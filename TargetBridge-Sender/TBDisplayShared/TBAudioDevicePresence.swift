import Foundation

/// Whether the sender should be answering the audio driver's liveness probe.
///
/// The driver publishes "TargetBridge" in Sound settings only while something
/// accepts UDP on 127.0.0.1:51710, and removes the device after three refused
/// probes. This decides when the sender binds that socket. It does not touch
/// the socket or CoreAudio — the app applies `Step` — so the grace rules can
/// be tested without a driver installed.
enum TBAudioDevicePresence {

    /// How long the sink stays bound after the last receiver stops streaming.
    ///
    /// The driver then needs up to about three seconds of refused probes
    /// before it removes the device. 8 seconds covers a short redial or a
    /// capture restart. One refused probe during a slow handshake does not
    /// withdraw the device, because the driver requires three in a row.
    /// Display sleep does not start this clock when `isStreaming` stays true.
    static let withdrawGrace: TimeInterval = 8

    struct State: Equatable {
        var sinkBound = false
        /// A grace timer is already armed. A second idle report must not
        /// push the deadline later.
        var withdrawArmed = false
    }

    enum Step: Equatable {
        /// Bind the loopback sink and cancel any pending withdraw.
        case bind
        /// The sink is already bound and a receiver is streaming. Cancel any
        /// pending withdraw; do not close and reopen the socket.
        case hold
        /// No receiver is streaming. Arm one withdraw at `withdrawGrace`.
        case armWithdraw
        /// A withdraw is already armed. Leave its deadline alone.
        case keepWithdraw
        /// Close the sink now. The caller restores the previous output first,
        /// while the device is still published.
        case close
        /// The sink is already closed.
        case idle
    }

    /// `anyStreaming` is true when at least one session is streaming. One idle
    /// session must not close the sink out from under another that is still up.
    static func step(addonEnabled: Bool, anyStreaming: Bool, state: State) -> Step {
        if !addonEnabled {
            return state.sinkBound ? .close : .idle
        }
        if anyStreaming {
            return state.sinkBound ? .hold : .bind
        }
        if state.sinkBound {
            return state.withdrawArmed ? .keepWithdraw : .armWithdraw
        }
        return .idle
    }

    /// The grace timer fired. A stream that came back, or a timer that lost
    /// the race with `hold`, must not close the sink.
    static func stepAfterGrace(addonEnabled: Bool, anyStreaming: Bool, state: State) -> Step {
        if addonEnabled && anyStreaming {
            return state.sinkBound ? .hold : .bind
        }
        return state.sinkBound ? .close : .idle
    }
}
