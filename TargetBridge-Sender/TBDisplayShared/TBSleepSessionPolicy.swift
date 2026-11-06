import Foundation

/// How a streaming MacBook treats sleep, and how a teardown is labeled.
///
/// Streaming must not take a sleep assertion of its own. The MacBook is
/// allowed to idle-sleep. `preventDisplaySleep` only asks the display to stay
/// on; it does not block system sleep, and it does not keep an IOPM assertion
/// for the life of the session.
///
/// A display or system sleep is not the Stop button. The session stays
/// latched so wake can resume it. Stop (`user_stop`, and the older
/// `sender_user_stop` / `sender_stop` strings) is the only reason that must
/// not come back by itself.
enum TBSleepSessionPolicy {
    static let displaySleep = "displaySleep"
    static let systemSleep = "systemSleep"
    static let userStop = "user_stop"

    struct StreamingPower: Equatable {
        var allowIdleSystemSleep: Bool
        var preventIdleDisplaySleep: Bool
        /// A long-lived IOPM assertion would keep the MacBook awake for the
        /// whole stream. Streaming does not take one.
        var holdsSleepAssertion: Bool
    }

    static func streamingPower(preventDisplaySleep: Bool) -> StreamingPower {
        StreamingPower(
            allowIdleSystemSleep: true,
            preventIdleDisplaySleep: preventDisplaySleep,
            holdsSleepAssertion: false
        )
    }

    static func isExplicitUserStop(_ reason: String) -> Bool {
        reason == userStop || reason == "sender_stop" || reason == "sender_user_stop"
    }

    static func isDisplayOrSystemSleep(_ reason: String) -> Bool {
        reason == displaySleep || reason == systemSleep
    }

    /// Reason written on the teardown packet. An explicit stop wins. A
    /// display that is already asleep is reported as that sleep, so the
    /// receiver can keep the last frame instead of treating it as Stop.
    static func teardownReason(
        userInitiatedStop: Bool,
        requestedReason: String,
        displayAsleepReason: String?
    ) -> String {
        if userInitiatedStop {
            return userStop
        }
        if isExplicitUserStop(requestedReason) {
            return requestedReason
        }
        if let displayAsleepReason, isDisplayOrSystemSleep(displayAsleepReason) {
            return displayAsleepReason
        }
        return requestedReason
    }

    /// The link died, or something asked to stop, while this Mac's display
    /// is down. That is not the user pressing Stop, so the session stays
    /// latched for wake.
    static func shouldLeaveSessionForWake(displayAsleep: Bool, userInitiatedStop: Bool) -> Bool {
        displayAsleep && !userInitiatedStop
    }

    /// Wake may redial only a session that was latched across sleep, and
    /// never one the user stopped.
    static func shouldReconnectAfterWake(
        userInitiatedStop: Bool,
        autoRestartOnWake: Bool,
        sessionLatched: Bool
    ) -> Bool {
        sessionLatched && autoRestartOnWake && !userInitiatedStop
    }
}
