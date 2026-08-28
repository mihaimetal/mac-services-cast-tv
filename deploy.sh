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

echo "==> Installing ${BIN_DIR}/cast.sh and yt_lounge.py"
mkdir -p "${BIN_DIR}"
cp "${ROOT}/bin/cast.sh" "${BIN_DIR}/cast.sh"
cp "${ROOT}/bin/yt_lounge.py" "${BIN_DIR}/yt_lounge.py"
chmod 755 "${BIN_DIR}/cast.sh" "${BIN_DIR}/yt_lounge.py"

echo "==> Installing Python package samsungtvws"
if ! python3 -c "import samsungtvws" >/dev/null 2>&1; then
  python3 -m pip install -r "${ROOT}/requirements.txt"
else
  echo "    already present ($(python3 -c 'import importlib.metadata as m; print(m.version("samsungtvws"))'))"
fi

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
/System/Library/CoreServices/pbs >/dev/null 2>&1 || true

echo
echo "Done."
echo "  Play:    ${BIN_DIR}/cast.sh <youtube_url>"
echo "  Queue:   ${BIN_DIR}/cast.sh --queue <youtube_url>"
echo "  Service: select a YouTube URL → Services → Cast to TV / Queue on TV"
echo "  Log:     ${HOME}/.local/share/cast.log"
echo
echo "Queue on TV only works if YouTube is already playing on the TV."
echo "First remote keypress: allow this Mac on the TV if it prompts."
echo "If a Service menu item is missing, log out or run: killall Finder"
