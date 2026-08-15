#!/bin/bash
# Install the built sender to /Applications — the canonical location.
#
# Exists because this sequence was retyped from memory dozens of times and got it
# wrong in two ways that both cost real time:
#
#   - the audio driver was restored from a /tmp scratchpad that does not survive a
#     reboot, so a reinstall silently lost it (Debug builds omit the driver)
#   - `tccutil reset` was run every time. Correct under ad-hoc signing, actively
#     harmful now: the stable certificate means grants persist, and resetting
#     discards the Local Network permission for no reason.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/build/TargetBridge.app"
DEST="/Applications/TargetBridge.app"
IDENTITY="${TB_SIGN_IDENTITY:-TargetBridge Local Signing}"
# In the repo, so it survives reboots and machine changes.
DRIVER_SRC="$ROOT/TargetBridge-AudioDriver/build/TargetBridge.driver"

[ -d "$APP" ] || { echo "No build at $APP — run build_targetbridge_sender_app.sh first." >&2; exit 1; }

echo "==> quitting"
osascript -e 'tell application "TargetBridge" to quit' 2>/dev/null || true
sleep 2

# Prefer the driver already installed: it is the one known to work on this Mac.
STASH="$(mktemp -d)"
if [ -d "$DEST/Contents/Resources/TargetBridge.driver" ]; then
    ditto "$DEST/Contents/Resources/TargetBridge.driver" "$STASH/TargetBridge.driver"
elif [ -d "$DRIVER_SRC" ]; then
    ditto "$DRIVER_SRC" "$STASH/TargetBridge.driver"
fi

echo "==> installing"
rm -rf "$DEST"
ditto "$APP" "$DEST"

if [ -d "$STASH/TargetBridge.driver" ]; then
    echo "==> restoring the audio driver"
    ditto "$STASH/TargetBridge.driver" "$DEST/Contents/Resources/TargetBridge.driver"
fi
rm -rf "$STASH"

xattr -cr "$DEST"
# Re-sign AFTER restoring the driver: adding it breaks the --deep seal.
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$DEST"
else
    echo "WARNING: no \"$IDENTITY\" identity — signing ad-hoc." >&2
    echo "         Local Network access will NOT survive this install." >&2
    echo "         Fix permanently: bash TargetBridge-Sender/scripts/make_local_signing_cert.sh" >&2
    codesign --force --deep --sign - "$DEST"
fi

echo "==> launching"
open -a "$DEST"
sleep 3
pgrep -x TargetBridge >/dev/null && echo "Installed and running." || { echo "Did not start." >&2; exit 1; }
