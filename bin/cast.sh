#!/usr/bin/env bash
set -euo pipefail

# Fallback if ~/.samsung_tv_ip.txt is missing or stale. DHCP can move the TV.
DEFAULT_TV_IP="192.168.0.111"
IP_CACHE="${HOME}/.samsung_tv_ip.txt"

# Regex to check for a valid IPv4 address format
ipv4_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"

is_samsung_tv() {
  python3 - "$1" <<'PY'
import json, sys, urllib.request
ip = sys.argv[1]
try:
    with urllib.request.urlopen(f"http://{ip}:8001/api/v2/", timeout=1.0) as r:
        data = json.load(r)
    ok = data.get("type") == "Samsung SmartTV" or "Samsung" in str(data.get("name", ""))
    raise SystemExit(0 if ok else 1)
except Exception:
    raise SystemExit(1)
PY
}

discover_samsung_tv() {
  python3 - <<'PY'
import json, socket, time, urllib.request

def is_tv(ip, timeout=0.8):
    try:
        with urllib.request.urlopen(f"http://{ip}:8001/api/v2/", timeout=timeout) as r:
            data = json.load(r)
        return data.get("type") == "Samsung SmartTV" or "Samsung" in str(data.get("name", ""))
    except Exception:
        return False

msg = (
    "M-SEARCH * HTTP/1.1\r\n"
    "HOST: 239.255.255.250:1900\r\n"
    'MAN: "ssdp:discover"\r\n'
    "MX: 2\r\n"
    "ST: ssdp:all\r\n"
    "\r\n"
).encode()
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.settimeout(2.5)
sock.sendto(msg, ("239.255.255.250", 1900))
seen = set()
ips = []
end = time.time() + 2.5
while time.time() < end:
    try:
        data, addr = sock.recvfrom(65535)
    except socket.timeout:
        break
    ip = addr[0]
    if ip in seen:
        continue
    if "samsung" in data.decode("utf-8", "replace").lower():
        seen.add(ip)
        ips.append(ip)

for ip in ips:
    if is_tv(ip):
        print(ip)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

usage() {
  echo "Usage: $0 [--queue] [tv_ip] <youtube_url>"
  echo "  (default)  play the video now"
  echo "  --queue    play after the current video (does not interrupt)"
  echo "Example: $0 https://youtu.be/BOUeZJDa4pU"
  echo "Example: $0 --queue https://youtu.be/BOUeZJDa4pU"
}

MODE=play
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --queue|-q) MODE=queue; shift ;;
    --play|-p) MODE=play; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; POSITIONAL+=("$@"); break ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  set -- "${POSITIONAL[@]}"
else
  set --
fi

# Check if the first argument matches the IPv4 regex
explicit_ip=0
if [[ "${1:-}" =~ $ipv4_regex ]]; then
  explicit_ip=1
  TV_IP="$1"
  YT_URL="${2:-}"
else
  if [[ -s "$IP_CACHE" ]]; then
    TV_IP="$(tr -d '[:space:]' < "$IP_CACHE")"
  else
    TV_IP="$DEFAULT_TV_IP"
  fi
  YT_URL="${1:-}"
fi

if [[ -z "$YT_URL" ]]; then
  usage >&2
  exit 1
fi

if [[ "$explicit_ip" -eq 0 ]]; then
  if ! is_samsung_tv "$TV_IP"; then
    echo "TV not responding at $TV_IP, searching the LAN..."
    if [[ "$TV_IP" != "$DEFAULT_TV_IP" ]] && is_samsung_tv "$DEFAULT_TV_IP"; then
      TV_IP="$DEFAULT_TV_IP"
    elif found="$(discover_samsung_tv)"; then
      TV_IP="$found"
    else
      echo "Could not find a Samsung TV on the LAN. Pass the IP explicitly: $0 <tv_ip> <youtube_url>"
      exit 1
    fi
    echo "Found TV at $TV_IP"
  fi
  printf '%s\n' "$TV_IP" > "$IP_CACHE"
fi

