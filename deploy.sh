#!/usr/bin/env bash
set -euo pipefail

# Install this repo onto the current Mac:
#   ~/.local/bin/cast.sh
#   ~/.local/bin/yt_lounge.py
#   ~/Applications/CastToTV.app   (casttv:// URL handler)
#   ~/Library/Services/Cast to TV.workflow
#   ~/Library/Services/Queue on TV.workflow

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
APP_DST="${HOME}/Applications/CastToTV.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

export PATH="${HOME}/Miniforge3/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

echo "==> Installing ${BIN_DIR}/cast.sh and helpers"
mkdir -p "${BIN_DIR}"
cp "${ROOT}/bin/cast.sh" "${BIN_DIR}/cast.sh"
cp "${ROOT}/bin/yt_lounge.py" "${BIN_DIR}/yt_lounge.py"
cp "${ROOT}/bin/cast_queue_watch.py" "${BIN_DIR}/cast_queue_watch.py"
chmod 755 "${BIN_DIR}/cast.sh" "${BIN_DIR}/yt_lounge.py" "${BIN_DIR}/cast_queue_watch.py"

echo "==> Installing Python packages"
python3 -m pip install -q -r "${ROOT}/requirements.txt"

echo "==> Building ${APP_DST}"
mkdir -p "${HOME}/Applications"
osascript -e 'tell application "CastToTV" to quit' >/dev/null 2>&1 || true
/usr/bin/osacompile -o "${APP_DST}" "${ROOT}/macos/CastToTV.applescript"

python3 - "${APP_DST}/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path

plist_path = Path(sys.argv[1])
data = plistlib.loads(plist_path.read_bytes())
data["CFBundleIdentifier"] = "com.mihai.casttv.helper"
data["CFBundleName"] = "CastToTV"
data["OSAAppletShowStartupScreen"] = False
data["CFBundleURLTypes"] = [
    {
        "CFBundleURLName": "com.mihai.casttv.helper",
        "CFBundleURLSchemes": ["casttv"],
    }
]
plist_path.write_bytes(plistlib.dumps(data))
PY

codesign --force --deep -s - "${APP_DST}" >/dev/null 2>&1 || true
if [[ -x "${LSREGISTER}" ]]; then
  "${LSREGISTER}" -f "${APP_DST}" >/dev/null 2>&1 || true
fi

echo "==> Installing Services"
mkdir -p "${HOME}/Library/Services"
for service in "Cast to TV.workflow" "Queue on TV.workflow"; do
  src="${ROOT}/macos/${service}"
  dst="${HOME}/Library/Services/${service}"
  echo "    ${dst}"
  rm -rf "${dst}"
  cp -R "${src}" "${dst}"
done
echo "==> Enabling Services in the menu"
python3 - <<'PY'
import plistlib, subprocess, tempfile
from pathlib import Path

raw = subprocess.check_output(["defaults", "export", "pbs", "-"])
data = plistlib.loads(raw)
status = data.setdefault("NSServicesStatus", {})
for name in ("Cast to TV", "Queue on TV"):
    key = f"(null) - {name} - runWorkflowAsService"
    status[key] = {
        "presentation_modes": {
            "ContextMenu": True,
            "ServicesMenu": True,
            "TouchBar": True,
        }
    }
tmp = Path(tempfile.mkstemp(suffix=".plist")[1])
tmp.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML))
subprocess.check_call(["defaults", "import", "pbs", str(tmp)])
tmp.unlink(missing_ok=True)
PY
killall pbs >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs >/dev/null 2>&1 || true

echo
echo "Done."
echo "  Play:    ${BIN_DIR}/cast.sh <youtube_url>"
echo "  Queue:   ${BIN_DIR}/cast.sh --queue <youtube_url>"
echo "  Service: select a YouTube URL → Services → Cast to TV / Queue on TV"
echo "  Log:     ${HOME}/.local/share/cast.log"
echo
echo "Queue on TV waits until the current video is almost over, then starts the next."
echo "If Queue on TV is missing from the menu, quit Safari and open it again."
echo "First remote keypress: allow this Mac on the TV if it prompts."
