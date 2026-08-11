#!/bin/bash
# verify_features.sh — assert that every hard-won feature is still present.
#
# WHY THIS EXISTS
#
# This tree carries a lot of work whose absence is silent. Most of it is not a
# feature you would notice missing on launch: it is a two-line capture setting, a
# lock that must not be removed, a probe interval, a backpressure divisor. Merging
# upstream touches the same two hub files that hold most of them, and "favour
# upstream" reverts that kind of line without ever raising a conflict.
#
# So the guarantee cannot be "read the diff carefully". It has to be mechanical:
# run this before a merge to get a baseline, run it after, and compare. Anything
# that disappears fails the script rather than surfacing weeks later as a
# performance regression nobody can explain.
#
# WHAT A MARKER IS
#
# Each check names one thing and the smallest string that proves it is wired in —
# not that a file exists, but that the call site is there. A file can survive a
# merge while the one line that invokes it does not.
#
#   ./verify_features.sh              check markers only (fast)
#   ./verify_features.sh --full       also build both ends and run the tests
#
# Exit status is the number of failures, so it composes with `&&`.

set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

PASS=0; FAIL=0
red()  { printf '\033[31m%s\033[0m' "$1"; }
green(){ printf '\033[32m%s\033[0m' "$1"; }

# want <label> <min-count> <pattern> <path...>
want() {
    local label="$1" min="$2" pat="$3"; shift 3
    local n
    n=$(grep -rIl --include='*' -e "$pat" "$@" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -ge "$min" ]; then
        PASS=$((PASS+1)); printf '  %s %-46s %s file(s)\n' "$(green ok)" "$label" "$n"
    else
        FAIL=$((FAIL+1)); printf '  %s %-46s expected >=%s, found %s  [%s]\n' \
            "$(red FAIL)" "$label" "$min" "$n" "$pat"
    fi
}

echo "== 10-bit / colour =========================================="
# The single most fragile thing here. A virtual display is 8-bpc because it is
# SDR; declaring a transfer function is what makes macOS promote the framebuffer
# to 16-bpc, and it is the ONLY reason the 10-bit path carries real bits rather
# than 8-bit values replicated into 10. Upstream edits the same function.
want "virtual display transferFunction" 1 "transferFunction" TargetBridge-Sender/TBDisplaySender
want "TBTransferFn override knob"       1 "TBTransferFn"      TargetBridge-Sender/TBDisplaySender
want "10-bit capture format (l10r)"     1 "ARGB2101010"       TargetBridge-Sender TargetBridge-Receiver
want "receiver 10-bit decode"           1 "ten_bit"           TargetBridge-Receiver/TBReceiverC/src

echo "== lossless 5K transfer (TBD2) =============================="
want "codec reference impl"              1 "tb_dpcm_encode"    TargetBridge-Shared/codec
want "GPU encoder"                      1 "tb_dpcm_gpu_encode" TargetBridge-Shared/codec
want "async encode entry point"         1 "encode_bands_async" TargetBridge-Shared/codec TargetBridge-Sender
want "sender async encode context"      1 "TBDPCMAsyncEncode"  TargetBridge-Sender
want "GPU decode on the receiver"       1 "render_dpcm_slice"  TargetBridge-Receiver/TBReceiverC/src
# All three live in one file, so check each name rather than counting files.
want "wire packet: whole frame"          1 "rawDPCM\b"          TargetBridge-Sender/TBDisplayShared
want "wire packet: slice"                1 "rawDPCMSlice"       TargetBridge-Sender/TBDisplayShared
want "wire packet: receiver log"         1 "receiverLog"        TargetBridge-Sender/TBDisplayShared
want "receiver packet handlers"         1 "RAW_DPCM_SLICE"     TargetBridge-Receiver/TBReceiverC/src
want "codec built into the receiver"    1 "tb_dpcm"            TargetBridge-Receiver/TBReceiverC/Makefile

echo "== the settings that produced 60 fps ========================"
# Found by reading Apple's docs after the gap had been wrongly declared a floor.
# queueDepth 2 -> 8, and minimumFrameInterval is a THROTTLE, so 60 Hz content
# needs kCMTimeZero rather than CMTime(1,60).
want "SCK queueDepth configured"        1 "queueDepth"             TargetBridge-Sender/TBDisplaySender
want "minimumFrameInterval = zero"      1 "minimumFrameInterval"   TargetBridge-Sender/TBDisplaySender
want "pixel-buffer lock (backpressure)" 1 "CVPixelBufferLockBaseAddress" TargetBridge-Sender/TBDisplaySender
want "depth-probe backoff"              1 "tenBitProbeInterval"    TargetBridge-Sender/TBDisplaySender
want "in-flight budget per band"        1 "packetsPerFrame"        TargetBridge-Sender/TBDisplaySender