# Function to extract the Video ID from various YouTube URL formats
extract_video_id() {
  local url="$1"
  python3 - "$url" <<'PY'
import sys, urllib.parse as u
url = sys.argv[1]
p = u.urlparse(url)

vid = None
if p.netloc in ("youtu.be", "www.youtu.be"):
    vid = p.path.lstrip("/").split("/")[0]
else:
    qs = u.parse_qs(p.query)
    vid = qs.get("v", [None])[0]

if not vid and "/shorts/" in p.path:
    vid = p.path.split("/shorts/")[-1].split("/")[0]

if not vid and "/live/" in p.path:
    vid = p.path.split("/live/")[-1].split("/")[0]

if not vid:
    raise SystemExit(1)

print(vid)
PY
}

VIDEO_ID="$(extract_video_id "$YT_URL")"
HERE="$(cd "$(dirname "$0")" && pwd)"
QUEUE_PY="${HERE}/cast_queue_watch.py"

echo "Casting video ID: $VIDEO_ID to $TV_IP (${MODE})"

if [[ "$MODE" == "queue" ]]; then
  set +e
  python3 "$QUEUE_PY" --ip "$TV_IP" --add "$VIDEO_ID"
  queue_rc=$?
  set -e
  if [[ "$queue_rc" -eq 0 ]]; then
    exit 0
  fi
  if [[ "$queue_rc" -eq 2 ]]; then
    echo "YouTube is not already playing; starting this video now."
  else
    echo "Queue failed (exit $queue_rc)."
    exit "$queue_rc"
  fi
fi

# 1. Try port 8001 (Standard endpoint used by modern Samsung Tizen TVs)
echo "Launching YouTube on TV..."
launched=0
if curl -m 2 -sS -X POST "http://$TV_IP:8001/ws/apps/YouTube" \
  --data "v=$VIDEO_ID" \
  -H "Content-Type: text/plain" >/dev/null 2>&1; then
  launched=1
fi

# 2. Try port 8080 (Fallback for older firmware)
if [[ "$launched" -eq 0 ]]; then
  if curl -m 2 -sS -X POST "http://$TV_IP:8080/ws/apps/YouTube" \
    --data "v=$VIDEO_ID" \
    -H "Content-Type: text/plain" >/dev/null 2>&1; then
    launched=1
  fi
fi

if [[ "$launched" -eq 0 ]]; then
  echo "Failed to launch YouTube on $TV_IP (ports 8001 and 8080)."
  exit 1
fi
echo "YouTube launched."

# Absolute times (seconds after launch) at which to press ENTER. The profile
# "Who's watching" screen can appear fast (warm) or late (cold, after the video
# preview loads), so we bracket both. Close pairs cover a swallowed first key;
# the late press at ~10s catches a slow profile screen. A lone press during
# playback just flashes the on-screen controls rather than pausing.
PRESS_TIMES="6"

echo "Pressing ENTER at the following times (s after launch) to bypass the profile screen: ${PRESS_TIMES}"
# Python block to send the Enter key via WebSocket
python3 - "$TV_IP" $PRESS_TIMES <<'EOF'
import sys
import os
import time
from samsungtvws import SamsungTVWS

tv_ip = sys.argv[1]
press_times = sorted(float(x) for x in sys.argv[2:])

# Save the authorization token to a hidden file in your Mac's home folder
token_file = os.path.expanduser('~/.samsung_tv_token.txt')

try:
    # Connect using port 8002 (WSS) which handles secure tokens for 2018+ TVs
    tv = SamsungTVWS(tv_ip, port=8002, token_file=token_file)

    # Open and register the remote NOW, so it's warm by the time we press ENTER.
    # Samsung TVs commonly swallow the first key sent on a freshly-opened socket
    # (the TV is still registering the remote), which is why a single lazily-sent
    # ENTER worked only intermittently. Warming it up front avoids that.
    tv.open()

    start = time.monotonic()
    for t in press_times:
        delay = start + t - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        # Reconnect if the idle socket dropped between presses.
        if not tv.is_alive():
            tv.open()
        tv.send_key('KEY_ENTER')
        print(f"ENTER sent at ~{t}s")
    print("Done. Video should be playing.")
except Exception as e:
    print(f"Could not send remote command: {e}")
    print("If this says 'unauthorized', you need to go to your TV's Network/Device settings, delete the blocked device, and click 'Allow' on the TV screen next time you run this script.")
EOF
