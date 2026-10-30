#!/bin/zsh
set -euo pipefail

APP="${1:?Usage: set_receiver_minimum_macos.sh Receiver.app}"
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || { print -u2 'Receiver Info.plist is missing'; exit 1; }
autoload -Uz is-at-least
MINIMUM="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
FILES=("$APP/Contents/MacOS/"*(N) "$APP/Contents/Frameworks/"*.dylib(N))
(( ${#FILES} > 0 )) || { print -u2 'Receiver binaries are missing'; exit 1; }

for BINARY in "${FILES[@]}"; do
    VERSIONS="$(otool -l "$BINARY" | awk '
        $1 == "cmd" { kind = $2 }
        kind == "LC_BUILD_VERSION" && $1 == "minos" { print $2 }
        kind == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2 }
    ')"
    [[ -n "$VERSIONS" ]] || { print -u2 "No macOS minimum found: $BINARY"; exit 1; }
    for VERSION in ${(f)VERSIONS}; do
        if ! is-at-least "$VERSION" "$MINIMUM"; then MINIMUM="$VERSION"; fi
    done
done

if [[ -n "${TARGETBRIDGE_RECEIVER_MAX_MIN_OS:-}" ]] &&
   ! is-at-least "$MINIMUM" "$TARGETBRIDGE_RECEIVER_MAX_MIN_OS"; then
    print -u2 "Receiver runtime requires macOS $MINIMUM; expected support for $TARGETBRIDGE_RECEIVER_MAX_MIN_OS"
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MINIMUM" "$PLIST"
print -- "Receiver bundle minimum macOS: $MINIMUM (executable and all bundled runtimes)"
