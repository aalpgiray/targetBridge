import SwiftUI

@main
struct TBDisplaySenderApp: App {
    @StateObject private var service = TBDisplaySenderService.shared
    private let statusItemController = TBDisplaySenderStatusItemController(service: TBDisplaySenderService.shared)

    var body: some Scene {
        WindowGroup("TargetBridge", id: "main") {
            // A monitor is the unit: sidebar of displays, one page each. Replaces
            // the four-level window > card > sheet > settings structure.
            //
            // TBDisplaySenderContentView is deliberately still compiled. It was
            // mounted, reverted once when the per-session settings SHEET turned out
            // to have no equivalent here, and restored until every control was
            // ported and checked against docs/monitors-window-spec.md. Swapping
            // back is this one line.
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
