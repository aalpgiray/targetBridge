// PROTOTYPE — THROWAWAY. Not built by the app, not shipped, not tested.
//
// The settled design from the grilling round, made clickable. The structure is
// no longer in question, so the switcher at the bottom cycles STATES instead of
// variants — those are the things we never mocked and therefore never checked:
//
//   1  Streaming        one monitor live
//   2  Nothing found    setup helper, not a spinner
//   3  Failed           a connect that did not work
//   4  Two streaming    multi-monitor, and where the sliders go
//
// Settled: a monitor is the unit; popover in the menu bar styled after Control
// Centre; the popover's controls follow the SCREEN IT WAS OPENED ON; glyph only
// in the bar, tinted while streaming; no Dock icon until the Monitors window is
// open; settings remembered per monitor.
//
// Run it:  swiftc -O -o /tmp/tbproto TargetBridge-Sender/prototypes/TBUIPrototype.swift && /tmp/tbproto
//
// State is fake and in memory. Nothing talks to the real service.

import SwiftUI
import AppKit
import Combine

// MARK: - Fake state

enum Demo: Int, CaseIterable {
    case streaming, empty, failed, twoUp
    var label: String {
        switch self {
        case .streaming: return "Streaming"
        case .empty:     return "Nothing found"
        case .failed:    return "Connect failed"
        case .twoUp:     return "Two streaming"
        }
    }
}

final class Model: ObservableObject {
    struct Monitor: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var host: String
        var online = true
        var resolution = "5120 × 2880"
        var hiDPI = true
        var arrangement = "Extended"
        var brightness = 0.72
        var volume = 0.35
        var audioOut = "Monitor speakers"
        var autoConnect = false
        var nightShift = false
        var trueTone = true
        var vsync = false
        var error: String?
    }

    @Published var demo: Demo = .streaming { didSet { apply() } }
    /// Created ONCE, with stable ids.
    ///
    /// These used to be rebuilt on every state change, which minted fresh UUIDs
    /// while SwiftUI views still held the old ones -- the next binding() lookup
    /// found nothing and the force unwrap trapped (SIGTRAP on any arrow key).
    /// Identity churn was the bug; a safer unwrap would only have hidden it.
    @Published var allMonitors: [Monitor] = [
        Monitor(name: "iMac 27\"", host: "10.0.1.2"),
        Monitor(name: "Studio Display", host: "10.0.1.7"),
    ]
    @Published var visible: [UUID] = []
    @Published var streaming: Set<UUID> = []
    @Published var errors: [UUID: String] = [:]
    /// Which of our monitors the popover was opened on -- nil means the Mac's own
    /// screen, so no per-monitor controls. In the real app this comes from
    /// statusItem.button.window.screen mapped to the session's displayID.
    @Published var openedOn: UUID?
    @Published var launchAtLogin = true

    let stats = "60 fps · 3.8 ms · lossless"
    @Published var fps: Int = 60

    var monitors: [Monitor] { visible.compactMap { id in allMonitors.first { $0.id == id } } }

    init() { apply() }

    func apply() {
        let imac = allMonitors[0].id, studio = allMonitors[1].id
        errors = [:]
        switch demo {
        case .streaming:
            visible = [imac, studio]; streaming = [imac]; openedOn = imac
        case .empty:
            visible = []; streaming = []; openedOn = nil
        case .failed:
            visible = [imac, studio]; streaming = []; openedOn = nil
            errors[imac] = "The receiver refused the connection."
        case .twoUp:
            visible = [imac, studio]; streaming = [imac, studio]
            openedOn = nil   // opened on the Mac's own screen: lists both, no inline sliders
        }
    }

    func toggle(_ id: UUID) {
        if streaming.contains(id) { streaming.remove(id) } else { streaming.insert(id) }
    }

    /// Never traps: a stale id yields a harmless throwaway binding.
    func binding(_ id: UUID) -> Binding<Monitor> {
        guard let i = allMonitors.firstIndex(where: { $0.id == id }) else {
            return .constant(allMonitors[0])
        }
        return Binding(get: { self.allMonitors[i] }, set: { self.allMonitors[i] = $0 })
    }
}

// MARK: - The popover (Control Centre styling)

struct Popover: View {
    @EnvironmentObject var m: Model
    var openWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if m.monitors.isEmpty { setupHelper } else { list }
            Divider().padding(.vertical, 6)
            // Real rows, not flat text. A plain-styled button reads as a label,
            // so the way into Settings looked like a caption.
            VStack(spacing: 1) {
                footerRow("gearshape", "Settings…") { openWindow() }
                footerRow("power", "Quit TargetBridge") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .padding(.top, 12)
        .frame(width: 300)
    }

