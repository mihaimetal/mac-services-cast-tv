#!/usr/bin/env python3
"""Add a video to the TV YouTube queue via Lounge addVideo.

The TV shows the native "Video added" toast and keeps playing the current video.
"""

from __future__ import annotations

import argparse
import asyncio
import re
import subprocess
import sys
import urllib.error
import urllib.request

from pyytlounge import YtLoungeApi

DIAL_PORTS = (8001, 8080)
EXIT_NOT_PLAYING = 2


class QueueApi(YtLoungeApi):
    async def add_video(self, video_id: str) -> bool:
        return await self._command("addVideo", {"videoId": video_id})


def _http_get(url: str, timeout: float = 2.0) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read().decode("utf-8", "replace")


def dial_status(ip: str) -> tuple[str, str]:
    for port in DIAL_PORTS:
        try:
            text = _http_get(f"http://{ip}:{port}/ws/apps/YouTube", timeout=2.0)
        except (urllib.error.URLError, TimeoutError, OSError):
            continue
        state_m = re.search(r"<state>([^<]+)</state>", text)
        screen_m = re.search(r"<screenId>([^<]+)</screenId>", text)
        return (state_m.group(1) if state_m else "", screen_m.group(1) if screen_m else "")
    return "", ""


def notify(title: str, message: str) -> None:
    script = f"display notification {message!r} with title {title!r}"
    subprocess.run(["osascript", "-e", script], check=False, capture_output=True)


async def queue_video(ip: str, video_id: str) -> int:
    state, screen = dial_status(ip)
    if state != "running" or not screen:
        print("YouTube is not playing on the TV.")
        return EXIT_NOT_PLAYING

    async with QueueApi("Mac Cast") as api:
        if not await api.pair_with_screen_id(screen):
            print("YouTube lounge pair failed.", file=sys.stderr)
            return 1
        if not await api.connect():
            print("YouTube lounge connect failed.", file=sys.stderr)
            return 1
        if not await api.add_video(video_id):
            print("YouTube lounge addVideo failed.", file=sys.stderr)
            return 1

    print(f"Queued {video_id} on {ip}")
    notify("Queue on TV", "Added to the TV YouTube queue")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", required=True, help="Samsung TV IP")
    parser.add_argument("--queue", metavar="VIDEO_ID", required=True)
    args = parser.parse_args()
    try:
        return asyncio.run(queue_video(args.ip, args.queue))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        print(f"YouTube lounge HTTP {e.code}: {detail}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"YouTube lounge error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
