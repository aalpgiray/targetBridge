import SwiftUI

/// The sender's main window: a sidebar of monitors, and one page per monitor.
///
/// Replaces a four-level structure — window → session card → settings sheet →
/// settings window — that the user summarised as "everything is a mess". The
/// organising idea is that **a monitor is the unit**: everything about one display
/// lives on one page, so there is no level to descend into and no sheet to open.
///
/// The word "session" does not appear. Internally sessions still exist and more
/// than one can stream at once; the UI simply calls them monitors, because that is
/// what they are to the person using them.
///
/// Native chrome throughout — `Form`/`.formStyle(.grouped)`, `Section`,
/// `LabeledContent` — rather than the previous bespoke cards, gradient tiles and
/// hand-built status chips. Looking like macOS is mostly a matter of not
/// overriding it.
struct TBMonitorsWindowView: View {
    @ObservedObject var service: TBDisplaySenderService
    @State private var selection: TBDisplaySenderSession.ID?
    @State private var showingAbout = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let session = selectedSession {
                TBMonitorPageView(service: service, session: session)
                    .id(session.id)
            } else {
                TBNoMonitorsView(service: service)
            }
        }
        .navigationTitle("")
        .task { service.refreshLocalInterfaces() }
        .sheet(isPresented: $showingAbout) {
            TBDisplaySenderAboutView(service: service)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    service.addSession()
                } label: {
                    Label(TBDisplaySenderL10n.addSessionButton(service.language),
                          systemImage: "plus")
                }
                Button { showingAbout = true } label: {
                    Label("About",
                          systemImage: "info.circle")
                }
            }
        }
        .onAppear { if selection == nil { selection = service.sessions.first?.id } }
        // A removed monitor must not leave the detail pane bound to a dead session.
        .onChange(of: service.sessions.count) { _, _ in
            if selection == nil || !service.sessions.contains(where: { $0.id == selection }) {
                selection = service.sessions.first?.id
            }
        }
    }

    private var selectedSession: TBDisplaySenderSession? {
        service.sessions.first(where: { $0.id == selection }) ?? service.sessions.first
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section(TBDisplaySenderL10n.connectionGroup(service.language)) {
                ForEach(service.sessions) { session in
                    TBMonitorRowView(service: service, session: session)
                        .tag(session.id as TBDisplaySenderSession.ID?)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        .safeAreaInset(edge: .bottom) {
            // The local interface belongs here rather than in a header card: it is
            // context for the whole list, and it is the first thing to check when
            // nothing connects.
            VStack(alignment: .leading, spacing: 2) {
                Divider()
                Text(service.localInterfaceSummaryText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// One sidebar row. Status is a dot plus a word — legible at a glance without
/// reading, which a bare label is not.
struct TBMonitorRowView: View {
    @ObservedObject var service: TBDisplaySenderService
    @ObservedObject var session: TBDisplaySenderSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isStreaming ? Color.green
                      : (session.isConnected ? Color.yellow : Color.secondary.opacity(0.35)))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.sessionTitle(for: session))
                    .lineLimit(1)
                Text(session.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Everything about one monitor, on one page. No sheets, no sub-levels.
struct TBMonitorPageView: View {
    @ObservedObject var service: TBDisplaySenderService
    @ObservedObject var session: TBDisplaySenderSession
    @State private var showDiagnostics = false

    var body: some View {
        Form {
            connectionSection
            displaySection
            soundSection
            behaviourSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .navigationTitle(service.sessionTitle(for: session))
        .navigationSubtitle(session.statusText)
    }

    // MARK: Connect

    private var connectionSection: some View {
        Section {
            LabeledContent(TBDisplaySenderL10n.receiverIP(service.language)) {
                Text(session.receiverIP.isEmpty
                     ? "—"
                     : session.receiverIP)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(session.isConnected
                       ? TBDisplaySenderL10n.stopButton(service.language)
                       : TBDisplaySenderL10n.connectButton(service.language)) {
                    if session.isConnected { session.stop() } else { session.connect() }
                }
                .buttonStyle(.borderedProminent)

                if service.sessions.count > 1 {
                    Button(TBDisplaySenderL10n.removeSessionButton(service.language),
                           role: .destructive) {
                        service.removeSession(session)
                    }
                }
                Spacer()
            }
        } header: {
            Text(TBDisplaySenderL10n.connectionGroup(service.language))
        } footer: {
            // The status string carries real failure detail — it is where
            // "connect: refused" and NWError text surface — so it stays visible
            // rather than living in a transient chip.
            Text(session.statusText).foregroundStyle(.secondary)
        }
    }

    // MARK: Display

    private var displaySection: some View {
        Section(TBDisplaySenderL10n.streamResolutionGroup(service.language)) {
            LabeledContent(TBDisplaySenderL10n.streamLabel(service.language)) {
                Text(session.streamResolutionText).foregroundStyle(.secondary)
            }
            if session.isConnected {
                LabeledContent("Brightness") {
                    Slider(value: $session.brightness, in: 0...1).frame(width: 200)
                }
                if session.receiverSupportsNightShift {
                    Toggle("Night Shift",
                           isOn: $session.nightShiftEnabled)
                }
                if session.receiverSupportsTrueTone {
                    Toggle("True Tone",
                           isOn: $session.trueToneEnabled)
                }
            }
            Toggle("V-Sync",
                   isOn: $session.vsyncEnabled)
        }
    }

    // MARK: Sound

    private var soundSection: some View {
        Section(TBDisplaySenderL10n.streamAudio(service.language)) {
            Toggle(TBDisplaySenderL10n.streamAudio(service.language),
                   isOn: $session.audioEnabled)
            if session.isConnected {
                LabeledContent("Volume") {
                    Slider(value: $session.volume, in: 0...1).frame(width: 200)
                }
            }
        }
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        Section {
            Toggle(TBDisplaySenderL10n.preventDisplaySleep(service.language),
                   isOn: $session.preventDisplaySleep)
            Toggle(TBDisplaySenderL10n.autoRestartOnWake(service.language),
                   isOn: $session.autoRestartOnWake)
            Toggle(TBDisplaySenderL10n.largeCursor(service.language),
                   isOn: $session.largeCursor)
        }
    }

    // MARK: Diagnostics — collapsed, because it is for when something is wrong

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showDiagnostics) {
                LabeledContent(TBDisplaySenderL10n.fpsLabel(service.language)) {
                    Text("\(session.liveMetrics.senderFPS)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent(TBDisplaySenderL10n.videoPathLabel(service.language)) {
                    Text(session.captureDisplayText).foregroundStyle(.secondary)
                }
                LabeledContent(TBDisplaySenderL10n.virtualDisplayLabel(service.language)) {
                    Text(session.virtualDisplayText).foregroundStyle(.secondary)
                }
                LabeledContent("Receiver panel") {
                    Text(session.receiverPanelText).foregroundStyle(.secondary)
                }
                Button(TBDisplaySenderL10n.restartCaptureButton(service.language)) {
                    session.restartCaptureNow()
                }
            } label: {
                Text("Diagnostics")
            }
        }
    }
}

/// Shown when there is nothing to configure. A blank pane tells a first-time user
/// nothing about what to do next, so this states the two things setup requires.
struct TBNoMonitorsView: View {
    @ObservedObject var service: TBDisplaySenderService

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "display.2")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No displays yet")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Install TargetBridge Receiver on the other Mac and open it.")
                step(2, "Connect the two Macs with Thunderbolt, or put both on the same network.")
            }
            .frame(maxWidth: 380, alignment: .leading)
            Button(TBDisplaySenderL10n.addSessionButton(service.language)) {
                service.addSession()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
                .background(.secondary.opacity(0.18), in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
