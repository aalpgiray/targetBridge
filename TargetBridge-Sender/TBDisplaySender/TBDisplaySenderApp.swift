import SwiftUI

/// Owns everything that must exist whether or not a window does.
///
/// The status item used to be a `let` on the App struct, activated from the
/// window's `.task`. SwiftUI does not eagerly construct App properties, so with no
/// window open the controller was never built and no menu bar item existed --
/// which, once the window's entry point moved INTO that menu, left the app running
/// and completely unreachable. An NSApplicationDelegate runs at launch regardless
/// of scenes, which is the only place this can safely live.
final class TBAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: TBDisplaySenderStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = TBDisplaySenderStatusItemController(service: TBDisplaySenderService.shared)
        controller.activate()
        statusItemController = controller

        if TBDisplaySenderService.shared.audioDriverAvailable {
            TBDefaultOutputGuard.shared.begin()
        }
        TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
    }

    /// Closing the window must not quit: the menu bar item is the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no window open reopens one, rather than
    /// activating an app that shows nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

@main
struct TBDisplaySenderApp: App {
    @NSApplicationDelegateAdaptor(TBAppDelegate.self) private var appDelegate
    @StateObject private var service = TBDisplaySenderService.shared

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
                .task { service.refreshLocalInterfaces() }
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
