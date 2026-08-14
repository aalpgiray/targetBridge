import SwiftUI

@main
struct TBDisplaySenderApp: App {
    @StateObject private var service = TBDisplaySenderService.shared
    private let statusItemController = TBDisplaySenderStatusItemController(service: TBDisplaySenderService.shared)

    var body: some Scene {
        WindowGroup("TargetBridge", id: "main") {
            // RESTORED. TBMonitorsWindowView is the redesign and it is still in the
            // build, but it only covers what the session CARD showed -- transport,
            // local interface, manual receiver entry, discovery, stream profile,
            // capture source, display profiles and the cable test all lived in the
            // per-session settings SHEET, and mounting the new window made every
            // one of them unreachable. Streaming quality is not an option you can
            // ship without.
            //
            // Swap back to TBMonitorsWindowView once those sections exist on the
            // monitor page.
            TBDisplaySenderContentView(service: service)
                .frame(minWidth: 540)
                .task {
                    statusItemController.activate()
                    // Track which output the user was on before selecting ours,
                    // so we can hand it back rather than leaving them silent.
                    // Only meaningful when our device exists to be selected.
                    if service.audioDriverAvailable {
                        TBDefaultOutputGuard.shared.begin()
                    }
                    TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
                }
                .onOpenURL { url in
                    TBSenderAutomation.handle(url: url)
                }
        }
        .defaultSize(width: 860, height: 860)

        Settings {
            TBDisplaySenderSettingsView(service: service)
                .frame(minWidth: 760, minHeight: 620)
        }
    }
}
