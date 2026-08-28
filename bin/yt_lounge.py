#!/usr/bin/env python3
"""Queue (or start) a YouTube video on a Samsung TV via the Lounge API."""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

DIAL_PORTS = (8001, 8080)
LOUNGE_TOKEN_URL = "https://www.youtube.com/api/lounge/pairing/get_lounge_token_batch"
BIND_URL = "https://www.youtube.com/api/lounge/bc/bind"
ORIGIN = "https://www.youtube.com/"
REMOTE_ID_FILE = Path.home() / ".cast_tv_remote_id.txt"

# 2 = YouTube isn't playing; caller should launch the video instead of queueing.
EXIT_NOT_PLAYING = 2


def _post(url: str, data: dict | None = None, params: dict | None = None, headers: dict | None = None, timeout: float = 15.0) -> bytes:
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    hdrs = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Origin": ORIGIN,
    }
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=body, headers=hdrs, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def _http_get(url: str, timeout: float = 2.0) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read().decode("utf-8", "replace")


def dial_status(ip: str) -> tuple[str, str, int | None]:
    """Return (state, screen_id, port) from the TV's YouTube DIAL endpoint."""
    for port in DIAL_PORTS:
        try:
            text = _http_get(f"http://{ip}:{port}/ws/apps/YouTube", timeout=2.0)
        except (urllib.error.URLError, TimeoutError, OSError):
            continue
        state_m = re.search(r"<state>([^<]+)</state>", text)
        screen_m = re.search(r"<screenId>([^<]+)</screenId>", text)
        state = state_m.group(1) if state_m else ""
        screen = screen_m.group(1) if screen_m else ""
        return state, screen, port
    return "", "", None


def launch_youtube(ip: str) -> None:
    pairing = str(uuid.uuid4())
    body = f"pairingCode={pairing}&theme=cl".encode()
    last_err: Exception | None = None
    for port in DIAL_PORTS:
        url = f"http://{ip}:{port}/ws/apps/YouTube"
        req = urllib.request.Request(
            url,
            data=body,
            headers={"Content-Type": "text/plain"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                resp.read()
            return
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last_err = e
    raise SystemExit(f"Failed to launch YouTube on {ip}: {last_err}")


def wait_for_screen(ip: str, timeout: float = 15.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state, screen, _port = dial_status(ip)
        if state == "running" and screen:
            return screen
        time.sleep(0.5)
    raise SystemExit(f"YouTube on {ip} did not publish a screenId")


def remote_id() -> str:
    if REMOTE_ID_FILE.is_file():
        saved = REMOTE_ID_FILE.read_text().strip()
        if saved:
            return saved
    rid = str(uuid.uuid4())
    REMOTE_ID_FILE.write_text(rid + "\n")
    return rid


def lounge_bind(screen_id: str) -> tuple[str, str, str, bytes]:
    raw = _post(LOUNGE_TOKEN_URL, data={"screen_ids": screen_id})
    token = json.loads(raw)["screens"][0]["loungeToken"]
    bind_data = {
        "device": "REMOTE_CONTROL",
        "id": remote_id(),
        "name": "Mac Cast",
        "mdx-version": 3,
        "pairing_type": "cast",
        "app": "android-phone-13.14.55",
    }
    bind_raw = _post(
        BIND_URL,
        data=bind_data,
        params={"RID": 0, "VER": 8, "CVER": 1},
        headers={"X-YouTube-LoungeId-Token": token},
    )
    text = bind_raw.decode("utf-8", "replace")
    sid_m = re.search(r'"c","(.*?)"', text)
    gs_m = re.search(r'"S","(.*?)"', text)
    if not sid_m or not gs_m:
        raise SystemExit(f"YouTube lounge bind did not return session ids:\n{text[:400]}")
    return token, sid_m.group(1), gs_m.group(1), bind_raw


def has_active_queue(bind_raw: bytes) -> bool:
    text = bind_raw.decode("utf-8", "replace")
    if '"nowPlaying"' in text:
        return True
    if re.search(r'"firstVideoId":"[^"]+"', text):
        return True
    return False


def lounge_add_video(token: str, sid: str, gsession: str, video_id: str) -> None:
    data = {
        "req0__sc": "addVideo",
        "req0_videoId": video_id,
        "count": 1,
    }
    _post(
        BIND_URL,
        data=data,
        params={"SID": sid, "gsessionid": gsession, "RID": 1, "VER": 8, "CVER": 1},
        headers={"X-YouTube-LoungeId-Token": token},
    )


def queue_video(ip: str, video_id: str) -> int:
    state, screen, _port = dial_status(ip)
    launched = False
    if state != "running" or not screen:
        print(f"YouTube not running on {ip}, launching it...")
        launch_youtube(ip)
        screen = wait_for_screen(ip)
        launched = True

    token, sid, gsession, bind_raw = lounge_bind(screen)
    if launched or not has_active_queue(bind_raw):
        print("Nothing is playing on YouTube; start the video with Cast to TV instead of Queue.")
        return EXIT_NOT_PLAYING

    lounge_add_video(token, sid, gsession, video_id)
    print(f"Queued {video_id} on {ip}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", required=True, help="Samsung TV IP")
    parser.add_argument("--queue", metavar="VIDEO_ID", required=True)
    args = parser.parse_args()
    try:
        return queue_video(args.ip, args.queue)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        print(f"YouTube lounge HTTP {e.code}: {detail}", file=sys.stderr)
        return 1
    except urllib.error.URLError as e:
        print(f"YouTube lounge network error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
