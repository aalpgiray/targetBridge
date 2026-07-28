#!/bin/bash
# Removes the driver and restarts CoreAudio. Run this if audio misbehaves.
set -e
sudo rm -rf /Library/Audio/Plug-Ins/HAL/TargetBridge.driver
sudo killall coreaudiod 2>/dev/null || true
echo "removed; CoreAudio restarted"