    @State private var hovered: String?

    private func footerRow(_ symbol: String, _ title: String,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12))
                    .frame(width: 18)
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovered == title ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovered = $0 ? title : nil }
    }

    // Not a spinner: tells you what to actually do.
    private var setupHelper: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("No displays found").font(.system(size: 13, weight: .semibold))
            Text("To use another Mac as a display:")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Install TargetBridge Receiver on that Mac and open it.")
                step(2, "Connect the two with Thunderbolt, or put both on the same network.")
            }
            HStack {
                ProgressView().controlSize(.small)
                Text("Still looking…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.bottom, 4)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("\(n)").font(.system(size: 10, weight: .semibold))
                .frame(width: 15, height: 15)
                .background(.secondary.opacity(0.18), in: Circle())
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var list: some View {
        VStack(spacing: 4) {
            ForEach(m.monitors) { mon in
                let live = m.streaming.contains(mon.id)
                VStack(spacing: 8) {
                    Button { m.toggle(mon.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "display")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 28, height: 28)
                                .background(live ? Color.accentColor : Color.secondary.opacity(0.18),
                                            in: Circle())
                                .foregroundStyle(live ? .white : .primary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mon.name).font(.system(size: 13))
                                Text(m.errors[mon.id] ?? (live ? m.stats : "Available"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(m.errors[mon.id] != nil ? .red : .secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(live ? Color.primary.opacity(0.06) : .clear,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    // The idea that removed a selector: controls appear only for the
                    // monitor whose screen this popover was opened on.
                    if live, m.openedOn == mon.id {
                        let b = m.binding(mon.id)
                        VStack(spacing: 12) {
                            // Sun glyphs at both ends, small to large, as the
                            // existing menu already does.
                            endedSlider("sun.min", "sun.max", b.brightness)
                            endedSlider("speaker.fill", "speaker.wave.3.fill", b.volume)
                            HStack(spacing: 0) {
                                roundToggle("moon.fill", "Night Shift", b.nightShift)
                                roundToggle("sun.max.fill", "True Tone", b.trueTone)
                                roundToggle("arrow.triangle.2.circlepath", "V-Sync", b.vsync)
                            }
                        }
                        .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 8)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func endedSlider(_ lead: String, _ trail: String,
                            _ value: Binding<Double>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: lead).font(.system(size: 10))
                .foregroundStyle(.secondary).frame(width: 14)
            Slider(value: value)
            Image(systemName: trail).font(.system(size: 13))
                .foregroundStyle(.secondary).frame(width: 16)
        }
    }

    /// Control Centre's circular toggle: filled accent when on, label and state
    /// underneath. Matches the controls already in the menu bar today.
    private func roundToggle(_ symbol: String, _ title: String,
                             _ isOn: Binding<Bool>) -> some View {
        VStack(spacing: 5) {
            Button { isOn.wrappedValue.toggle() } label: {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isOn.wrappedValue ? .white : .primary)
                    .frame(width: 46, height: 46)
                    .background(isOn.wrappedValue ? Color.accentColor
                                                  : Color.secondary.opacity(0.20),
                                in: Circle())
            }
            .buttonStyle(.plain)
            Text(title).font(.system(size: 11))
            Text(isOn.wrappedValue ? "On" : "Off")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The Monitors window — one page per monitor, no sub-levels

struct MonitorsWindow: View {
    @EnvironmentObject var m: Model
    @State private var selected: UUID?
    @State private var showDiagnostics = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section("Displays") {
                    ForEach(m.monitors) { mon in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(m.streaming.contains(mon.id) ? .green : .secondary.opacity(0.35))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(mon.name)
                                Text(m.streaming.contains(mon.id) ? "Streaming" : "Available")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        .tag(mon.id as UUID?)
                    }
                }
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            if let id = selected ?? m.monitors.first?.id,
               let mon = m.monitors.first(where: { $0.id == id }) {
                page(mon)
            } else {
                windowEmptyState
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    /// The same guidance the panel gives. An empty window that only says "nothing
    /// found" tells a first-time user nothing about what to do next.
    private var windowEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "display.2")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No displays found").font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                helpStep(1, "Install TargetBridge Receiver on the other Mac",
                         "It needs to be running for this Mac to find it.")
                helpStep(2, "Connect the two Macs",
                         "A Thunderbolt cable gives the best result. The same Wi-Fi or Ethernet network also works.")
                helpStep(3, "Keep both Macs awake",
                         "A sleeping Mac will not appear here.")
            }
            .frame(maxWidth: 380, alignment: .leading)
            HStack(spacing: 10) {
                Button("Open Receiver Download Page") {}
                Button("Search Again") {}.buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Still looking…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func helpStep(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(.secondary.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func page(_ mon: Model.Monitor) -> some View {
        let b = m.binding(mon.id)
        let live = m.streaming.contains(mon.id)
        return Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mon.name).font(.system(size: 15, weight: .semibold))
                        Text(mon.host).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(live ? "Disconnect" : "Connect") { m.toggle(mon.id) }
                        .buttonStyle(.borderedProminent)
                }
                if let e = m.errors[mon.id] {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
                if live { LabeledContent("Now") { Text(m.stats).foregroundStyle(.secondary) } }
            }
            Section("Display") {
                LabeledContent("Resolution") { Text(mon.resolution).foregroundStyle(.secondary) }
                Toggle("High Resolution (HiDPI)", isOn: b.hiDPI)
                Picker("Use As", selection: b.arrangement) {
                    Text("Extended").tag("Extended"); Text("Mirrored").tag("Mirrored")
                }
                LabeledContent("Brightness") { Slider(value: b.brightness).frame(width: 200) }
            }
            Section {
                Toggle("Night Shift", isOn: b.nightShift)
                Toggle("True Tone", isOn: b.trueTone)
                Toggle("V-Sync", isOn: b.vsync)
            } footer: {
                Text("V-Sync trades a little latency for tear-free motion.")
            }
            Section("Sound") {
                Picker("Output", selection: b.audioOut) {
                    Text("Monitor speakers").tag("Monitor speakers"); Text("Off").tag("Off")
                }
                LabeledContent("Volume") { Slider(value: b.volume).frame(width: 200) }
            }
            Section {
                Toggle("Connect automatically when available", isOn: b.autoConnect)
                Toggle("Open TargetBridge at login", isOn: $m.launchAtLogin)
            }
            Section {
                DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                    LabeledContent("Frame rate") { Text("60.0 fps").foregroundStyle(.secondary) }
                    LabeledContent("Cursor latency") { Text("3.8 ms").foregroundStyle(.secondary) }
                    LabeledContent("Compression") { Text("Lossless · 3.1×").foregroundStyle(.secondary) }
                    LabeledContent("Capture") { Text("240 Hz → 60 fps").foregroundStyle(.secondary) }
                    Button("Reveal Log in Finder") {}
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Prototype-only switcher

struct Switcher: View {
    @EnvironmentObject var m: Model
    var body: some View {
        HStack(spacing: 12) {
            Button { cycle(-1) } label: { Image(systemName: "chevron.left") }
            Text("\(m.demo.rawValue + 1) — \(m.demo.label)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 170)
            Button { cycle(1) } label: { Image(systemName: "chevron.right") }
            Divider().frame(height: 14)
            Text("click the menu bar icon")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.85), in: Capsule())
        .foregroundStyle(.white)
        .shadow(radius: 12, y: 3)
    }
    private func cycle(_ d: Int) {
        let all = Demo.allCases
        let i = (m.demo.rawValue + d + all.count) % all.count
        m.demo = all[i]
    }
}

struct Root: View {
    @EnvironmentObject var m: Model
    var body: some View {
        ZStack(alignment: .bottom) {
            MonitorsWindow()
            Switcher().padding(.bottom, 16)
        }
        .background(KeyCatcher { key in
            if key == 123 { step(-1) }; if key == 124 { step(1) }
        })
    }
    private func step(_ d: Int) {
        let all = Demo.allCases
        m.demo = all[(m.demo.rawValue + d + all.count) % all.count]
    }
}

struct KeyCatcher: NSViewRepresentable {
    let onKey: (UInt16) -> Void

    // Registered once and torn down with the view. SwiftUI rebuilds a
    // representable freely, and the previous version added a global monitor each
    // time without removing any -- so after a few state changes a single arrow
    // press fired the handler several times and skipped states.
    final class Coordinator {
        var monitor: Any?
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if !(NSApp.keyWindow?.firstResponder is NSTextView) { onKey(e.keyCode) }
            return e
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m); coordinator.monitor = nil }
    }
}

// MARK: - Control Centre style panel

/// A borderless panel, NOT an NSPopover.
///
/// NSPopover always draws a beak pointing at the status item, and there is no API
/// to remove it. macOS's own Control Centre panels (Display, Sound, Wi-Fi) are
/// plain rounded panels with no arrow, so matching them means owning the window.
/// It also puts dismissal under our control: a popover set to .transient closes on
/// the first click anywhere, including clicks meant for its own controls.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }   // sliders and toggles need key status
}

/// Real vibrancy. A SwiftUI `Material` blurs what is INSIDE the window, so in a
/// borderless panel floating over the desktop it has nothing to sample and renders
/// as flat grey -- the "looks old" version. Only NSVisualEffectView with
/// .behindWindow blending samples the desktop underneath.
struct Vibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        // .popover, not .hudWindow. hudWindow is a dark, nearly opaque material --
        // side by side with Control Centre it reads as flat grey. .popover is the
        // one AppKit uses for real popovers and lets the desktop through.
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct PanelChrome<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(Vibrancy())
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            // Just enough for the shadow. This was 10, which read as a visible gap
            // between the panel and the menu bar; macOS sits much closer.
            .padding(5)
    }
}

// MARK: - Host

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    var statusItem: NSStatusItem!
    var panel: Panel!
    var outsideClick: Any?
    var window: NSWindow?
    var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        // No Dock icon until a window exists.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        refreshIcon()

        let host = NSHostingView(
            rootView: PanelChrome {
                Popover(openWindow: { [weak self] in self?.openWindow() })
                    .environmentObject(model)
            })
        host.sizingOptions = [.intrinsicContentSize]
        panel = Panel(contentRect: .init(x: 0, y: 0, width: 320, height: 200),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The icon tracks streaming state, so refresh whenever the model changes.
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }

        openWindow()   // prototype convenience: the switcher lives here
    }

    /// Glyph only. Tinted while streaming. No stats — the bar is already full.
    func refreshIcon() {
        guard let button = statusItem.button else { return }
        let live = !model.streaming.isEmpty
        let vsync = model.allMonitors.contains { model.streaming.contains($0.id) && $0.vsync }

        // Built like the battery item: value on the LEFT, glyph on the right.
        button.imagePosition = live ? .imageRight : .imageOnly

        // Plain title + font, NOT attributedTitle.
        //
        // An attributed string with no explicit colour draws BLACK, and setting an
        // explicit colour is just as wrong the other way -- it cannot know whether
        // the menu bar is currently light or dark. Leaving the colour to AppKit is
        // the only version that adapts. Monospaced digits stop the bar shifting
        // sideways every time the rate ticks between 59 and 60.
        if live {
            button.title = "\(model.fps) "
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        } else {
            button.title = ""
        }

        // V-Sync is shown by the glyph, so the state is legible without opening
        // anything -- optional, and it costs no extra width.
        let name = vsync ? "arrow.triangle.2.circlepath" : "display.2"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "TargetBridge")
        img?.isTemplate = true          // contentTintColor only applies to templates
        if img == nil { button.title = "TB" }   // a nil symbol must never blank the item
        button.image = img
        button.contentTintColor = live ? .controlAccentColor : nil

        button.toolTip = live
            ? "TargetBridge — \(model.fps) fps to \(model.streaming.count) display(s)"
              + (vsync ? ", V-Sync on" : "")
            : "TargetBridge — idle"
    }

    @objc func toggle() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    func showPanel() {
        guard let button = statusItem.button,
              let bWin = button.window else { return }
        refreshIcon()
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 260)
        panel.setContentSize(size)

        // Centred under the status item, clamped to the screen it lives on.
        // LEFT edges aligned, not centred. macOS aligns a status item's menu or
        // panel to the item's left edge; centring makes it hang off to the left and
        // look unrelated to the icon that opened it.
        let onScreen = bWin.convertToScreen(button.convert(button.bounds, to: nil))
        var x = onScreen.minX - 5      // less the chrome padding, so edges line up
        // macOS panels sit ~5pt under the bar; the chrome padding is part of
        // that distance, so add it back rather than stacking two gaps.
        var y = onScreen.minY - size.height + 5
        if let vf = (bWin.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
            y = max(y, vf.minY + 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        panel.makeKey()

        // Dismiss on a click OUTSIDE the panel only, so clicks on our own sliders
        // and toggles are never swallowed.
        outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hidePanel() }
    }

    func hidePanel() {
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
        panel.orderOut(nil)
    }

    func openWindow() {
        hidePanel()
        if window == nil {
            let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 780, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false   // ARC does not know the manual-retain convention
            w.title = "TargetBridge Settings — PROTOTYPE"
            w.contentView = NSHostingView(rootView: Root().environmentObject(model))
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)     // Dock icon appears with the window
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ n: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)   // and goes away with it
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
