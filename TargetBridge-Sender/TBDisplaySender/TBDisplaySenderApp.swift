import SwiftUI

@main
struct TBDisplaySenderApp: App {
    @StateObject private var service = TBDisplaySenderService.shared
    private let statusItemController = TBDisplaySenderStatusItemController(service: TBDisplaySenderService.shared)

    var body: some Scene {
        WindowGroup("TargetBridge", id: "main") {
            // The monitors window replaces the old card stack. The previous view
            // still exists and still compiles; it is simply no longer mounted, so
            // reverting is a one-line change if this turns out worse in practice.
            TBMonitorsWindowView(service: service)
                .frame(minWidth: 720, minHeight: 460)
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
