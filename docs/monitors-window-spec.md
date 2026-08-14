# Monitors window — specification

Status: **spec agreed, partially built.** `TBMonitorsWindowView` exists and
compiles but is NOT mounted; `TBDisplaySenderApp` still shows
`TBDisplaySenderContentView`. Swapping it in is one line, and must not happen
until §3 is complete.

## 1. Why

The main window had four levels for one display's settings: window → session
card → per-session settings sheet → separate Settings window. The user's summary
was "everything is a mess", and the mess is structural, not visual.

**A monitor is the unit.** Everything about one display lives on one page. No
sheet, no level to descend into.

The word **"session" does not appear in the UI**. Sessions still exist internally
and more than one can stream at once; they are called monitors, because that is
what they are to the person using them.

## 2. What already exists

- **Sidebar** of monitors: status dot (green streaming / yellow connected /
  grey idle), title, status line. Local interface summary pinned at the bottom.
- **Monitor page** with: Connect/Disconnect + receiver IP + status footer;
  stream resolution; brightness; Night Shift; True Tone; V-Sync; stream audio;
  volume; prevent sleep; auto-restart; large cursor; collapsed Diagnostics
  (sender fps, capture display, virtual display, receiver panel, restart capture).
- **Empty state** with two setup steps.
- Add / Remove monitor in the toolbar and page.

## 3. What is MISSING — the reason this is not mounted

Everything below lived in the per-session **settings sheet**. Mounting the new
window without it made all of it unreachable, including streaming quality. This
is the change request.

### 3.1 New section: Connection

| control | binding | source of options |
|---|---|---|
| Transport | `session.transportKind` | `service.availableTransportKinds` |
| Local interface | `session.localInterfaceIP` | `service.availableInterfaces(for:)` |
| Discovered receiver | `session.selectedReceiverID` | `service.discoveredReceivers` |
| Receiver address (manual) | `session.receiverIP` | free text, placeholder `169.254.x.x / 192.168.x.x` |
| Cable test | `session.startCableTest()` | shows `session.isCableTesting` while running |
| Check configuration | `service.configurationChecks()` | renders the returned check list |

Selecting a discovered receiver must still call
`service.applyDiscoveredReceiver(...)`, and changing transport must still call
`service.transportDidChange(...)` — the old sheet did both, and dropping either
silently breaks connecting.

### 3.2 New section: Stream

| control | binding |
|---|---|
| **Stream profile** (resolution / refresh / depth) | `session.capturePreset` over `TBDisplayCapturePreset.allCases` |
| Capture source | `session.captureSource` over `TBDisplayCaptureSource.allCases` |
| Match render to stream | `session.matchRenderToStream` |
| Display profiles | buttons over `TBDisplayProfile.allCases` → `service.applyDisplayProfile(...)` |

**Stream profile is the "streaming quality" control.** It is the single most
important item on this list.

### 3.3 New section: Input

| control | binding |
|---|---|
| Input control role | `session.inputControlRole` via `service.setInputControlRole(...)` |
| Gesture mode | `session.inputGestureMode` |

Includes the buttons to open Accessibility and Input Monitoring settings
(`service.openAccessibilitySettings()`, `service.openInputMonitoringSettings()`).

### 3.4 Not in scope

The separate **Settings scene** (⌘,) — language, menu bar icon, verbose logging,
prevent sleep, auto-restart, large cursor — stays exactly as it is. It was never
affected. Do not fold it in.

## 4. Rules

1. **Reuse existing `TBDisplaySenderL10n` keys.** Inventing keys breaks
   `check_localizations.sh`, which must keep passing for de/en/fr/it/zh. New
   strings need real catalogue entries, not inline English. The current file has
   ~7 inline English strings (Brightness, Night Shift, True Tone, V-Sync, Volume,
   Diagnostics, About) that should become proper keys.
2. **Native chrome only** — `Form`/`.formStyle(.grouped)`, `Section`,
   `LabeledContent`, system fonts. No bespoke cards, gradient tiles or status
   chips; looking like macOS is mostly not overriding it.
3. **Every control in §3 must be reachable before mounting.** Count them against
   this table, do not judge by eye.
4. **Keep `TBDisplaySenderContentView` compiling** until the swap is verified in
   front of a human, so reverting stays one line.

## 5. Acceptance

- [ ] Every row in §3.1–§3.3 present and bound
- [ ] `verify_features.sh` 64+ passing, `check_localizations.sh` passing
- [ ] No inline English strings left
- [ ] A human has looked at it with a live stream — it builds and launches is
      NOT acceptance; that was claimed twice and was wrong both times
- [ ] Then, and only then, swap the one line in `TBDisplaySenderApp`

## 6. History

Built and mounted at `f6bfb48`, reverted at `123908f` when the missing sheet was
found. The lesson recorded: the inventory in §3 came from reading the sheet, and
reading it FIRST would have prevented shipping a window that silently removed
streaming quality.
