#!/usr/bin/env bash
set -euo pipefail

# Install this repo onto the current Mac:
#   ~/.local/bin/cast.sh
#   ~/Applications/CastToTV.app   (casttv:// URL handler)
#   ~/Library/Services/Cast to TV.workflow

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_DST="${HOME}/.local/bin/cast.sh"
APP_DST="${HOME}/Applications/CastToTV.app"
SERVICE_NAME="Cast to TV.workflow"
SERVICE_SRC="${ROOT}/macos/${SERVICE_NAME}"
SERVICE_DST="${HOME}/Library/Services/${SERVICE_NAME}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

export PATH="${HOME}/Miniforge3/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

echo "==> Installing ${BIN_DST}"
mkdir -p "${HOME}/.local/bin"
cp "${ROOT}/bin/cast.sh" "${BIN_DST}"
chmod 755 "${BIN_DST}"

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

echo "==> Installing Service ${SERVICE_DST}"
mkdir -p "${HOME}/Library/Services"
rm -rf "${SERVICE_DST}"
cp -R "${SERVICE_SRC}" "${SERVICE_DST}"
/System/Library/CoreServices/pbs >/dev/null 2>&1 || true

echo
echo "Done."
echo "  CLI:     ${BIN_DST} <youtube_url>"
echo "  Service: select a YouTube URL → Services → Cast to TV"
echo "  Log:     ${HOME}/.local/share/cast.log"
echo
echo "First remote keypress: allow this Mac on the TV if it prompts."
echo "If the Service menu item is missing, log out or run: killall Finder"
