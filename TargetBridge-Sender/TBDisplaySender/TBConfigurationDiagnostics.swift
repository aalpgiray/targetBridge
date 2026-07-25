import Foundation

enum TBConfigurationCheckState: String, Equatable {
    case passed
    case attention
    case pending
}

struct TBConfigurationCheck: Identifiable, Equatable {
    let id: String
    let state: TBConfigurationCheckState
    let titleKey: String
    let detailKey: String
    let values: [String: String]
}

struct TBConfigurationDiagnosticSnapshot {
    var hasScreenRecording: Bool
    var transportIsThunderbolt: Bool
    var localInterfaceName: String?
    var receiverAddress: String
    var receiverProfileAvailable: Bool
    var receiverSupportsHEVC: Bool?
    var requiresHEVC: Bool
    var cableRate: Double?
    var requiresSenderInputMonitoring: Bool
    var senderInputMonitoringGranted: Bool
    var requiresSenderAccessibility: Bool
    var senderAccessibilityGranted: Bool
    var requiresReceiverInputMonitoring: Bool
    var receiverInputMonitoringGranted: Bool?
    var requiresReceiverAccessibility: Bool
    var receiverAccessibilityGranted: Bool?
}

enum TBConfigurationDiagnostics {
    static func checks(for snapshot: TBConfigurationDiagnosticSnapshot) -> [TBConfigurationCheck] {
        var checks = [
            check("screen_recording", snapshot.hasScreenRecording ? .passed : .attention, "sender.diagnostics.screen_recording", snapshot.hasScreenRecording ? "sender.diagnostics.granted" : "sender.diagnostics.screen_recording_missing"),
            localLinkCheck(snapshot),
            check("receiver_address", snapshot.receiverAddress.isEmpty ? .attention : .passed, "sender.diagnostics.receiver_address", snapshot.receiverAddress.isEmpty ? "sender.diagnostics.receiver_address_missing" : "sender.diagnostics.receiver_address_ready"),
            receiverCheck(snapshot),
            cableCheck(snapshot)
        ]
        appendInputChecks(to: &checks, snapshot: snapshot)
        return checks
    }

    private static func localLinkCheck(_ snapshot: TBConfigurationDiagnosticSnapshot) -> TBConfigurationCheck {
        guard let interface = snapshot.localInterfaceName, !interface.isEmpty else {
            return check("local_link", .attention, "sender.diagnostics.local_link", "sender.diagnostics.local_link_missing")
        }
        let isBridge = interface.lowercased().hasPrefix("bridge")
        let state: TBConfigurationCheckState = snapshot.transportIsThunderbolt && !isBridge ? .attention : .passed
        let detail = snapshot.transportIsThunderbolt
            ? (isBridge ? "sender.diagnostics.thunderbolt_link_ready" : "sender.diagnostics.thunderbolt_link_unexpected")
            : "sender.diagnostics.network_link_selected"
        return check("local_link", state, "sender.diagnostics.local_link", detail, ["interface": interface])
    }

    private static func receiverCheck(_ snapshot: TBConfigurationDiagnosticSnapshot) -> TBConfigurationCheck {
        guard snapshot.requiresHEVC else {
            return check("receiver_profile", snapshot.receiverProfileAvailable ? .passed : .pending, "sender.diagnostics.receiver_profile", snapshot.receiverProfileAvailable ? "sender.diagnostics.receiver_profile_ready" : "sender.diagnostics.receiver_profile_pending")
        }
        guard let supportsHEVC = snapshot.receiverSupportsHEVC else {
            return check("receiver_profile", .pending, "sender.diagnostics.hevc", "sender.diagnostics.hevc_pending")
        }
        return check("receiver_profile", supportsHEVC ? .passed : .attention, "sender.diagnostics.hevc", supportsHEVC ? "sender.diagnostics.hevc_ready" : "sender.diagnostics.hevc_missing")
    }

    private static func cableCheck(_ snapshot: TBConfigurationDiagnosticSnapshot) -> TBConfigurationCheck {
        guard let rate = snapshot.cableRate else {
            return check("cable", .pending, "sender.diagnostics.cable", "sender.diagnostics.cable_pending")
        }
        return check("cable", .passed, "sender.diagnostics.cable", "sender.diagnostics.cable_ready", ["rate": String(format: "%.2f", rate)])
    }

    private static func appendInputChecks(to checks: inout [TBConfigurationCheck], snapshot: TBConfigurationDiagnosticSnapshot) {
        if snapshot.requiresSenderInputMonitoring {
            checks.append(check("sender_input_monitoring", snapshot.senderInputMonitoringGranted ? .passed : .attention, "sender.diagnostics.sender_input_monitoring", snapshot.senderInputMonitoringGranted ? "sender.diagnostics.granted" : "sender.diagnostics.input_monitoring_missing"))
        }
        if snapshot.requiresSenderAccessibility {
            checks.append(check("sender_accessibility", snapshot.senderAccessibilityGranted ? .passed : .attention, "sender.diagnostics.sender_accessibility", snapshot.senderAccessibilityGranted ? "sender.diagnostics.granted" : "sender.diagnostics.accessibility_missing"))
        }
        if snapshot.requiresReceiverInputMonitoring {
            checks.append(remotePermissionCheck("receiver_input_monitoring", snapshot.receiverInputMonitoringGranted, "sender.diagnostics.receiver_input_monitoring"))
        }
        if snapshot.requiresReceiverAccessibility {
            checks.append(remotePermissionCheck("receiver_accessibility", snapshot.receiverAccessibilityGranted, "sender.diagnostics.receiver_accessibility"))
        }
    }

    private static func remotePermissionCheck(_ id: String, _ granted: Bool?, _ title: String) -> TBConfigurationCheck {
        guard let granted else { return check(id, .pending, title, "sender.diagnostics.receiver_permission_pending") }
        return check(id, granted ? .passed : .attention, title, granted ? "sender.diagnostics.granted" : "sender.diagnostics.permission_missing")
    }

    private static func check(_ id: String, _ state: TBConfigurationCheckState, _ title: String, _ detail: String, _ values: [String: String] = [:]) -> TBConfigurationCheck {
        TBConfigurationCheck(id: id, state: state, titleKey: title, detailKey: detail, values: values)
    }
}
