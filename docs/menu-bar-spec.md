# Menu bar — specification

Companion to `monitors-window-spec.md`. Covers the status item's menu only.

Status: **partially built.** The fps in the icon and the per-screen filtering of
which monitor's controls appear are live. Everything in §2 is not.

## 1. Principle

**The menu bar acts; Settings configures.** Day to day: click the icon, pick a
monitor, adjust brightness. Anything you set once and forget belongs in the
window, not here.

**Controls follow the screen the menu was opened on.** macOS puts the menu bar on
every display, so opening it on a streamed display identifies that display —
no picker, no "selected monitor", no state. Opened on this Mac's own screen there
is nothing to disambiguate, so all monitors are listed. *(Built, unverified.)*

**AppKit, not SwiftUI.** Custom menu-item views follow `TBMenuToggleRowView`:
explicit geometry, `TBMenuMetrics.width`/`.inset`, `preferredHeight`. A real
`NSMenu` gets the system's material, alignment, dismissal and keyboard handling —
six prototype iterations of a custom `NSPanel` never matched it. See
`.claude/skills/native-macos-ui/SKILL.md`.

## 2. What is missing

### 2.1 Monitor rows — the point of the whole thing

The menu has **no receiver list**, so there is no way to start streaming from it.
This was the original request: *"I go to menu bar, click which monitor to
connect."*

One row per entry in `service.discoveredReceivers`, plus any session already
connected. Each row (new `TBMenuMonitorRowView`, modelled on
`TBMenuToggleRowView`):

| element | source |
|---|---|
| circular icon, accent-filled when streaming | `session.isStreaming` |
| name | `receiver.displayText` / `service.sessionTitle(for:)` |
| subtitle | streaming → `fps · latency · codec`; idle → "Available"; failed → error, in red |
| click action | connect if idle, disconnect if streaming |

Connecting from a row must go through `service.applyDiscoveredReceiver(_:to:)`
then `session.connect()` — the same path the window uses. Do not invent a second
one.

### 2.2 Setup helper

When `service.discoveredReceivers` is empty and no session is connected, replace
the rows with two steps: install the receiver on the other Mac and open it;
connect Thunderbolt or share a network. A disabled `NSMenuItem` with an attributed
string is enough — this is not a place for a custom view.

### 2.3 Settings item

`Settings…` with key equivalent `,` opening the main window. Currently the item
is `showMainWindow` with no shortcut.

## 3. Keep

Already correct, do not regress:

- brightness slider with end glyphs (`makeSliderItem`)
- `TBMenuToggleRowView` — Night Shift / True Tone / V-Sync
- per-session header when more than one is shown
- Add / Stop all / Hide icon / Quit
- **No volume slider** — the system Sound slider already drives the receiver when
  the TargetBridge audio device is selected, and a second control disagrees with it
- fps in the status item, `labelColor` + monospaced digits, no `contentTintColor`

## 4. Rules

1. Reuse `TBDisplaySenderL10n` keys; `check_localizations.sh` must keep passing
   for de/en/fr/it/zh.
2. Rebuild menu contents in `menuNeedsUpdate(_:)`. Never swap `item.menu` while
   tracking — it strands an invisible menu window that swallows clicks.
3. Retain custom row views for the menu's lifetime, as `sliderTargets` and
   `toggleRows` already do; `NSMenuItem.view` does not retain its targets.
4. `NSMenuItem` sizes its row from `view.frame`. Set it explicitly or the item is
   present at zero height and invisible.

## 5. Acceptance

- [ ] Every row in §2 present and bound
- [ ] Connecting from a row starts a stream
- [ ] `verify_features.sh` and `check_localizations.sh` pass
- [ ] A human has opened the menu and seen it — "it builds" is not acceptance
