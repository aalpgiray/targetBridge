#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
DERIVED_DATA_DIR="${ROOT}/.build/DerivedData"
BUILD_DIR="${DERIVED_DATA_DIR}/Build/Products/Debug"
SOURCE_APP="${BUILD_DIR}/TargetBridge.app"
DEST_DIR="${REPO_ROOT}/build"
DEST_APP="${DEST_DIR}/TargetBridge.app"

cd "$ROOT"

xcodegen generate

xcodebuild \
  -scheme TBDisplaySender \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"

# Bundle the audio driver.
#
# The app's driver page compares the driver it ships against the one in
# /Library/Audio/Plug-Ins/HAL and offers Install / Update / "Up to date". With
# nothing bundled it can only ever say "This build does not include the driver",
# which is what every build said until this step existed.
#
# The driver's build.sh stamps CFBundleVersion with a hash of its own sources,
# so an unchanged driver is reused rather than recompiled — libASPL is a
# universal build and not quick.
DRIVER_DIR="$REPO_ROOT/TargetBridge-AudioDriver"
DRIVER_BUNDLE="$DRIVER_DIR/build/TargetBridge.driver"
DRIVER_HASH=$(cd "$DRIVER_DIR" && cat Driver.cpp build.sh | shasum -a 256 | cut -c1-12)
BUILT_HASH=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
    "$DRIVER_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
if [[ "$BUILT_HASH" != "$DRIVER_HASH" ]]; then
    echo "Building audio driver ($DRIVER_HASH)..."
    bash "$DRIVER_DIR/build.sh"
else
    echo "Audio driver unchanged ($DRIVER_HASH), reusing build."
fi
ditto "$DRIVER_BUNDLE" "$DEST_APP/Contents/Resources/TargetBridge.driver"

echo "Cleaning extended attributes..."
xattr -cr "$DEST_APP" || true
# Sign with a STABLE identity, not ad-hoc.
#
# This is not cosmetic. macOS keys TCC and Local Network grants to the code's
# designated requirement. Ad-hoc signed code (`--sign -`) has no certificate, so
# that requirement falls back to the cdhash — the exact bytes of the binary — and
# every rebuild therefore looks like a brand new app that has never been granted
# anything. The grant does not follow, and because the app NAME is unchanged,
# System Settings keeps showing a row that appears enabled while access is denied.
# The result is a Local Network list with one dead `TargetBridge` row per rebuild
# (six were observed) and a sender that reports `NWError 50 - Network is down`
# while `nc` reaches the receiver perfectly. Days were lost to that symptom.
#
# Signing with any real certificate — a self-signed one is enough — makes the
# requirement identifier + certificate chain, which is stable across rebuilds, so
# the grant is given once and then persists.
#
# Create the certificate (once per machine):
#   see TargetBridge-Sender/scripts/make_local_signing_cert.sh
# Override the name with TB_SIGN_IDENTITY if you use a Developer ID instead.
#
# Falls back to ad-hoc rather than failing the build, so a fresh clone still
# builds — but it says so loudly, because the fallback reintroduces the churn.
SIGN_IDENTITY="${TB_SIGN_IDENTITY:-TargetBridge Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "Signing sender application as \"$SIGN_IDENTITY\"..."
    codesign --force --deep --sign "$SIGN_IDENTITY" "$DEST_APP"
    # --deep just re-signed the bundled driver with our certificate. Put it
    # back to ad-hoc — the signature the driver's own build.sh gives it and the
    # only one proven to load in coreaudiod here — then reseal the app around it.
    codesign --force --sign - "$DEST_APP/Contents/Resources/TargetBridge.driver"
    codesign --force --sign "$SIGN_IDENTITY" "$DEST_APP"
else
    echo "WARNING: no \"$SIGN_IDENTITY\" identity found — falling back to ad-hoc." >&2
    echo "         Local Network access will NOT survive this reinstall." >&2
    echo "         Run scripts/make_local_signing_cert.sh to fix permanently." >&2
    codesign --force --deep --sign - "$DEST_APP" || true
fi
touch "$DEST_APP"

echo "TargetBridge sender built: $DEST_APP"
echo "Local DerivedData: $DERIVED_DATA_DIR"
