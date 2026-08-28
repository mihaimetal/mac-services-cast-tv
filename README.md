# mac-services-cast-tv

Cast a YouTube URL from macOS to a Samsung Tizen TV.

Safari runs **Services** inside a sandbox, so the Service does not talk to the TV itself. It base64-encodes the selected URL and opens `casttv://…`. **CastToTV.app** handles that scheme unsandboxed and runs `cast.sh`.

Two Services:

- **Cast to TV** — play the video now
- **Queue on TV** — play next on the TV (does not interrupt the current video)

```
selected YouTube URL
        │
        ▼
Services → Cast to TV.workflow     (sandbox-safe: open casttv://)
        │
        ▼
~/Applications/CastToTV.app        (decodes URL, runs cast.sh)
        │
        ▼
~/.local/bin/cast.sh               (launch YouTube on the TV, press ENTER)
```

## Install

```bash
cd ~/DEV/cast
./deploy.sh
```

That copies `cast.sh`, builds `CastToTV.app` with the `casttv://` handler, and installs the **Cast to TV** and **Queue on TV** Services.

Needs:

- Python 3 (`samsungtvws` is installed by deploy)
- `curl`
- TV and Mac on the same LAN

## Use

- Select a YouTube URL (Safari, or any app that offers Services on text) → **Services → Cast to TV** (play now) or **Queue on TV** (play next)
- Or from a terminal:

```bash
cast.sh 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
cast.sh --queue 'https://youtu.be/dQw4w9WgXcQ'
cast.sh 192.168.0.111 'https://youtu.be/dQw4w9WgXcQ'
```

**Queue on TV** tells the TV to play that clip next (`insertVideo`). Current playback is not interrupted; skip or wait for the end to get the queued video. The TV often shows **Video added**. If YouTube is not already playing, it falls back to play-now.

The first time the script sends a remote key, the TV may ask to allow this Mac. Accept it. Token is stored at `~/.samsung_tv_token.txt` (not in git).

## TV IP

`cast.sh` remembers the last working address in `~/.samsung_tv_ip.txt`. If that host is not a Samsung TV, it tries the hardcoded default, then SSDP-discovers one on the LAN.

## Layout

| Path | Role |
|---|---|
| `bin/cast.sh` | Play now (DIAL + ENTER) or `--queue` |
| `bin/yt_lounge.py` | Lounge `addVideo` for Queue on TV |
| `macos/CastToTV.swift` | Source for the `casttv://` helper app |
| `macos/Cast to TV.workflow` | Play-now Service |
| `macos/Queue on TV.workflow` | Queue Service |
| `deploy.sh` | Install onto this Mac |

Log: `~/.local/share/cast.log`
