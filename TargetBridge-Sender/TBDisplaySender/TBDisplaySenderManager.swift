import AppKit
import ApplicationServices
import Combine
import Foundation
import Network

enum TBTransportKind: String, CaseIterable, Identifiable {
    case thunderboltBridge
    case networkLink

    var id: String { rawValue }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch (self, language) {
        case (.thunderboltBridge, .italian): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .english): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .german): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .french): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .chinese): return "Thunderbolt Bridge"
        case (.networkLink, .italian): return "Network Link (sperimentale)"
        case (.networkLink, .english): return "Network Link (experimental)"
        case (.networkLink, .german): return "Network Link (experimentell)"
        case (.networkLink, .french): return "Network Link (expérimental)"
        case (.networkLink, .chinese): return "Network Link（实验性）"
        }
    }
}

struct TBLocalLinkInterface: Identifiable, Hashable {
    let name: String
    let ip: String
    let transportKind: TBTransportKind

    var id: String { "\(transportKind.rawValue)|\(name)|\(ip)" }

    func displayText(_ language: TBDisplaySenderLanguage) -> String {
        "\(name) · \(ip) · \(transportKind.title(language))"
    }
}

@MainActor
final class TBDisplaySenderService: ObservableObject {
    static let shared = TBDisplaySenderService()

