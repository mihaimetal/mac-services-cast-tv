#!/usr/bin/env python3
"""Local play-next queue for Samsung YouTube.

The TV's YouTube app ignores Lounge addVideo, so we wait until the current
video is about to end (nowPlaying remaining <= 2.5s) and then DIAL-launch
the next queued id without interrupting earlier.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

QUEUE_FILE = Path.home() / ".local/share/cast_queue"
PID_FILE = Path.home() / ".local/share/cast_queue.pid"
LOG_FILE = Path.home() / ".local/share/cast.log"
HANDOFF_SECONDS = 2.5
SETTLE_SECONDS = 8.0

DIAL_PORTS = (8001, 8080)


def log(msg: str) -> None:
    line = time.strftime("%Y-%m-%d %H:%M:%S") + " " + msg
    print(line, flush=True)
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def dial_running(ip: str) -> bool:
    for port in DIAL_PORTS:
        try:
            with urllib.request.urlopen(f"http://{ip}:{port}/ws/apps/YouTube", timeout=2.0) as r:
                text = r.read().decode("utf-8", "replace")
            m = re.search(r"<state>([^<]+)</state>", text)
            if m and m.group(1) == "running":
                return True
        except (urllib.error.URLError, TimeoutError, OSError):
            continue
    return False


def dial_play(ip: str, video_id: str) -> bool:
    body = f"v={video_id}".encode()
    for port in DIAL_PORTS:
        req = urllib.request.Request(
            f"http://{ip}:{port}/ws/apps/YouTube",
            data=body,
            headers={"Content-Type": "text/plain"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                resp.read()
            return True
        except (urllib.error.URLError, TimeoutError, OSError):
            continue
    return False


def dial_screen_id(ip: str) -> str | None:
    for port in DIAL_PORTS:
        try:
            with urllib.request.urlopen(f"http://{ip}:{port}/ws/apps/YouTube", timeout=2.0) as r:
                text = r.read().decode("utf-8", "replace")
            m = re.search(r"<screenId>([^<]+)</screenId>", text)
            if m:
                return m.group(1)
        except (urllib.error.URLError, TimeoutError, OSError):
            continue
    return None


def read_queue() -> list[str]:
    if not QUEUE_FILE.is_file():
        return []
    return [ln.strip() for ln in QUEUE_FILE.read_text().splitlines() if ln.strip()]


def write_queue(items: list[str]) -> None:
    QUEUE_FILE.parent.mkdir(parents=True, exist_ok=True)
    QUEUE_FILE.write_text("".join(v + "\n" for v in items))


def pop_queue() -> str | None:
    items = read_queue()
    if not items:
        return None
    vid = items.pop(0)
    write_queue(items)
    return vid


def append_queue(video_id: str) -> int:
    items = read_queue()
    items.append(video_id)
    write_queue(items)
    return len(items)


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def watcher_running() -> bool:
    if not PID_FILE.is_file():
        return False
    try:
        pid = int(PID_FILE.read_text().strip())
    except ValueError:
        return False
    return pid_alive(pid)


def notify(title: str, message: str) -> None:
    script = f'display notification {message!r} with title {title!r}'
    subprocess.run(["osascript", "-e", script], check=False, capture_output=True)


def spawn_watcher(ip: str) -> None:
    if watcher_running():
        return
    log_f = LOG_FILE.open("a")
    proc = subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "--watch", "--ip", ip],
        start_new_session=True,
        stdout=log_f,
        stderr=log_f,
        stdin=subprocess.DEVNULL,
    )
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(proc.pid) + "\n")
    log(f"queue watcher started pid={proc.pid}")


def play_next(ip: str) -> bool:
    vid = pop_queue()
    if not vid:
        return False
    left = len(read_queue())
    log(f"queue handoff -> {vid} ({left} still waiting)")
    if not dial_play(ip, vid):
        log(f"queue handoff failed to launch {vid}")
        # put it back at the front
        write_queue([vid] + read_queue())
        return False
    notify("Queue on TV", f"Playing next queued video ({left} left)")
    return True


async def watch_loop(ip: str) -> None:
    import asyncio

    from pyytlounge import YtLoungeApi
    from pyytlounge.event_listener import EventListener
    from pyytlounge.events import NowPlayingEvent, PlaybackStateEvent
    from pyytlounge.models import State

    handed_for: str | None = None
    last_fire = 0.0

    class Listener(EventListener):
        async def now_playing_changed(self, event: NowPlayingEvent) -> None:
            await maybe_handoff(event.video_id, event.current_time, event.duration, event.state)

        async def playback_state_changed(self, event: PlaybackStateEvent) -> None:
            await maybe_handoff(None, event.current_time, event.duration, event.state)

    async def maybe_handoff(video_id, current_time, duration, state) -> None:
        nonlocal handed_for, last_fire
        if not read_queue():
            return
        now = time.monotonic()
        if now - last_fire < SETTLE_SECONDS:
            return
        remaining = None
        if current_time is not None and duration and duration > 0:
            remaining = duration - current_time
        near_end = remaining is not None and 0 <= remaining <= HANDOFF_SECONDS
        ended = state in (State.Stopped,)
        if not (near_end or ended):
            return
        key = video_id or "_"
        if handed_for == key:
            return
        handed_for = key
        last_fire = now
        play_next(ip)

    idle_empty = 0
    while True:
        if not read_queue():
            idle_empty += 1
            if idle_empty > 12:  # ~60s of empty polls if subscribe keeps dying
                log("queue empty, watcher exiting")
                return
            await asyncio.sleep(5)
            continue
        idle_empty = 0
        if not dial_running(ip):
            log("YouTube not running; waiting")
            await asyncio.sleep(5)
            continue
        screen = dial_screen_id(ip)
        if not screen:
            await asyncio.sleep(3)
            continue
        try:
            async with YtLoungeApi("Mac Cast Queue", event_listener=Listener()) as api:
                if not await api.pair_with_screen_id(screen):
                    log("queue watcher: lounge pair failed")
                    await asyncio.sleep(5)
                    continue
                if not await api.connect():
                    log("queue watcher: lounge connect failed")
                    await asyncio.sleep(5)
                    continue
                await api.get_now_playing()
                log("queue watcher subscribed")
                await api.subscribe()
        except Exception as e:
            log(f"queue watcher lounge error: {e}")
            await asyncio.sleep(5)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip", required=True)
    parser.add_argument("--add", metavar="VIDEO_ID")
    parser.add_argument("--watch", action="store_true")
    args = parser.parse_args()

    if args.watch:
        PID_FILE.parent.mkdir(parents=True, exist_ok=True)
        PID_FILE.write_text(str(os.getpid()) + "\n")
        import asyncio

        try:
            asyncio.run(watch_loop(args.ip))
        finally:
            try:
                if PID_FILE.is_file() and PID_FILE.read_text().strip() == str(os.getpid()):
                    PID_FILE.unlink()
            except OSError:
                pass
        return 0

    if not args.add:
        parser.error("pass --add VIDEO_ID or --watch")

    if not dial_running(args.ip):
        print("YouTube is not playing on the TV.")
        return 2

    n = append_queue(args.add)
    spawn_watcher(args.ip)
    print(f"Queued {args.add} to play after the current video ({n} waiting)")
    notify("Queue on TV", f"Queued. Plays after the current video ({n} waiting).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
