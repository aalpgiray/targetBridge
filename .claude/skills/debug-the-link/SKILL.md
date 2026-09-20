---
name: debug-the-link
description: Diagnose the TargetBridge display link. Use when the stream stalls, bogs, judders, drops frames or the cursor lags; when Connect fails or reports NWError 50; when the audio device disappears; when the receiver freezes or crashes; or before trusting any number this project's telemetry reports.
---

Every hour lost on this link was lost the same way: a plausible mechanism, built
before it was measured. This document is the accumulated cost of that — the
instruments that lie, the order that finds faults fast, and the theories already
falsified.

Work through **Instruments that lie** before quoting any number as evidence.

## Instruments that lie

Each of these read *healthy* while the thing they name was broken.

- **`cadence capture(pts)`** bins against the arrival interval now, but any
  histogram with a hardcoded reference period goes blind when that period
  changes — and fails by looking *perfect*. At 120 Hz capture an 8.33 ms gap is
  0.5 periods, Swift rounds half away from zero, and every arrival landed in
  bin 1: a flawless 60 Hz cadence that was measuring nothing. Trust
  `interval X.XXms (YYYHz)`, which states the rate outright.
- **A full 60 fps with zero drops is not health.** The bad-phase stall shows
  `drawable 16.6ms`, `submit` 98% and 27 ms cursor latency while every rate
  counter reads perfect. Rate counters cannot see it; the receiver's `drawable`
  wait is the only instrument that can.
- **`nc -z` proves only that the kernel completed a handshake.** The kernel does
  that whether or not the app ever calls `accept()`. A receiver that has stopped
  accepting passes this test.
- **Discovery working is not permission.** Bonjour browsing is brokered by
  `mDNSResponder`, which has its own access, so the receiver keeps appearing in
  the selector while the app's own sockets are denied.
- **`log show` returns nothing for `com.targetbridge.sender`.** Use `log stream`
  from a **script file** — zsh mangles the predicate inline.
- **`.ips` crash-report mtime lies.** Read the `captureTime` JSON field; the
  filename timestamp is process launch.
- **`lsof` ORs its filters.** Without `-a` you get every process on the machine.
- **`system_profiler SPAudioDataType` is unreliable.** Query
  `kAudioHardwarePropertyDevices` directly.
- **`open` passes no environment variables** to a LaunchServices-launched app, and
  drives a new instance rather than one started from a terminal.

## Where the evidence is

`~/Library/Logs/TargetBridge/receiver.log` carries **both** ends: the receiver
ships its stderr to the sender over the wire, and sender telemetry is written to
the same file. One file, both machines. It has no rotation.

## Connect fails

Run in this order. It finds in ten minutes what reasoning did not find in two days.

1. `lsof -a -p <pid> -i -nP` — does the app hold a socket at all?
2. `log stream --level debug --predicate 'subsystem == "com.targetbridge.sender"'`
   from a script file.
3. Drive it directly rather than asking someone to click:
   `open "targetbridge://connect?receiver=10.0.1.2&localip=10.0.1.1"`.
4. Diff the app against a working `nc` invocation, parameter by parameter.
5. Build a minimal bundled `.app` that only dials, and **time every state
   transition**. A bare terminal binary is not a substitute — bundled and
   terminal-launched behave differently, and that difference has been the bug.

**Read the error's own words.** `timed out … last network state: waiting` is a
self-describing bug report: still waiting, and we quit. `.waiting` is recoverable,
not fatal.

## A protective condition gated on the wrong signal (2026-09-20)

