# TargetBridge

A 5K60 lossless display link: MacBook Pro (arm64 sender) → 2020 Retina 5K iMac
(x86_64 receiver) over Thunderbolt Bridge. The goal is that it feels like a real
monitor, so latency and stability outrank features.

## Two apps, one wire

The sender is a SwiftUI/Xcode app. The receiver is a hand-built self-contained
x86_64 bundle. They agree only on `proto.h` / `TBMonitorProtocol.swift` — keep
packet IDs in step across both, or the ends disagree silently.

**Rebuild the receiver only when the wire format or receiver code changes.**
Sender-only work — encoder internals, capture, pacing, UI — does not touch it,
and the x86 build is slow enough that this matters.

## Build and install

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash TargetBridge-Sender/scripts/build_targetbridge_sender_app.sh   # sender
bash TargetBridge-Receiver/scripts/build_x86_bundle.sh              # receiver (x86_64)
bash TargetBridge-Shared/scripts/verify_features.sh                 # must stay at 0 failed
```

Use those scripts rather than `xcodebuild` directly — the signing step at the end
is load-bearing, and the script explains why in place.

**`/Applications/TargetBridge.app` is the canonical install.** Installing is a
sequence, not a copy, and the whole sequence runs every time:

1. quit the running app
2. `tccutil reset ScreenCapture com.targetbridge.sender`, same for `Accessibility`
3. remove the old bundle, `ditto` the new one, `xattr -cr`
4. restore `Contents/Resources/TargetBridge.driver` — Debug builds omit the audio
   driver, so a clean install loses it — then re-sign, because restoring it breaks
   the seal
5. launch

Propose a build and wait for agreement before running one.

## Measure first

This project's expensive mistakes have all been the same mistake: a mechanism
reasoned out, then built, then found wrong. Six theories for one connect failure
cost two days. Three fixes for one cursor stall each targeted the wrong layer.

So: take a measurement before proposing a cause, and say plainly when a fix is
unproven. When something is wrong with the link, read
`.claude/skills/debug-the-link/SKILL.md` first — it lists which instruments here
lie, the diagnostic order that works, and the theories already falsified so they
are not re-chased.

Codec changes ship only when proven bit-exact against the CPU reference in
`TargetBridge-Shared/codec/tb_dpcm.c`.

## Runtime flags

Behaviour switches live in `defaults` under `com.targetbridge.sender`
(`TBVirtualRefresh`, `TBMaxSendFPS`, `TBPhaseLock`, `TBSliceCount`, …). Each is
documented at its point of use in `TBDisplaySenderService.swift`. Ask before
writing one — a flag change is a behaviour change.