    @Published var sessions: [TBDisplaySenderSession] = []
    @Published private(set) var localInterfaces: [TBLocalLinkInterface] = []
    @Published private(set) var discoveredReceivers: [TBDiscoveredReceiver] = []
    @Published private(set) var addons: [TBAddonRecord] = []
    /// Changes whenever the app returns from System Settings so permission cards
    /// re-evaluate their live TCC state instead of showing a stale warning.
    @Published private(set) var privacyPermissionsRevision = 0
    @Published var language: TBDisplaySenderLanguage = .load() {
        didSet {
            language.persist()
            sessions.forEach { $0.language = language }
            pushLanguageUpdateToDiscoveredReceivers()
            objectWillChange.send()
        }
    }
    @Published var showsMenuBarIcon = true
    @Published var largeCursor: Bool = UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.largeCursor") {
        didSet {
            UserDefaults.standard.set(largeCursor, forKey: "fd.tbdisplaysender.largeCursor")
            sessions.forEach { $0.largeCursor = largeCursor }
            objectWillChange.send()
        }
    }
    @Published var preventDisplaySleep: Bool = {
        if UserDefaults.standard.object(forKey: "fd.tbdisplaysender.preventDisplaySleep") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.preventDisplaySleep")
    }() {
        didSet {
            UserDefaults.standard.set(preventDisplaySleep, forKey: "fd.tbdisplaysender.preventDisplaySleep")
            sessions.forEach { $0.preventDisplaySleep = preventDisplaySleep }
            objectWillChange.send()
        }
    }
    @Published var autoRestartOnWake: Bool = {
        if UserDefaults.standard.object(forKey: "fd.tbdisplaysender.autoRestartOnWake") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.autoRestartOnWake")
    }() {
        didSet {
            UserDefaults.standard.set(autoRestartOnWake, forKey: "fd.tbdisplaysender.autoRestartOnWake")
            sessions.forEach { $0.autoRestartOnWake = autoRestartOnWake }
            objectWillChange.send()
        }
    }
    @Published var verboseDisplayLogging: Bool = UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.verboseDisplayLogging") {
        didSet {
            UserDefaults.standard.set(verboseDisplayLogging, forKey: "fd.tbdisplaysender.verboseDisplayLogging")
            sessions.forEach { $0.verboseDisplayLogging = verboseDisplayLogging }
            objectWillChange.send()
        }
    }
    @Published var audioEnabled: Bool = UserDefaults.standard.object(forKey: "fd.tbdisplaysender.audioEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "fd.tbdisplaysender.audioEnabled")
            objectWillChange.send()
        }
    }
    /// The audio driver's loopback listener, owned by the APP rather than by a
    /// session.
    ///
    /// WHY IT LIVES HERE
    ///
    /// The driver probes this port once a second and withdraws its audio device
    /// after three refusals — deliberately, so a device cannot sit selected and
    /// silent (see Driver.cpp's liveness loop). While the socket was opened by
    /// the video pipeline and closed on session teardown, that meant the
    /// TargetBridge output device only existed *during a stream*: end the
    /// session, or lose the link, and it disappeared from macOS three seconds
    /// later. The whole point of the driver feature is a native output device
    /// that is always there to select.
    ///
    /// So the socket now opens with the app and closes with it. "Alive" comes to
    /// mean "TargetBridge is running", which is what the driver's probe was
    /// really asking all along.
    private var audioDriverReceiver: TBAudioDriverReceiver?
    private var sessionCancellables: [UUID: AnyCancellable] = [:]
    private let receiverDiscovery = TBReceiverDiscovery()
    private let addonStore = TBAddonStore.shared
    private let inputRelayController = TBInputRelayController()
    private var discoveryCancellable: AnyCancellable?
    private var addonCancellable: AnyCancellable?
    private var activationObserver: NSObjectProtocol?
    private var clipboardTimer: Timer?
    private var lastClipboardChangeCount: Int = NSPasteboard.general.changeCount

    private init() {
        discoveryCancellable = receiverDiscovery.$receivers.sink { [weak self] receivers in
            guard let self else { return }
            discoveredReceivers = receivers
            pushLanguageUpdateToDiscoveredReceivers()
            evaluateAutoCast()
            objectWillChange.send()
        }
        addonCancellable = addonStore.$addons.sink { [weak self] addons in
            guard let self else { return }
            self.addons = addons
            normalizeAddonState()
            refreshAudioDriverListener()
            objectWillChange.send()
        }
        refreshLocalInterfaces()
        addonStore.refresh()
        restorePersistedSessions()
        // Publish the audio device immediately, not on first stream.
        refreshAudioDriverListener()
        observeAudioDeviceSelection()
        startClipboardMonitoring()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPrivacyPermissions()
            }
        }
    }

    /// Open the driver's loopback port so the audio device stays published.
    /// Idempotent, and safe to call whenever the addon state changes.
    func refreshAudioDriverListener() {
        guard audioDriverAvailable else {
            if audioDriverReceiver != nil {
                audioDriverReceiver?.stop()
                audioDriverReceiver = nil
                TBLog.connection.notice("audio driver listener: stopped (addon disabled) — device will withdraw")
            }
            return
        }
        guard audioDriverReceiver == nil else { return }

        let rx = TBAudioDriverReceiver { [weak self] pcm in
            Task { @MainActor [weak self] in
                self?.routeDriverAudio(pcm)
            }
        }
        if rx.start() {
            audioDriverReceiver = rx
            TBLog.connection.notice("audio driver listener: up — device stays published while the app runs")
        } else {
            TBLog.connection.error("audio driver listener: bind failed; the audio device will withdraw")
        }
    }

    /// Selecting our device in Sound settings is a request to send audio to the
    /// receiver, so honour it: switch the sessions' audio on.
    ///
    /// Without this the device could be chosen as the system output while
    /// `audioEnabled` was false, and every sample was dropped in routeDriverAudio
    /// with nothing said. Sound simply stopped, which is indistinguishable from a
    /// broken driver — and is precisely the "selected and silent" failure the
    /// driver's liveness probe was written to avoid.
    ///
    /// Deselecting is deliberately NOT the inverse: the user may switch output
    /// briefly without meaning to change what this app streams, and silently
    /// turning their setting off would be worse than leaving it on.
    private func observeAudioDeviceSelection() {
        TBDefaultOutputGuard.shared.observeSelection { [weak self] isOurs in
            guard isOurs else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let off = self.sessions.filter { !$0.audioEnabled }
                guard !off.isEmpty else { return }
                off.forEach { $0.audioEnabled = true }
                TBLog.connection.notice("audio: TargetBridge selected as output — enabling audio on \(off.count, privacy: .public) session(s)")
                self.objectWillChange.send()
            }
        }
    }

    /// Hand PCM to whichever session can actually carry it. With no live session
    /// the audio is dropped here — the device stays present, which is the point:
    /// selectable like any output, silent until something is streaming.
    private func routeDriverAudio(_ pcm: Data) {
        guard let session = sessions.first(where: { $0.isStreaming && $0.audioEnabled }) else { return }
        session.acceptDriverAudio(pcm)
    }

    func refreshPrivacyPermissions() {
        privacyPermissionsRevision &+= 1
    }

    var anyConnected: Bool {
        sessions.contains { $0.isConnected || $0.isStreaming }
    }

    var anyStreaming: Bool {
        sessions.contains { $0.isStreaming }
    }

    var connectedSessionCount: Int {
        sessions.reduce(into: 0) { count, session in
            if session.isConnected || session.isStreaming {
                count += 1
            }
        }
    }

    var localInterfaceSummaryText: String {
        guard !localInterfaces.isEmpty else {
            return TBDisplaySenderL10n.notDetected(language)
        }
        return localInterfaces
            .map { $0.displayText(language) }
            .joined(separator: "   ")
    }

    var availableTransportKinds: [TBTransportKind] {
        TBTransportKind.allCases.filter { transportKind in
            switch transportKind {
            case .thunderboltBridge:
                return true
            case .networkLink:
                return isAddonCapabilityEnabled(.networkLink)
            }
        }
    }

    var audioRelayAvailable: Bool {
        isAddonCapabilityEnabled(.audioRelay)
    }

    /// The virtual audio driver. Separate from Audio Relay because it installs a
    /// system component rather than just streaming: off by default, and worth an
    /// explicit decision.
    var audioDriverAvailable: Bool {
        isAddonCapabilityEnabled(.audioDriver)
    }

    /// Either addon carries audio to the receiver, and they share the wire
    /// format and the receiver's playback. So the transport follows both — the
    /// driver has to work with Audio Relay switched off, or it would not be
    /// independently installable.
    var audioTransportAvailable: Bool {
        audioRelayAvailable || audioDriverAvailable
    }

    var inputDockstationAvailable: Bool {
        isAddonCapabilityEnabled(.inputDockstation)
    }

    var localInputInjectionTrusted: Bool {
        AXIsProcessTrusted()
    }

    var localInputMonitoringTrusted: Bool {
        CGPreflightListenEventAccess()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func configurationChecks(for session: TBDisplaySenderSession) -> [TBConfigurationCheck] {
        let interfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
        let role = session.inputControlRole
        let snapshot = TBConfigurationDiagnosticSnapshot(
            hasScreenRecording: CGPreflightScreenCaptureAccess(),
            transportIsThunderbolt: session.transportKind == .thunderboltBridge,
            localInterfaceName: TBConnectionDiagnostics.interfaceName(forLocalIP: session.localInterfaceIP, in: interfaces),
            receiverAddress: session.receiverIP.trimmingCharacters(in: .whitespacesAndNewlines),
            receiverProfileAvailable: session.receiverSupportsHEVCDecodeHint != nil,
            receiverSupportsHEVC: session.receiverSupportsHEVCDecodeHint,
            requiresHEVC: session.capturePreset.codecName == "HEVC",
            cableRate: session.cableTestResult,
            requiresSenderInputMonitoring: role == .senderMaster,
            senderInputMonitoringGranted: localInputMonitoringTrusted,
            requiresSenderAccessibility: role == .receiverMaster,
            senderAccessibilityGranted: localInputInjectionTrusted,
            requiresReceiverInputMonitoring: role == .receiverMaster,
            receiverInputMonitoringGranted: session.receiverInputMonitoringTrustedHint,
            requiresReceiverAccessibility: role == .senderMaster,
            receiverAccessibilityGranted: session.receiverAccessibilityTrustedHint
        )
        return TBConfigurationDiagnostics.checks(for: snapshot)
    }

    func addSession() {
        let session = TBDisplaySenderSession(
            language: language,
            largeCursor: largeCursor,
            preventDisplaySleep: preventDisplaySleep,
            autoRestartOnWake: autoRestartOnWake,
            audioEnabled: audioEnabled,
            verboseDisplayLogging: verboseDisplayLogging
        )
        if let previous = sessions.last {
            session.capturePreset = previous.capturePreset
            session.captureSource = previous.captureSource
            session.transportKind = previous.transportKind
            session.audioEnabled = previous.audioEnabled
            session.inputGestureMode = previous.inputGestureMode
        }
        session.audioAddonAvailable = audioTransportAvailable
        session.audioDriverAvailable = audioDriverAvailable
        if let suggestedInterface = suggestedInterfaceForNewSession(transportKind: session.transportKind) {
            session.localInterfaceIP = suggestedInterface.ip
        }
        attachSession(session)
        sessions.append(session)
        schedulePersist()
        objectWillChange.send()
    }

    func removeSession(_ session: TBDisplaySenderSession) {
        guard sessions.count > 1 else { return }
        session.stop()
        sessions.removeAll { $0.id == session.id }
        sessionCancellables.removeValue(forKey: session.id)
        normalizeAddonState()
        normalizeSessionInterfaces()
        schedulePersist()
        objectWillChange.send()
    }

    func stopAll() {
        sessions.forEach { $0.persistExtendedDisplayArrangementSnapshot() }
        sessions.forEach { $0.stop(persistArrangement: false) }
    }

    // MARK: - Session persistence

    private static let persistedSessionsKey = "fd.tbdisplaysender.sessions.v1"
    private static let receiverDisplayProfilesKey = "fd.tbdisplaysender.receiverDisplayProfiles.v1"
    /// One-shot repair for state the audio latch corrupted.
    ///
    /// `normalizeAddonState` used to write availability into the persisted
    /// `audioEnabled`, so a single launch where the addon had not loaded turned
    /// audio off permanently. That write is gone, but a session saved while the
    /// bug was live still carries `audioEnabled: false` and would keep it
    /// forever. Any false written by the latch is indistinguishable from a
    /// deliberate one, so this restores audio ONCE on sessions whose transport
    /// is available, and never runs again.
    private static let audioLatchRepairKey = "fd.tbdisplaysender.audioLatchRepaired.v1"

    /// Snapshot of the user-configurable settings for a single session. Transient
    /// runtime state (connection, FPS, …) is intentionally excluded — only the
    /// choices the user makes in the UI are remembered across launches. The input
    /// master role (Input Dockstation) is a user choice, so it is persisted too;
    /// role and bindings are optional for backward compatibility with sessions
    /// saved before either setting was added.
    private struct PersistedSession: Codable {
        var transportKind: String
        var localInterfaceIP: String
        var receiverIP: String
        var selectedReceiverID: String
        var capturePreset: String
        var captureSource: String
        var audioEnabled: Bool
        var brightness: Double
        var inputGestureMode: String
        var volume: Double?
        var inputControlRole: String?
        var inputBindings: [TBInputBinding]?
        var matchRenderToStream: Bool?
        /// Optional: sessions saved before auto-cast existed decode as nil = off.
        var autoCastEnabled: Bool?
        /// Optional: sessions saved before this decode as nil and re-learn it.
        var preferredLocalInterfaceIP: String?
    }

    private var lastPersistedData: Data?
    private var persistScheduled = false

    /// Coalesces the many synchronous `objectWillChange` notifications a single
    /// user action produces into one write. Runs on the next main-loop tick, so
    /// it observes the post-change values rather than the pre-change ones that
    /// `objectWillChange` fires with.
    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.persistScheduled = false
            self.persistSessions()
        }
    }

    private func persistSessions() {
        let configs = sessions.map { session in
            PersistedSession(
                transportKind: session.transportKind.rawValue,
                localInterfaceIP: session.localInterfaceIP,
                receiverIP: session.receiverIP,
                selectedReceiverID: session.selectedReceiverID,
                capturePreset: session.capturePreset.rawValue,
                captureSource: session.captureSource.rawValue,
                audioEnabled: session.audioEnabled,
                brightness: session.brightness,
                inputGestureMode: session.inputGestureMode.rawValue,
                volume: session.volume,
                inputControlRole: session.inputControlRole.rawValue,
                inputBindings: session.inputBindings,
                matchRenderToStream: session.matchRenderToStream,
                autoCastEnabled: session.autoCastEnabled,
                preferredLocalInterfaceIP: session.preferredLocalInterfaceIP
            )
        }
        guard let data = try? JSONEncoder().encode(configs) else { return }
        // Streaming churns `objectWillChange` constantly; skip redundant writes.
        guard data != lastPersistedData else { return }
        lastPersistedData = data
        UserDefaults.standard.set(data, forKey: Self.persistedSessionsKey)
    }

    private func restorePersistedSessions() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedSessionsKey),
              let configs = try? JSONDecoder().decode([PersistedSession].self, from: data),
              !configs.isEmpty
        else {
            addSession()
            return
        }

        lastPersistedData = data
        for config in configs {
            let session = TBDisplaySenderSession(
                language: language,
                largeCursor: largeCursor,
                preventDisplaySleep: preventDisplaySleep,
                autoRestartOnWake: autoRestartOnWake,
                audioEnabled: audioEnabled,
                verboseDisplayLogging: verboseDisplayLogging
            )
            apply(config, to: session)
            session.audioAddonAvailable = audioTransportAvailable
            session.audioDriverAvailable = audioDriverAvailable
            attachSession(session)
            sessions.append(session)
        }
        // Mark the latch repair done whether or not it changed anything, so a
        // later deliberate "audio off" is never second-guessed.
        UserDefaults.standard.set(true, forKey: Self.audioLatchRepairKey)
        // Enforce the single-master invariant: only one session may hold a
        // non-`off` input role. (Persisted data should already satisfy this, but
        // restore sets roles directly, so guard against stale/edited defaults.)
        if let firstMaster = sessions.first(where: { $0.inputControlRole != .off }) {
            for session in sessions where session.id != firstMaster.id {
                session.inputControlRole = .off
            }
        }
        // Drop transports/audio for addons that are no longer enabled and make
        // sure every restored interface still exists on this machine.
        normalizeAddonState()
        normalizeSessionInterfaces()
        objectWillChange.send()
    }

    private func apply(_ config: PersistedSession, to session: TBDisplaySenderSession) {
        if let transport = TBTransportKind(rawValue: config.transportKind) {
            session.transportKind = transport
        }
        if let preset = TBDisplayCapturePreset(rawValue: config.capturePreset) {
            session.capturePreset = preset
        }
        if let source = TBDisplayCaptureSource(rawValue: config.captureSource) {
            session.captureSource = source
        }
        if let gesture = TBInputGestureMode(rawValue: config.inputGestureMode) {
            session.inputGestureMode = gesture
        }
        if let roleRaw = config.inputControlRole,
           let role = TBInputControlRole(rawValue: roleRaw) {
            session.inputControlRole = role
        }
        if let bindings = config.inputBindings {
            session.inputBindings = bindings
        }
        session.receiverIP = config.receiverIP
        session.selectedReceiverID = config.selectedReceiverID
        session.localInterfaceIP = config.localInterfaceIP
        if !UserDefaults.standard.bool(forKey: Self.audioLatchRepairKey),
           audioTransportAvailable,
           !config.audioEnabled {
            session.audioEnabled = true
        } else {
            session.audioEnabled = config.audioEnabled
        }
        session.brightness = config.brightness
        session.volume = config.volume ?? 0.5
        session.matchRenderToStream = config.matchRenderToStream ?? false
        session.autoCastEnabled = config.autoCastEnabled ?? false
        session.preferredLocalInterfaceIP = config.preferredLocalInterfaceIP ?? config.localInterfaceIP
    }

    func refreshLocalInterfaces() {
        localInterfaces = detectLocalInterfaces()
        receiverDiscovery.refresh()
        normalizeSessionInterfaces()
        objectWillChange.send()
    }

    func applyDiscoveredReceiver(_ receiver: TBDiscoveredReceiver, to session: TBDisplaySenderSession) {
        session.receiverIP = receiver.ip(for: session.transportKind)
        session.receiverSupportsHEVCDecodeHint = receiver.supportsHEVCDecode
        if session.localInterfaceIP.isEmpty {
            session.localInterfaceIP = suggestedInterfaceForNewSession(transportKind: session.transportKind)?.ip
                ?? availableInterfaces(for: session.transportKind).first?.ip
                ?? ""
        }
        restoreDisplayProfile(for: session)
        objectWillChange.send()
    }

    func applyDisplayProfile(_ profile: TBDisplayProfile, to session: TBDisplaySenderSession) {
        guard !session.isConnected, !session.isStreaming else { return }

        let settings = profile.settings
        session.captureSource = settings.captureSource
        session.capturePreset = settings.capturePreset
        session.matchRenderToStream = settings.matchRenderToStream
        session.audioEnabled = settings.audioEnabled

        guard let receiverKey = receiverProfileKey(for: session) else { return }
        var profiles = persistedDisplayProfiles
        profiles[receiverKey] = profile.rawValue
        UserDefaults.standard.set(profiles, forKey: Self.receiverDisplayProfilesKey)
    }

    private var persistedDisplayProfiles: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.receiverDisplayProfilesKey) as? [String: String] ?? [:]
    }

    private func receiverProfileKey(for session: TBDisplaySenderSession) -> String? {
        if !session.selectedReceiverID.isEmpty {
            return "id:\(session.selectedReceiverID)"
        }

        let receiverIP = session.receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return receiverIP.isEmpty ? nil : "ip:\(receiverIP)"
    }

    private func restoreDisplayProfile(for session: TBDisplaySenderSession) {
        guard let receiverKey = receiverProfileKey(for: session),
              let rawValue = persistedDisplayProfiles[receiverKey],
              let profile = TBDisplayProfile(rawValue: rawValue)
        else {
            return
        }

        applyDisplayProfile(profile, to: session)
    }

    func sessionTitle(for session: TBDisplaySenderSession) -> String {
        let index = sessions.firstIndex(where: { $0.id == session.id }).map { $0 + 1 } ?? 0
        return TBDisplaySenderL10n.sessionTitle(language, index: index)
    }

    func interfaceDisplayText(for ip: String) -> String {
        localInterfaces.first(where: { $0.ip == ip })?.displayText(language) ?? ip
    }

    func availableInterfaces(for transportKind: TBTransportKind) -> [TBLocalLinkInterface] {
        localInterfaces.filter { $0.transportKind == transportKind }
    }

    func defaultLocalInterfaceIP(for transportKind: TBTransportKind) -> String {
        suggestedInterfaceForNewSession(transportKind: transportKind)?.ip
            ?? availableInterfaces(for: transportKind).first?.ip
            ?? ""
    }

    func transportDidChange(for session: TBDisplaySenderSession) {
        session.localInterfaceIP = defaultLocalInterfaceIP(for: session.transportKind)
        if let receiver = discoveredReceivers.first(where: { $0.id == session.selectedReceiverID }) {
            session.receiverIP = receiver.ip(for: session.transportKind)
        }
        objectWillChange.send()
    }

    func refreshAddons() {
        addonStore.refresh()
    }

    func openAddonsFolder() {
        addonStore.openAddonsFolder()
    }

    func importAddonManifest(from url: URL) throws {
        _ = try addonStore.importManifest(from: url)
        normalizeAddonState()
    }

    func isAddonEnabled(_ addon: TBAddonRecord) -> Bool {
        addonStore.isEnabled(addon)
    }

    func setAddonEnabled(_ enabled: Bool, for addon: TBAddonRecord) {
        addonStore.setEnabled(enabled, for: addon)
        normalizeAddonState()
    }

    func isAddonCompatible(_ addon: TBAddonRecord) -> Bool {
        addonStore.isCompatible(addon)
    }

    func summaryStatusText() -> String {
        if anyStreaming {
            return TBDisplaySenderL10n.multiSessionSummaryStreaming(language, active: connectedSessionCount, total: sessions.count)
        }
        if anyConnected {
            return TBDisplaySenderL10n.multiSessionSummaryConnected(language, active: connectedSessionCount, total: sessions.count)
        }
        return TBDisplaySenderStatusState.ready.text(language)
    }

    private func attachSession(_ session: TBDisplaySenderSession) {
        session.audioAddonAvailable = audioTransportAvailable
        session.audioDriverAvailable = audioDriverAvailable
        session.onRemoteSwitchRequest = { [weak self, weak session] direction in
            guard let self, let session else { return }
            self.switchReceiverMasterTarget(from: session, direction: direction)
        }
        session.onRemoteDeactivateInputRequest = { [weak self, weak session] in
            guard let self, let session else { return }
            self.setInputControlRole(.off, for: session)
        }
        sessionCancellables[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.updateInputRelayController()
            self?.schedulePersist()
            self?.objectWillChange.send()
        }
    }

    func isInputRelayActive(for session: TBDisplaySenderSession) -> Bool {
        session.inputControlRole != .off
    }

    func setInputControlRole(_ role: TBInputControlRole, for session: TBDisplaySenderSession) {
        for candidate in sessions {
            if candidate.id == session.id {
                candidate.inputControlRole = role
            } else if role != .off {
                candidate.inputControlRole = .off
            }
        }
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
        objectWillChange.send()
    }

    func switchSenderMasterTarget(direction: Int) {
        let connected = sessions.filter { $0.isConnected || $0.isStreaming }
        guard connected.count > 1,
              let current = connected.first(where: { $0.inputControlRole == .senderMaster }),
              let currentIndex = connected.firstIndex(where: { $0.id == current.id })
        else {
            return
        }

        let nextIndex = (currentIndex + (direction >= 0 ? 1 : connected.count - 1)) % connected.count
        let next = connected[nextIndex]
        guard next.id != current.id else { return }

        for candidate in sessions {
            candidate.inputControlRole = (candidate.id == next.id) ? .senderMaster : .off
        }
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
        objectWillChange.send()
    }

    func switchReceiverMasterTarget(from session: TBDisplaySenderSession, direction: Int) {
        let connected = sessions.filter { $0.isConnected || $0.isStreaming }
        guard connected.count > 1,
              let currentIndex = connected.firstIndex(where: { $0.id == session.id })
        else {
            return
        }

        let nextIndex = (currentIndex + (direction >= 0 ? 1 : connected.count - 1)) % connected.count
        let next = connected[nextIndex]
        guard next.id != session.id else { return }

        for candidate in sessions {
            candidate.inputControlRole = (candidate.id == next.id) ? .receiverMaster : .off
        }
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
        objectWillChange.send()
    }

    private func isAddonCapabilityEnabled(_ capability: TBAddonCapability) -> Bool {
        addonStore.isCapabilityEnabled(capability)
    }

    private func normalizeAddonState() {
        let networkLinkEnabled = isAddonCapabilityEnabled(.networkLink)
        let audioEnabled = audioTransportAvailable
        let inputEnabled = inputDockstationAvailable

        for session in sessions {
            // Availability is reported, never written into the user's choice.
            //
            // This used to do `if !audioEnabled { session.audioEnabled = false }`,
            // and since `audioEnabled` is the PERSISTED field that latched audio
            // off for good: one launch where the addon had not loaded yet turned
            // the preference off, and the addon coming back could not turn it on
            // again. Observed as `audioEnabled: false` in the saved session with
            // the addon plainly enabled, which left the sender never binding its
            // audio port, so the driver's liveness probe found nothing and
            // withdrew the device from the whole system.
            //
            // Nothing needs this write: both places that act on audio check
            // availability themselves at the point of use, and the UI greys the
            // control off `audioAddonAvailable`.
            session.audioAddonAvailable = audioEnabled
            if !networkLinkEnabled, session.transportKind == .networkLink {
                session.transportKind = .thunderboltBridge
            }
            if !inputEnabled {
                session.inputControlRole = .off
                session.inputGestureMode = .native
            }
        }

        normalizeSessionInterfaces()
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
    }

    private func updateInputRelayController() {
        guard inputDockstationAvailable,
              let session = sessions.first(where: { $0.inputControlRole == .senderMaster })
        else {
            inputRelayController.stop()
            return
        }

        inputRelayController.start(
            gestureMode: session.inputGestureMode,
            handler: { [weak self] relayEvent in
                guard let self,
                      session.isConnected
                else { return }
                session.sendInputEvent(relayEvent)
            },
            switchHandler: { [weak self] direction in
                self?.switchSenderMasterTarget(direction: direction)
            },
            deactivateHandler: { [weak self, weak session] in
                guard let self, let session else { return }
                self.setInputControlRole(.off, for: session)
            }
        )
    }

    private func startClipboardMonitoring() {
        clipboardTimer?.invalidate()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollClipboardIfNeeded()
            }
        }
    }

    private func pollClipboardIfNeeded() {
        guard let session = sessions.first(where: { $0.inputControlRole == .senderMaster && ($0.isConnected || $0.isStreaming) }) else {
            lastClipboardChangeCount = NSPasteboard.general.changeCount
            return
        }

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string) else { return }
        session.sendClipboardText(text)
    }

    private func suggestedInterfaceForNewSession(transportKind: TBTransportKind) -> TBLocalLinkInterface? {
        let candidates = availableInterfaces(for: transportKind)
        let usedIPs = Set(
            sessions
                .filter { $0.transportKind == transportKind }
                .map(\.localInterfaceIP)
                .filter { !$0.isEmpty }
        )
        return candidates.first(where: { !usedIPs.contains($0.ip) }) ?? candidates.first
    }

    /// Keeps each session pointed at a local interface that actually exists,
    /// WITHOUT throwing away the one the user chose.
    ///
    /// The naive version — replace the IP whenever it is not currently valid —
    /// loses the choice permanently the first time a cable is unplugged. The
    /// Thunderbolt address disappears, a fallback is written in its place, and
    /// because the fallback is itself valid the guard never fires again once the
    /// cable is back. Observed exactly that: a session on 10.0.1.1 silently
    /// repointed at a VM bridge on 192.168.64.1 and stayed there, which breaks
    /// reconnecting by hand as surely as it breaks auto-cast.
    ///
    /// So remember the preference separately from the working value: fall back
    /// while it is missing, restore it the moment it returns.
    private func normalizeSessionInterfaces() {
        for session in sessions {
            let available = availableInterfaces(for: session.transportKind)
            let validIPs = Set(available.map(\.ip))

            // A valid current IP that we have not recorded yet is the user's
            // choice, by definition — this is the only place it can be learned.
            if session.preferredLocalInterfaceIP.isEmpty,
               validIPs.contains(session.localInterfaceIP) {
                session.preferredLocalInterfaceIP = session.localInterfaceIP
            }

            if validIPs.contains(session.preferredLocalInterfaceIP) {
                // Back again (cable replugged) — restore it, even if the
                // fallback we are currently on is perfectly valid.
                if session.localInterfaceIP != session.preferredLocalInterfaceIP {
                    NSLog("[interface] \(session.preferredLocalInterfaceIP) is back; restoring it over \(session.localInterfaceIP)")
                    session.localInterfaceIP = session.preferredLocalInterfaceIP
                }
                continue
            }

            if session.localInterfaceIP.isEmpty || !validIPs.contains(session.localInterfaceIP) {
                let fallbackIP = suggestedInterfaceForNewSession(transportKind: session.transportKind)?.ip
                    ?? available.first?.ip
                    ?? ""
                // Deliberately not touching preferredLocalInterfaceIP: this is a
                // stand-in while the real one is away, not a new choice.
                session.localInterfaceIP = fallbackIP
            }
        }
    }

    /// Called on every discovery update. Cheap and side-effect-free unless
    /// TBAutoCast actually says to dial — the decision itself lives there so it
    /// can be tested without Bonjour.
    private func evaluateAutoCast() {
        let candidates = discoveredReceivers.map {
            TBAutoCast.Candidate(id: $0.id, ips: [$0.preferredIP, $0.thunderboltIP, $0.networkIP])
        }

        for session in sessions {
            // Re-arm first: a deliberate disconnect is only honoured until the
            // receiver actually leaves. Unplugging and plugging back in is how a
            // person says "yes, again" — without this the suppression would be
            // permanent for the rest of the launch.
            //
            // "Gone" has to be judged the same way a match is, or a session
            // configured by hand would never re-arm: it has no service name.
            if session.autoCastSuppressedByManualStop {
                let wantedService = TBAutoCast.serviceName(ofReceiverID: session.selectedReceiverID)
                let stillHere = candidates.contains {
                    (!session.selectedReceiverID.isEmpty
                        && TBAutoCast.serviceName(ofReceiverID: $0.id) == wantedService)
                    || (!session.receiverIP.isEmpty && $0.ips.contains(session.receiverIP))
                }
                if !stillHere {
                    session.autoCastSuppressedByManualStop = false
                    session.lastAutoCastAttempt = nil
                }
            }

            let decision = TBAutoCast.decide(TBAutoCast.Input(
                enabled: session.autoCastEnabled,
                sessionIsBusy: session.isBusyForAutoCast,
                rememberedReceiverID: session.selectedReceiverID,
                rememberedReceiverIP: session.receiverIP,
                suppressedByManualStop: session.autoCastSuppressedByManualStop,
                secondsSinceLastAttempt: session.lastAutoCastAttempt.map { -$0.timeIntervalSinceNow },
                candidates: candidates
            ))

            // Log the reason, but only when it changes — discovery republishes
            // several times a second. Without this, "the toggle is on and
            // nothing happens" is invisible from the outside, which is exactly
            // the failure that shipped.
            if case .wait(let reason) = decision {
                if session.autoCastEnabled, session.lastAutoCastWaitReason != reason {
                    session.lastAutoCastWaitReason = reason
                    NSLog("[autocast] waiting: \(reason)")
                }
                continue
            }
            session.lastAutoCastWaitReason = nil

            guard case .connect(let receiverID) = decision else { continue }
            guard let receiver = discoveredReceivers.first(where: { $0.id == receiverID }) else { continue }

            session.lastAutoCastAttempt = Date()
            // Re-apply the receiver rather than trusting the stored IP: the match
            // was made on service name precisely because the address may have
            // moved since it was persisted.
            applyDiscoveredReceiver(receiver, to: session)
            session.selectedReceiverID = receiver.id
            if session.localInterfaceIP.isEmpty {
                session.localInterfaceIP = defaultLocalInterfaceIP(for: session.transportKind)
            }
            NSLog("[autocast] \(receiver.serviceName) appeared at \(session.receiverIP); connecting")
            session.connect()
        }
    }

    private func pushLanguageUpdateToDiscoveredReceivers() {
        let receivers = discoveredReceivers
        let languageCode = language.fileStem
        for receiver in receivers {
            let candidateIPs = [receiver.preferredIP, receiver.thunderboltIP, receiver.networkIP]
            var sentTo = Set<String>()
            for ip in candidateIPs where !ip.isEmpty && sentTo.insert(ip).inserted {
                sendLanguageUpdate(to: ip, languageCode: languageCode)
            }
        }
    }

    private func sendLanguageUpdate(to receiverIP: String, languageCode: String) {
        guard !receiverIP.isEmpty,
              let packet = TBMonitorProtocol.makeJSONPacket(
                type: .uiLanguage,
                value: TBMonitorUILanguageUpdate(uiLanguage: languageCode)
              )
        else { return }

        let connection = NWConnection(
            host: NWEndpoint.Host(receiverIP),
            port: NWEndpoint.Port(rawValue: TBMonitorProtocol.port)!,
            using: .tcp
        )

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: packet, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func detectLocalInterfaces() -> [TBLocalLinkInterface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var interfaces: [TBLocalLinkInterface] = []
        var pointer = ifaddr
        while let iface = pointer {
            defer { pointer = iface.pointee.ifa_next }
            guard let sa = iface.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let name = String(cString: iface.pointee.ifa_name)
            let flags = Int32(iface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let ip = String(cString: buffer)
            if name.hasPrefix("bridge"), ip.hasPrefix("169.254.") {
                interfaces.append(TBLocalLinkInterface(name: name, ip: ip, transportKind: .thunderboltBridge))
                continue
            }

            guard isLikelyLocalNetworkInterfaceName(name),
                  isLikelyLANIPv4(ip)
            else { continue }

            interfaces.append(TBLocalLinkInterface(name: name, ip: ip, transportKind: .networkLink))
        }

        return interfaces.sorted {
            if $0.transportKind == $1.transportKind, $0.name == $1.name {
                return $0.ip < $1.ip
            }
            if $0.transportKind == $1.transportKind {
                return $0.name < $1.name
            }
            return $0.transportKind.rawValue < $1.transportKind.rawValue
        }
    }

    private func isLikelyLocalNetworkInterfaceName(_ name: String) -> Bool {
        if name.hasPrefix("lo") || name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") {
            return false
        }
        return name.hasPrefix("en")
            || name.hasPrefix("eth")
            || name.hasPrefix("bridge")
    }

    private func isLikelyLANIPv4(_ ip: String) -> Bool {
        if ip.hasPrefix("169.254.") || ip.hasPrefix("127.") {
            return false
        }
        if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") {
            return true
        }
        let components = ip.split(separator: ".")
        guard components.count == 4,
              let first = Int(components[0]),
              let second = Int(components[1])
        else {
            return false
        }
        return first == 172 && (16...31).contains(second)
    }
}
