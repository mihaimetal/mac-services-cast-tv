#!/usr/bin/env python3
"""Play-next on the TV YouTube app (Lounge insertVideo). Does not interrupt."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
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
EXIT_NOT_PLAYING = 2


def _post(
    url: str,
    data: dict | None = None,
    params: dict | None = None,
    token: str | None = None,
    timeout: float = 15.0,
) -> str:
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Origin": ORIGIN,
    }
    if token:
        headers["X-YouTube-LoungeId-Token"] = token
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", "replace")


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


def remote_id() -> str:
    if REMOTE_ID_FILE.is_file():
        saved = REMOTE_ID_FILE.read_text().strip()
        if saved:
            return saved
    rid = str(uuid.uuid4())
    REMOTE_ID_FILE.write_text(rid + "\n")
    return rid


def notify(title: str, message: str) -> None:
    script = f'display notification {message!r} with title {title!r} sound name "Glass"'
    subprocess.run(["osascript", "-e", script], check=False, capture_output=True)


def lounge_insert(screen_id: str, video_id: str) -> None:
    token = json.loads(_post(LOUNGE_TOKEN_URL, data={"screen_ids": screen_id}))["screens"][0][
        "loungeToken"
    ]
    bind_data = {
        "device": "REMOTE_CONTROL",
        "id": remote_id(),
        "name": "Mac Cast",
        "mdx-version": 3,
        "pairing_type": "cast",
        "app": "android-phone-13.14.55",
    }
    bind_text = _post(
        BIND_URL,
        data=bind_data,
        params={"RID": 0, "VER": 8, "CVER": 1},
        token=token,
    )
    sid_m = re.search(r'"c","(.*?)"', bind_text)
    gs_m = re.search(r'"S","(.*?)"', bind_text)
    if not sid_m or not gs_m:
        raise RuntimeError(f"lounge bind missing session ids:\n{bind_text[:400]}")

    # First command on a fresh bind (ofs=0), same pattern as a phone "play next".
    _post(
        BIND_URL,
        data={
            "count": "1",
            "ofs": "0",
            "req0__sc": "insertVideo",
            "req0_videoId": video_id,
        },
        params={
            "SID": sid_m.group(1),
            "gsessionid": gs_m.group(1),
            "RID": 1,
            "VER": 8,
            "CVER": 1,
        },
        token=token,
    )


def queue_video(ip: str, video_id: str) -> int:
    state, screen = dial_status(ip)
    if state != "running" or not screen:
        print("YouTube is not playing on the TV.")
        return EXIT_NOT_PLAYING

    lounge_insert(screen, video_id)
    print(f"Queued {video_id} on {ip} (play next)")
    notify("Queue on TV", "Queued to play next. TV should show Video added.")
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
    except Exception as e:
        print(f"YouTube lounge error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
