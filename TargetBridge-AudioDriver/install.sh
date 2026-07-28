#!/bin/bash
# Installs the driver and restarts the audio server so it is actually loaded.
# Requires admin.
set -e
cd "$(dirname "$0")"
[ -d build/TargetBridge.driver ] || { echo "run build.sh first"; exit 1; }

sudo rm -rf /Library/Audio/Plug-Ins/HAL/TargetBridge.driver
sudo cp -R build/TargetBridge.driver /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/TargetBridge.driver

# The audio server hosts HAL plug-ins and only loads them at startup, so an
# install without a restart leaves the OLD code running with the new binary on
# disk — which looks exactly like "my change did nothing". Recent macOS uses
# audiomxd; older releases use coreaudiod. Kill whichever is present, and fail
# loudly if neither is, rather than silently not reloading.
restarted=0
for proc in audiomxd coreaudiod; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    sudo killall "$proc" 2>/dev/null || true
    echo "restarted $proc"
    restarted=1
  fi
done
# Restarting the audio server is not enough on its own: recent macOS hosts each
# plug-in in a Core-Audio-Driver-Service.helper that OUTLIVES the restart, so the
# old copy keeps running and keeps its sockets. The new instance then loads
# alongside it and fails to bind. Clear them out too.
sudo pkill -f "Core-Audio-Driver-Service" 2>/dev/null || true

if [ "$restarted" -eq 0 ]; then
  echo "WARNING: no audio server process found (audiomxd/coreaudiod)."
  echo "         The driver will not load until one restarts — log out or reboot."
  exit 1
fi

echo "installed. Check Audio MIDI Setup for 'TargetBridge'."
echo "Driver logs: log stream --predicate 'subsystem == \"com.targetbridge.audiodriver\"' --info"
