#!/bin/bash
# Install the built sender to /Applications — the canonical location.
#
# Exists because this sequence was retyped from memory dozens of times and got it
# wrong in two ways that both cost real time:
#
#   - the audio driver was restored from a /tmp scratchpad that does not survive a
#     reboot, so a reinstall silently lost it
#   - `tccutil reset` was run every time. Correct under ad-hoc signing, actively
#     harmful now: the stable certificate means grants persist, and resetting
#     discards the Local Network permission for no reason.
#
# The build now bundles the audio driver itself and signs the finished app, so
# this copies it as-is. It used to carry the driver over from the previously
# installed app and re-sign — which, once the build ships a fresh driver, would
# put the OLD driver back and leave the app unable to ever offer an update.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/build/TargetBridge.app"
DEST="/Applications/TargetBridge.app"

[ -d "$APP" ] || { echo "No build at $APP — run build_targetbridge_sender_app.sh first." >&2; exit 1; }
[ -d "$APP/Contents/Resources/TargetBridge.driver" ] || \
    echo "WARNING: this build has no bundled audio driver; the driver page will say so." >&2
codesign --verify --deep --strict "$APP" || { echo "Build signature is invalid — rebuild." >&2; exit 1; }

echo "==> quitting"
osascript -e 'tell application "TargetBridge" to quit' 2>/dev/null || true
sleep 2

echo "==> installing"
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "==> launching"
open -a "$DEST"
sleep 3
pgrep -x TargetBridge >/dev/null && echo "Installed and running." || { echo "Did not start." >&2; exit 1; }