echo "== receiver robustness ======================================"
want "parser read cursor"               1 "parser_maybe_compact"   TargetBridge-Receiver/TBReceiverC/src
want "parser bounded reads"             1 "parser_reclaim_for"     TargetBridge-Receiver/TBReceiverC/src
want "parser cost regression test"      1 "backlog_cost_stays_linear" TargetBridge-Receiver/TBReceiverC/tests
want "threaded receive"                 1 "link_reader_main"       TargetBridge-Receiver/TBReceiverC/src
want "video queue (never block reader)" 1 "TB_VIDEO_QUEUE"         TargetBridge-Receiver/TBReceiverC/src
want "async present"                    1 "TB_ASYNC_PRESENT"       TargetBridge-Receiver/TBReceiverC/src

echo "== audio ===================================================="
want "virtual output driver"            1 "libASPL\|TargetBridgeAudioDevice" TargetBridge-AudioDriver TargetBridge-Sender
want "driver installer"                 1 "TBAudioDriverInstaller" TargetBridge-Sender
want "audio wire format"                1 "TBAudioWireFormat"      TargetBridge-Sender
want "microphone capture"               1 "tb_mic_capture"         TargetBridge-Receiver/TBReceiverC/src
want "mic forwarding"                   1 "TBMicForwarder"         TargetBridge-Sender
want "default-output guard"             1 "TBDefaultOutputGuard"   TargetBridge-Sender
want "volume mirroring"                 1 "TBAudioDeviceVolumeObserver" TargetBridge-Sender

echo "== menu bar / display control =============================="
want "V-Sync toggle"                    1 "vsync\|vSync"           TargetBridge-Sender/TBDisplaySender TargetBridge-Sender/TBDisplayShared
want "Night Shift / True Tone"          1 "nightShift\|NightShift\|night_shift" TargetBridge-Sender TargetBridge-Receiver

echo "== seamless start (menu bar + auto-cast) ===================="
# The receiver is a monitor: no Dock icon, no window between sessions, and the
# menu bar as the only way to see or quit it. LSUIElement without the status item
# would leave it running invisibly, so both halves are checked.
want "receiver runs as a menu bar agent"  1 "LSUIElement"          TargetBridge-Receiver/scripts
want "receiver status item"               1 "tb_menubar_start"     TargetBridge-Receiver/TBReceiverC/src
want "status item built in"               1 "tb_menubar"           TargetBridge-Receiver/TBReceiverC/Makefile
want "menu Quit reaches the run loop"     1 "tb_menubar_quit_requested" TargetBridge-Receiver/TBReceiverC/src
want "window hidden between sessions"     1 "TB_WINDOW_HIDDEN"     TargetBridge-Receiver/TBReceiverC/src
want "window mode test"                   1 "test_window_mode"     TargetBridge-Receiver/TBReceiverC/Makefile
want "sender auto-cast rule"              1 "TBAutoCast"           TargetBridge-Sender/TBDisplaySender
want "auto-cast runs on discovery"        1 "evaluateAutoCast"     TargetBridge-Sender/TBDisplaySender
# Without this latch auto-cast reconnects a session the user just stopped, which
# makes the Disconnect button look broken.
want "manual-stop suppression"            1 "autoCastSuppressedByManualStop" TargetBridge-Sender/TBDisplaySender
want "auto-cast survives a launch"        1 "autoCastEnabled"      TargetBridge-Sender/TBDisplaySender
want "auto-cast tests"                    1 "TBAutoCastTests"      TargetBridge-Sender/TBDisplaySenderTests
# A session configured by typing an address has no selectedReceiverID, so
# matching only on service name made the shipped toggle silently do nothing.
want "auto-cast matches a typed address"  1 "rememberedReceiverIP" TargetBridge-Sender/TBDisplaySender
# One unplug used to repoint a session at whatever interface was left (a VM
# bridge, in practice) and never move it back, breaking manual reconnect too.
want "local interface choice survives unplug" 1 "preferredLocalInterfaceIP" TargetBridge-Sender/TBDisplaySender

