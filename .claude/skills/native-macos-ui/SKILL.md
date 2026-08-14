---
name: native-macos-ui
description: Build TargetBridge's AppKit/SwiftUI interface. Use when working on the menu bar item, the status item's menu, the Settings window, SF Symbols, popovers or panels, or when something renders blank, unreadable, or subtly unlike macOS.
---

Every trap below fails **silently** — no crash, no warning, no log. That is what
makes them expensive: the symptom always points somewhere other than the cause.

## Do not rebuild what the framework provides

A custom `NSPanel` cannot reproduce a menu's appearance. macOS gives real menus a
system backdrop that `NSVisualEffectView` only approximates — side by side with
Control Centre, every material reads as flat grey. Six iterations were spent on
this before switching to an `NSMenu` with custom SwiftUI views inside menu items:
the content stays ours, while material, alignment, dismissal, highlight and
keyboard handling become the system's. That deleted ~80 lines of workaround.

`TBDisplaySenderStatusItemController` already does this correctly. Extend it.

## Sizing: AppKit wants a frame, SwiftUI does not supply one

- **`NSMenuItem` sizes its row from `view.frame`.** `NSHostingView` never sets one,
  so the item exists at zero height and the menu renders as though it were absent.
  Call `layoutSubtreeIfNeeded()`, read `fittingSize`, assign `frame`.
- **`NSPopover` does not follow its content** unless the hosting controller sets
  `sizingOptions = .preferredContentSize`. Content draws and is clipped — identical
  in appearance to a feature that never rendered.

## The status item

- **Verify SF Symbol names exist before using them.** `NSImage(systemSymbolName:)`
  returns nil for an unknown name and assigning nil blanks the item. `display.2`
  exists; `display.2.fill` does not. A three-line program settles it; reasoning
  does not.
- **Keep the image `isTemplate = true`.** `contentTintColor` applies only to
  templates. A non-template symbol draws in its own colour — invisible on a dark
  menu bar.
- **Use `title` + `font`, never `attributedTitle`, for menu bar text.** An
  attributed string with no colour draws black, and an explicit colour cannot
  adapt to light vs dark. Plain title lets AppKit colour it correctly.
- **Numbers need `monospacedDigitSystemFont`**, or the whole menu bar shifts
  sideways every time the value changes.

## SwiftUI state

- **Never churn identities.** Rebuilding a model array mints fresh `UUID`s while
  views still hold the old ones, and the next `firstIndex(...)!` traps. Create
  entities once and change only their attributes. A safer unwrap hides the bug as
  silently wrong bindings rather than fixing it.
- **`NSViewRepresentable` is rebuilt freely.** An event monitor registered in
  `makeNSView` and never removed leaks one per rebuild, so a single key press fires
  the handler several times. Own it in the `Coordinator`; remove it on teardown.
- **`Material` blurs what is inside its own window** — useless in a borderless
  panel over the desktop.

## Current API

When a status item must present its own window, use the **expanded interface
session API** (WWDC26, "Modernize your AppKit app") rather than overriding
`canBecomeKey` and running a global click monitor.
