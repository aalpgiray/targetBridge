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