echo "== latency work ============================================"
want "keep-warm implementation"         1 "TBKeepWarm"             TargetBridge-Sender/TBDisplaySender
want "keep-warm actually started"       1 "keepWarm.start"         TargetBridge-Sender/TBDisplaySender
# One deleted line reinstates a double-release that segfaults on every teardown
# path (cable pull, unlock) with a stack naming nothing of ours. See TBKeepWarm.
want "keep-warm window over-release fix" 1 "isReleasedWhenClosed"  TargetBridge-Sender/TBDisplaySender
want "keep-warm survives display loss"  1 "didChangeScreenParametersNotification" TargetBridge-Sender/TBDisplaySender
want "keep-warm regression tests"       1 "TBKeepWarmTests"        TargetBridge-Sender/TBDisplaySenderTests
# Without this, unplugging leaves the session alive for the ~10s TCP takes to
# give up: virtual display still on screen, frames into a socket nobody reads.
want "link-loss detected by viability"  1 "viabilityUpdateHandler" TargetBridge-Sender/TBDisplaySender
# Damage rectangles were built, measured at 0 rect / 49440 whole frames, and
# removed. Assert the ABSENCE: reintroducing the wire types by merge would have
# the sender emit packets no receiver handles.
gone() {
    local label="$1" pat="$2"; shift 2
    local n
    n=$(grep -rIl -e "$pat" "$@" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -eq 0 ]; then
        PASS=$((PASS+1)); printf '  %s %-46s absent\n' "$(green ok)" "$label"
    else
        FAIL=$((FAIL+1)); printf '  %s %-46s came back in %s file(s)  [%s]\n' \
            "$(red FAIL)" "$label" "$n" "$pat"
    fi
}
gone "damage rects stay removed (sender)" "TBDamageRects\|dpcmRects\|carriedDirty" TargetBridge-Sender/TBDisplaySender TargetBridge-Sender/TBDisplayShared
gone "damage wire types stay removed"     "rawDamage\|rawDPCMRect"                 TargetBridge-Sender/TBDisplayShared
gone "damage handlers stay removed (rx)"  "handle_raw_damage\|handle_raw_dpcm_rect" TargetBridge-Receiver/TBReceiverC/src

echo "== diagnostics =============================================="
want "receiver log shipping"            1 "tb_logship"             TargetBridge-Receiver/TBReceiverC/src
want "sender-side log sink"             1 "TBReceiverLogSink"      TargetBridge-Sender/TBDisplaySender
want "durable sender telemetry"         1 "TBTelemetryReporter"    TargetBridge-Sender/TBDisplaySender
want "receiver health telemetry"        1 "tb_health_start"        TargetBridge-Receiver/TBReceiverC/src
want "health built into the receiver"   1 "tb_health"              TargetBridge-Receiver/TBReceiverC/Makefile
want "wake-up measurement"              1 "tbWakeLong\|wakeLong"   TargetBridge-Sender/TBDisplaySender
want "idle vs wedged discriminator"     1 "tbIdleInputGapMin"      TargetBridge-Sender/TBDisplaySender
# The lossless path silently downgrading is the failure this whole file exists to
# catch late; this makes it visible at runtime instead.
want "resolved video path is logged"    1 "noteResolvedPath"       TargetBridge-Sender/TBDisplaySender

echo "== build tooling ============================================"
want "self-contained x86_64 bundle"     1 "build_x86_bundle"       TargetBridge-Receiver/scripts

echo "== Xcode project still includes our sources ================"
# A Swift file can survive a merge while dropping out of the target, which
# compiles fine and silently removes the feature.
for f in TBKeepWarm TBDPCMAsyncEncode TBReceiverLogSink TBTelemetryReporter; do
    want "pbxproj lists $f" 1 "$f" TargetBridge-Sender/TargetBridge.xcodeproj/project.pbxproj
done

if [ "$FULL" = "1" ]; then
    echo "== builds and tests ========================================"
    if make -C TargetBridge-Receiver/TBReceiverC test >/tmp/vf_tests.log 2>&1; then
        PASS=$((PASS+1)); printf '  %s receiver test suite\n' "$(green ok)"
        grep -E "checks passed" /tmp/vf_tests.log | sed 's/^/       /'
    else
        FAIL=$((FAIL+1)); printf '  %s receiver test suite (see /tmp/vf_tests.log)\n' "$(red FAIL)"
    fi

    if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
       bash TargetBridge-Sender/scripts/build_targetbridge_sender_app.sh >/tmp/vf_sender.log 2>&1; then
        PASS=$((PASS+1)); printf '  %s sender builds\n' "$(green ok)"
    else
        FAIL=$((FAIL+1)); printf '  %s sender build (see /tmp/vf_sender.log)\n' "$(red FAIL)"
    fi

    if bash TargetBridge-Receiver/scripts/build_x86_bundle.sh >/tmp/vf_recv.log 2>&1; then
        PASS=$((PASS+1)); printf '  %s x86_64 receiver builds\n' "$(green ok)"
    else
        FAIL=$((FAIL+1)); printf '  %s x86_64 receiver build (see /tmp/vf_recv.log)\n' "$(red FAIL)"
    fi
fi

echo
printf '%s passed, %s failed\n' "$(green $PASS)" "$([ "$FAIL" -gt 0 ] && red $FAIL || echo 0)"
exit "$FAIL"
