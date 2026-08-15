import AppKit
import SwiftUI
import Combine

@MainActor
final class TBDisplaySenderStatusItemController: NSObject {
    private let service: TBDisplaySenderService
    nonisolated(unsafe) private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var hasActivated = false
    // Retains the target objects for the current menu's sliders (NSSlider holds
    // its target weakly). Cleared and rebuilt each time the menu opens.
    private var sliderTargets: [TBMenuSliderTarget] = []
    private var toggleRows: [TBMenuToggleRowView] = []
    // NSMenuItem.view does not retain the target of its subviews' actions.
    private var monitorRows: [TBMenuMonitorRowView] = []

    init(service: TBDisplaySenderService) {
        self.service = service
        super.init()
        bind()
        observeApplicationLifecycle()
    }

    deinit {
        let item = statusItem
        DispatchQueue.main.async { [item] in
            if let item {
                NSStatusBar.system.removeStatusItem(item)
            }
        }
    }

    private func bind() {
        service.$showsMenuBarIcon
            .sink { [weak self] _ in
                guard let self, self.hasActivated else { return }
                self.syncVisibility()
            }
            .store(in: &cancellables)

        service.objectWillChange
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &cancellables)
    }

    private func observeApplicationLifecycle() {
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in
                self?.activate()
            }
            .store(in: &cancellables)
    }

    func activate() {
        guard !hasActivated else { return }
        hasActivated = true
        syncVisibility()
    }

    private func syncVisibility() {
        if service.showsMenuBarIcon {
            ensureStatusItem()
            refreshStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = TBDisplaySenderL10n.topBarToolTip(service.language)

        // Assign one menu instance for the lifetime of the status item and
        // repopulate it lazily in `menuNeedsUpdate(_:)`. Swapping `item.menu`
        // out from under an open/tracking menu leaves macOS holding an
        // orphaned, invisible menu window that swallows clicks at the menu's
        // location — the "dead zone" below the menu bar icon.
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        applyStatusAppearance()
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func refreshStatusItem() {
        applyStatusAppearance()
    }

    /// The frame rate beside the glyph, laid out like the battery item: value on
    /// the left, symbol on the right, and nothing at all while idle so a full menu
    /// bar gets the width back.
    ///
    /// Three details are load-bearing, and each one fails silently if missed:
    ///   - `title`, never `attributedTitle`. An attributed string with no colour
    ///     draws BLACK, and an explicit colour cannot adapt to a light vs dark menu
    ///     bar. Only a plain title lets AppKit colour it correctly.
    ///   - `isTemplate = true`. `contentTintColor` applies only to template images;
    ///     a non-template symbol draws in its own colour, invisible on a dark bar.
    ///   - monospaced digits, or the whole menu bar shifts sideways every time the
    ///     rate ticks between 59 and 60.
    private func applyStatusAppearance() {
        guard let button = statusItem?.button else { return }

        let live = service.sessions.filter { $0.isConnected }
        let fps = live.map(\.liveMetrics.senderFPS).max() ?? 0
        let streaming = !live.isEmpty

        // Verified to exist. NSImage(systemSymbolName:) returns nil for an unknown
        // name and assigning nil blanks the item -- "display.2.fill" does NOT exist,
        // which once made the icon vanish exactly while streaming.
        let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "TargetBridge")
        image?.isTemplate = true
        if image == nil { button.title = "TB" }
        button.image = image

        if streaming, fps > 0 {
            // attributedTitle WITH an explicit dynamic colour.
            //
            // The trap is subtle and cost three wrong fixes: attributedTitle with
            // NO colour attribute draws black, so it is unreadable on a dark menu
            // bar -- but a plain `title` combined with contentTintColor is worse,
            // because the accent colour is a user preference that can resolve dark
            // (graphite), and it then tints the glyph too. Measured: labelColor
            // resolves to white on dark and black on light, so it is the only
            // option that adapts in BOTH directions while keeping monospaced
            // digits, which stop the bar shifting as the rate ticks.
            button.attributedTitle = NSAttributedString(
                string: "\(fps) ",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ])
            button.imagePosition = .imageRight
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        }
        button.contentTintColor = nil
        button.toolTip = TBDisplaySenderL10n.topBarToolTip(service.language)
    }

    /// The session shown on the screen this menu was opened from, if any.
    ///
    /// macOS puts the menu bar on every display, so opening the menu ON a streamed
    /// display identifies that display -- no picker, no mode, no state to track.
    /// Returns nil when opened from the Mac's own screen, where "which monitor" has
    /// no answer and the menu should simply list them.
    private func sessionForMenuScreen() -> TBDisplaySenderSession? {
        guard let screen = statusItem?.button?.window?.screen,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        return service.sessions.first(where: { $0.isConnected && $0.virtualDisplayID == displayID })
    }

    /// One row per discovered receiver, plus any connected session that discovery
    /// is not currently reporting (a manually entered address, or a receiver that
    /// has stopped advertising while still streaming).
    private func addMonitorRows(to menu: NSMenu) {
        var rows: [TBMenuMonitorSpec] = []
        // Match on EVERY address a receiver advertises, not just the preferred
        // one. A receiver reachable over both Thunderbolt and Wi-Fi publishes two
        // addresses; the session dialled one of them, so comparing against a
        // single field lists the same machine twice -- once as connected and once
        // as available.
        var seenIP = Set<String>()

        for session in service.sessions where session.isConnected {
            seenIP.insert(session.receiverIP)
            rows.append(TBMenuMonitorSpec(
                symbol: "display",
                title: service.sessionTitle(for: session),
                subtitle: session.statusText,
                isStreaming: session.isStreaming,
                isError: false,
                onTap: { [weak session] in session?.stop() }))
        }

        for receiver in service.discoveredReceivers {
            let addresses = [receiver.preferredIP, receiver.thunderboltIP, receiver.networkIP]
                .filter { !$0.isEmpty }
            if addresses.contains(where: { seenIP.contains($0) }) { continue }
            rows.append(TBMenuMonitorSpec(
                symbol: "display",
                title: receiver.displayText,
                subtitle: TBDisplaySenderL10n.statusChipIdle(service.language),
                isStreaming: false,
                isError: false,
                onTap: { [weak self] in self?.connect(to: receiver) }))
        }

        if rows.isEmpty {
            addSetupHelp(to: menu)
            return
        }

        for spec in rows {
            let view = TBMenuMonitorRowView(spec: spec,
                                            width: TBMenuMetrics.width,
                                            leadingInset: TBMenuMetrics.inset)
            let item = NSMenuItem()
            // NSMenuItem sizes its row from the view's frame; the initialiser sets
            // it, and without one the item is present at zero height.
            item.view = view
            menu.addItem(item)
            monitorRows.append(view)
        }
    }

    /// Nothing found. Says what to do rather than simply reporting emptiness --
    /// this is the first thing a new user sees, and "no displays" alone is a dead
    /// end. A disabled item is enough; this does not need a custom view.
    private func addSetupHelp(to menu: NSMenu) {
        let text = TBDisplaySenderL10n.discoveryHint(service.language)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        item.isEnabled = false
        menu.addItem(item)
    }

    /// Connect through the SAME path the window uses. A second route would drift
    /// out of step with it -- applyDiscoveredReceiver also settles the transport
    /// and local interface, and skipping it dials a stale address.
    private func connect(to receiver: TBDiscoveredReceiver) {
        let session = service.sessions.first(where: { !$0.isConnected })
            ?? service.sessions.first
        guard let session else { return }
        // applyDiscoveredReceiver resolves the address via receiver.ip(for:), which
        // returns the THUNDERBOLT address when the session's transport is
        // Thunderbolt. Reaching for preferredIP here instead would silently dial
        // the Wi-Fi address of a machine sitting on a Thunderbolt bridge -- the
        // difference between a lossless 5K60 link and one that cannot carry it.
        service.applyDiscoveredReceiver(receiver, to: session)
        session.connect()
    }

    private func rebuildMenuItems(in menu: NSMenu) {
        menu.removeAllItems()
        sliderTargets.removeAll()
        toggleRows.removeAll()
        monitorRows.removeAll()

        // No title, no summary line.
        //
        // "TargetBridge" restates the icon that was just clicked, and "1 active
        // sessions of 1" is both the retired session vocabulary and a count the
        // monitor rows below already show -- each carries its own name and live
        // status. Two dead rows before the first useful one.

        // The monitor list: the reason the menu bar is useful on its own. Without
        // it there is no way to start streaming without opening the main window.
        addMonitorRows(to: menu)

        // Brightness / volume sliders for each connected session. Reliable and
        // native-feeling: they drive the receiver directly via the existing
        // brightness/volume path — no event taps, no cursor/keyboard routing.
        // Opened ON one of our displays: show just that display's controls, since
        // that is unambiguously the one being looked at. Opened from this Mac's own
        // screen: show them all, because there is nothing to disambiguate against.
        let allConnected = service.sessions.filter { $0.isConnected }
        let focused = sessionForMenuScreen()
        let connectedSessions = focused.map { [$0] } ?? allConnected
        if !connectedSessions.isEmpty {
            menu.addItem(.separator())
            for session in connectedSessions {
                if connectedSessions.count > 1 {
                    let header = NSMenuItem(title: service.sessionTitle(for: session), action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                menu.addItem(makeSliderItem(symbol: "sun.min.fill",
                                            trailingSymbol: "sun.max.fill",
                                            label: brightnessMenuLabel(),
                                            value: session.brightness) { [weak session] value in
                    session?.brightness = value
                })
                // No volume slider: with the TargetBridge audio device selected,
                // macOS's own Sound slider and the F11/F12 keys already drive the
                // receiver's hardware volume, so a second control here would just
                // be a duplicate that can disagree with the system one.
                var toggles: [TBMenuToggleSpec] = []
                if session.receiverSupportsNightShift {
                    toggles.append(TBMenuToggleSpec(
                        symbol: "sun.lefthalf.filled",
                        title: nightShiftMenuLabel(),
                        stateText: session.nightShiftEnabled ? onWord() : offWord(),
                        isOn: session.nightShiftEnabled) { [weak session] on in
                            session?.nightShiftEnabled = on
                        })
                }
                if session.receiverSupportsTrueTone {
                    toggles.append(TBMenuToggleSpec(
                        symbol: "sun.max.fill",
                        title: trueToneMenuLabel(),
                        stateText: session.trueToneEnabled ? onWord() : offWord(),
                        isOn: session.trueToneEnabled) { [weak session] on in
                            session?.trueToneEnabled = on
                        })
                }
                // Shown unconditionally: unlike Night Shift and True Tone, which
                // are panel hardware a receiver may not have, this is a property
                // of the receiver's own render path. An older receiver ignores
                // the field, which is the same outcome as leaving it alone.
                toggles.append(TBMenuToggleSpec(
                    symbol: "arrow.triangle.2.circlepath",
                    title: vsyncMenuLabel(),
                    stateText: session.vsyncEnabled ? onWord() : offWord(),
                    isOn: session.vsyncEnabled) { [weak session] on in
                        session?.vsyncEnabled = on
                    })

                if !toggles.isEmpty {
                    let row = TBMenuToggleRowView(specs: toggles,
                                                  width: TBMenuMetrics.width,
                                                  leadingInset: TBMenuMetrics.inset)
                    row.onWord = onWord()
                    row.offWord = offWord()
                    let item = NSMenuItem()
                    item.view = row
                    menu.addItem(item)
                    toggleRows.append(row)
                }
            }
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: TBDisplaySenderL10n.showMainWindow(service.language),
            action: #selector(showMainWindow),
            keyEquivalent: ","
        )
        openItem.target = self
        menu.addItem(openItem)

        let addItem = NSMenuItem(
            title: TBDisplaySenderL10n.addSessionButton(service.language),
            action: #selector(addSession),
            keyEquivalent: ""
        )
        addItem.target = self
        menu.addItem(addItem)

        let stopAllItem = NSMenuItem(
            title: TBDisplaySenderL10n.stopAllButton(service.language),
            action: #selector(stopAll),
            keyEquivalent: ""
        )
        stopAllItem.target = self
        stopAllItem.isEnabled = service.anyConnected
        menu.addItem(stopAllItem)

        // The verbose connection/IP details live behind a submenu so the default
        // menu stays focused on the useful actions.
        if !service.localInterfaces.isEmpty || !service.sessions.isEmpty {
            let infoItem = NSMenuItem(title: connectionInfoMenuLabel(), action: nil, keyEquivalent: "")
            let infoSubmenu = NSMenu()
            if !service.localInterfaces.isEmpty {
                let ipItem = NSMenuItem(title: TBDisplaySenderL10n.topBarIP(service.language, service.localInterfaceSummaryText), action: nil, keyEquivalent: "")
                ipItem.isEnabled = false
                infoSubmenu.addItem(ipItem)
            }
            for session in service.sessions {
                let line = "\(service.sessionTitle(for: session)): \(session.statusText)"
                let sessionItem = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                sessionItem.isEnabled = false
                infoSubmenu.addItem(sessionItem)
            }
            infoItem.submenu = infoSubmenu
            menu.addItem(infoItem)
        }

        let hideItem = NSMenuItem(
            title: TBDisplaySenderL10n.hideMenuBarIcon(service.language),
            action: #selector(hideStatusItem),
            keyEquivalent: ""
        )
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: TBDisplaySenderL10n.quitApp(service.language), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Builds a menu row with an icon and a 0…1 slider whose changes are pushed
    /// live to `onChange` (which sets `session.brightness`/`.volume`, forwarding
    /// to the receiver).
    /// Brightness row: a small glyph, the system slider, and a larger glyph
    /// closing the row. The trailing icon is what stops the track running to the
    /// edge of the menu.
    ///
    /// Stock NSSlider, deliberately, after two attempts at Control Center's
    /// accent-filled track. `trackFillColor` is set below and menus ignore it.
    /// Overriding NSSliderCell.drawBar does produce the fill, but any drawing
    /// override opts the cell out of AppKit's modern slider rendering and the
    /// knob loses its pressed-state translucency — more noticeable than a grey
    /// track, since it makes the control feel wrong rather than just look plain.
    private func makeSliderItem(symbol: String, trailingSymbol: String, label: String,
                                value: Double, onChange: @escaping (Double) -> Void) -> NSMenuItem {
        let width = TBMenuMetrics.width
        // SwiftUI's Slider, hosted, not a hand-built NSSlider.
        //
        // NSSlider draws an unfilled grey track inside a menu -- trackFillColor is
        // documented but ignored there, which the previous version set and noted.
        // SwiftUI's Slider fills with the accent colour, which is what the
        // prototype looked like and what every Control Centre slider looks like.
        // Hosting one view is cheaper than reimplementing the fill by hand.
        let height: CGFloat = 28
        let row = TBMenuSliderRow(symbol: symbol,
                                  trailingSymbol: trailingSymbol,
                                  label: label,
                                  value: value,
                                  width: width,
                                  inset: TBMenuMetrics.inset,
                                  onChange: onChange)
        let container = NSHostingView(rootView: row)
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let item = NSMenuItem()
        item.view = container
        item.toolTip = label
        return item
    }

    private func brightnessMenuLabel() -> String {
        switch service.language {
        case .italian: return "Luminosità"
        case .french: return "Luminosité"
        case .english: return "Brightness"
        case .german: return "Helligkeit"
        case .chinese: return "亮度"
        }
    }

    private func onWord() -> String {
        switch service.language {
        case .italian: return "Attivo"
        case .english: return "On"
        case .german: return "Ein"
        case .chinese: return "开"
        case .french: return "Activé"
        }
    }

    private func offWord() -> String {
        switch service.language {
        case .italian: return "Non attivo"
        case .english: return "Off"
        case .german: return "Aus"
        case .chinese: return "关"
        case .french: return "Désactivé"
        }
    }

    /// Kept as "V-Sync" in the Latin-script languages: it is the term the setting
    /// is universally known by, and translating it would make it harder to
    /// recognise, not easier.
    private func vsyncMenuLabel() -> String {
        switch service.language {
        case .chinese: return "垂直同步"
        default: return "V-Sync"
        }
    }

    private func nightShiftMenuLabel() -> String {
        switch service.language {
        case .italian: return "Night Shift"
        case .english: return "Night Shift"
        case .german: return "Night Shift"
        case .chinese: return "夜览"
        case .french: return "Night Shift"
        }
    }

    private func trueToneMenuLabel() -> String {
        switch service.language {
        case .italian: return "True Tone"
        case .english: return "True Tone"
        case .german: return "True Tone"
        case .chinese: return "原彩显示"
        case .french: return "True Tone"
        }
    }

    private func volumeMenuLabel() -> String {
        switch service.language {
        case .italian: return "Volume"
        case .french: return "Volume"
        case .english: return "Volume"
        case .german: return "Lautstärke"
        case .chinese: return "音量"
        }
    }

    private func connectionInfoMenuLabel() -> String {
        switch service.language {
        case .italian: return "Info connessione"
        case .french: return "Infos de connexion"
        case .english: return "Connection info"
        case .german: return "Verbindungsinfo"
        case .chinese: return "连接信息"
        }
    }

    // Menu-item handlers run while the menu is still dismissing. Doing work
    // synchronously here (activating the app, ordering windows front, mutating
    // observed session state) interrupts the menu window's fade-out: its alpha
    // animates to 0 but the window is never closed, leaving an invisible
    // menu-layer window that swallows clicks at the menu's footprint. Deferring
    // to the next runloop tick lets the menu fully tear down first.
    private func runAfterMenuDismissal(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    @objc
    private func showMainWindow() {
        runAfterMenuDismissal {
            NSApp.activate(ignoringOtherApps: true)

            // Front an existing window if there is one.
            //
            // A CLOSED SwiftUI WindowGroup window is not merely hidden -- it is
            // gone from NSApp.windows, so the old loop had nothing to front and
            // this menu item silently did nothing. With the window closed and the
            // Dock icon hidden, that left no way back into the app at all.
            if let existing = NSApp.windows.first(where: {
                $0.canBecomeMain && !($0 is NSPanel) && $0.contentView != nil
            }) {
                existing.makeKeyAndOrderFront(nil)
                return
            }
            // Closed WindowGroup windows are destroyed, not hidden, so there is
            // nothing to front -- only SwiftUI can rebuild the scene.
            TBWindowOpener.shared.open?()
        }
    }

    @objc
    private func addSession() {
        runAfterMenuDismissal { [service] in
            service.addSession()
        }
    }

    @objc
    private func stopAll() {
        runAfterMenuDismissal { [service] in
            service.stopAll()
        }
    }

    @objc
    private func hideStatusItem() {
        runAfterMenuDismissal { [service] in
            // Confirm, because this is now PERSISTENT and the menu is the main way
            // into the app: hiding it with no window open leaves nothing to click.
            // The alert says where the switch lives before it disappears, rather
            // than after.
            let alert = NSAlert()
            alert.messageText = "Hide the menu bar icon?"
            alert.informativeText = "TargetBridge keeps running. To bring the icon "
                + "back, open TargetBridge from Applications and turn it on again "
                + "in General."
            alert.addButton(withTitle: "Hide")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            service.showsMenuBarIcon = false
        }
    }

    @objc
    private func quitApp() {
        runAfterMenuDismissal {
            // Quitting with our device still selected would leave the Mac
            // pointed at a device that no longer carries audio.
            TBDefaultOutputGuard.shared.restoreIfSelected()
            NSApp.terminate(nil)
        }
    }
}

extension TBDisplaySenderStatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuItems(in: menu)
    }
}

/// Target for a menu slider. NSSlider holds its target weakly, so the controller
/// retains these for the lifetime of the open menu.
@MainActor
final class TBMenuSliderTarget: NSObject {
    private let onChange: (Double) -> Void

    init(_ onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
    }

    @objc func changed(_ sender: NSSlider) {
        onChange(sender.doubleValue)
    }
}
