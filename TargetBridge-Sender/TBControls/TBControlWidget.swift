import AppIntents
import SwiftUI
import WidgetKit

/// Connect/disconnect from Control Center and the menu bar.
///
/// This is the mechanism Teams uses -- a WidgetKit extension declaring a
/// ControlWidget -- and it is what puts an app in System Settings > Control
/// Center's "Controls" list, draggable into Control Center OR the menu bar.
///
/// It exists alongside the NSStatusItem rather than replacing it: a Control is a
/// single action and cannot host the status menu's brightness slider, per-monitor
/// rows and toggles. It does have one structural advantage -- macOS owns its
/// placement, so it cannot end up positioned somewhere it will not render, which
/// is the failure the status item hit.
///
/// The action goes through the targetbridge:// URL scheme, deliberately. A
/// Control runs in its own process and cannot read TBDisplaySenderService, so
/// live state would need a shared App Group -- and an App Group changes the
/// entitlements, and therefore the code-signing shape, of an app whose identity
/// macOS has already proven willing to treat oddly (see the NECP connect
/// failures and the suppressed status item). One new mechanism at a time.
@available(macOS 26.0, *)
struct TBConnectControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.targetbridge.sender.connect") {
            ControlWidgetButton(action: TBConnectIntent()) {
                Label("Cast to Monitor", systemImage: "display.2")
            }
        }
        .displayName("Cast to Monitor")
        .description("Start streaming to the TargetBridge receiver.")
    }
}

@available(macOS 26.0, *)
struct TBConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Cast to Monitor"
    static let description = IntentDescription("Connects the sender to its receiver.")
    /// The app must come forward to do the work; the extension only asks.
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "targetbridge://connect")!))
    }
}

@available(macOS 26.0, *)
struct TBDisconnectControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.targetbridge.sender.disconnect") {
            ControlWidgetButton(action: TBDisconnectIntent()) {
                Label("Stop Casting", systemImage: "stop.circle")
            }
        }
        .displayName("Stop Casting")
        .description("Stops the TargetBridge stream.")
    }
}

@available(macOS 26.0, *)
struct TBDisconnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Casting"
    static let description = IntentDescription("Disconnects the sender from its receiver.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "targetbridge://disconnect")!))
    }
}

@main
@available(macOS 26.0, *)
struct TBControlsBundle: WidgetBundle {
    var body: some Widget {
        TBConnectControl()
        TBDisconnectControl()
    }
}
