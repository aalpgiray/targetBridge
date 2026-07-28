#!/bin/bash
# Installs the driver for coreaudiod. Requires admin.
set -e
cd "$(dirname "$0")"
[ -d build/TargetBridge.driver ] || { echo "run build.sh first"; exit 1; }
sudo rm -rf /Library/Audio/Plug-Ins/HAL/TargetBridge.driver
sudo cp -R build/TargetBridge.driver /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/TargetBridge.driver
sudo killall coreaudiod 2>/dev/null || true
echo "installed; CoreAudio restarted. Check Audio MIDI Setup for 'TargetBridge'."