Symptom: every connect died within ~1s of "sent display profile", 100%
reproducible, immediately after deploying a receiver-side grace period meant
to protect a freshly-live session from being killed by the sender's own
overlapping reconnect dial (see main.c's accept-loop comment, `have_video_frame
&& since_last_recv_ms < TB_NEW_SESSION_GRACE_MS`).

PROVEN, by measurement (parallel `log stream` + ssh `tail -f` on
receiver-local.log, correlated by timestamp):
  - The receiver's own log showed the FULL handshake completing normally
    (`client connected` -> `session started` -> `sent display profile`) and
    then, before any video frame, a second dial landing and immediately
    winning: `new dial while session live: old link is dead, replacing
    session` -- the receiver's OWN accept loop, not the sender, tore the live
    handshake down.
  - The condition required `a.have_video_frame` to be true before the grace
    period would protect a session at all. A session still in its handshake
    (hello sent, caps exchanged, capture pipeline not yet started, zero
    frames decoded) had `have_video_frame == 0`, so ANY second dial in that
    window -- including a harmless one-shot control connection unrelated to
    streaming (the sender's `sendLanguageUpdate()` opens and closes a bare
    NWConnection to the same port) -- read as proof the real session was dead
    and killed it.
  - Confirmed independently on a second capture (sleep/wake test): repeated
    clean EOFs (`isDone=true error=none`) landing within ~1s of connect at
    varying handshake stages (creatingVirtualDisplay, startingCapture,
    captureStartedWaitingFirstFrame) -- consistent with the receiver actively
    closing right after accept, not a network-level failure, and consistent
    with intermittent/racy rather than 100% once the reconnect backoff
    happened to avoid landing a second dial inside the unprotected window.
  - Once a session lived long enough to decode one frame, `have_video_frame`
    flipped true and the SAME session became protected — this is why the link
    worked for extended, confirmed 60fps streams earlier the same night with
    the exact same deploy: the failure needed a second dial to land inside
    the narrow pre-first-frame window, which is timing-dependent.

LESSON: when a new "is this session real" check ANDs together a boolean
milestone (has it produced output yet) with a recency clock, audit what
happens before that milestone is ever reached — a freshly-accepted session is
maximally real and maximally vulnerable in exactly that window, and gating
protection on a milestone it hasn't hit yet inverts the intended effect. The
recency clock alone (time since last real bytes, stamped at accept) was
already a correct, self-terminating freshness signal — a genuinely dead
session still ages past the grace window the same way, so it was safe to drop
the boolean AND entirely rather than special-casing the pre-first-frame
period.

FALSIFIED as the cause — do not re-chase for this incident:
  - `normalizeSessionInterfaces()` / the 4s `interfaceRefreshTimer` racing the
    sender's own state during an active connection. It fires constantly
    (every 4s, confirmed in the receiver log as bursts of "new dial arrived
    ...ms after current session's last data") but every one of those bursts
    was correctly rejected by the (even the old, buggy) grace-period check
    once a session had a frame — proof this mechanism was not the live
    session's killer, only an unrelated noisy neighbor that happened to be
    new the same night and looked suspicious.
  - The sender tearing itself down for a new reason in `normalizeSessionInterfaces`
    or the interface-preservation logic — the sender-side `log stream` showed
    a clean `connect: ready` -> `hello` sequence with no sender-initiated
    teardown call anywhere near the failure; the receiver's log was the only
    side that recorded an explicit teardown decision.

## Already falsified — do not re-chase

For connect failures: the firewall, TCC, entitlements, a reboot, six reinstalls,
a stale bundle, the audio driver. All checked, none ever involved. The causes
found were a connect deadline sitting below real latency, and ad-hoc signing
handing macOS a new identity on every rebuild.

For cursor stalls: a `dispatch_sync` stall, and a drawable leak that fired **zero**
times across two days of logs.

A deadline sitting just below a real latency fails nearly always but *looks*
intermittent — which is what made several wrong fixes each seem to work once.

## Reducing jitter can create a stuck state

The bad-phase stall used to average out. Cutting send jitter from ±10 ms to ±1 ms
made the phase stable too, so a bad one now persists for minutes. Expect this
class of bug when a fix makes timing steadier.

## Report honestly

State which measurement supports a claim, and say when one does not exist yet.
`phase locked` after a single episode is n=1, and the same shape has been observed
without the feature enabled. Two episodes agreeing is a signature; one is a
coincidence with a story attached.

## ENETDOWN on a healthy link — the state of it, 2026-08-18

Symptom: every dial fails in ~35ms with `POSIXErrorCode 50: Network is down`
while the receiver is provably accepting. Six occurrences in one day.

PROVEN, by measurement:
  - It is not the network. `nc` to the same host:port from the same source IP
    succeeds while the sender is refused. Ping 0.4ms, 0% loss.
  - It is not the receiver. It accepts on 54321 throughout.
  - It is not the address, the route, the interface, or the source pin.
  - It is PER-PROCESS-IDENTITY. A freshly signed control bundle using identical
    NWConnection parameters connects instantly while the sender cannot.
  - A rebuild always clears it, and only because the build produces a new
    LC_UUID. NECP keys on the main executable's UUID. Before
    ENABLE_DEBUG_DYLIB: NO, rebuilding unchanged source reproduced the SAME uuid
    (the debug stub never relinks), which is why "just rebuild" used to work only
    when a source file happened to change too.

FALSIFIED — do not re-chase these:
  - "It degrades with streaming duration." No. Identities have died in 4 min and
    13 min, and one survived 17 hours -- but that one was IDLE overnight, not
    streaming, and failed on its first dial afterwards.
  - "Rapid connect/disconnect churn poisons it." Fitted the short-lived cases and
    was then contradicted by the idle-overnight case.
  - "macOS throttles heavy apps' networking." No such mechanism exists. App Nap,
    thermal throttling and jetsam do not revoke network access.
  - Local Network privacy state: the app's LC_UUID is present and unique, the
    designated requirement is stable (cert-signed), no duplicate UUID on the
    machine. LaunchServices had 19 stale registrations; cleaning them to 2
    changed nothing.

STILL UNKNOWN: what poisons the identity. There is no measured variable that
predicts both the failures and the survivals.

WHAT TO DO WHEN IT HAPPENS: rebuild the sender (any source change, or just
`touch` a file) and install. That is a workaround for OS-side state we cannot
reset -- Apple provides no supported way to clear local network privacy on macOS
(radar 134842755) -- not a fix.
