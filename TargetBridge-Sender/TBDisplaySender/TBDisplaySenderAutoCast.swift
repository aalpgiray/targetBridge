import Foundation

/// Starts casting on its own when a receiver this Mac has used before shows up
/// on the network again.
///
/// WHY
///
/// Plugging in a monitor does not ask you to pick it from a list. The iMac now
/// sits in the menu bar with no window until something casts to it, and the
/// sender already remembers which receiver a session belongs to
/// (`selectedReceiverID`, persisted across launches) — so the last manual step
/// left in "plug the cable in and it works" is a button press that has only one
/// sensible answer.
///
/// WHY THE DECISION IS A PURE FUNCTION
///
/// The dangerous failure here is not "it did not connect", which is visible and
/// recoverable. It is a connect that fires when it should not: Bonjour republishes
/// the same service repeatedly, so anything keyed off "a receiver appeared" runs
/// far more often than a person would guess, and each spurious run either fights
/// a user who deliberately disconnected or hammers a receiver that is not ready.
/// Both are timing-dependent and neither reproduces on demand, so the rule is
/// stated here — away from Combine, Bonjour and the network — where every branch
/// can be checked directly.
enum TBAutoCast {

    /// Minimum spacing between attempts on the same session. Discovery can
    /// republish several times a second; a failed dial must not become a dial
    /// loop.
    static let retryInterval: TimeInterval = 5.0

    enum Decision: Equatable {
        case connect(receiverID: String)
        /// Carries why, because the interesting bug is a connect that did NOT
        /// happen for a reason nobody can see from the outside.
        case wait(reason: String)
    }

    struct Input {
        var enabled: Bool
        /// Connected, connecting or streaming — anything where a second dial
        /// would be wrong.
        var sessionIsBusy: Bool
        /// The receiver this session was last pointed at, as persisted.
        var rememberedReceiverID: String
        /// Set when the user stopped this session by hand. Auto-cast must not
        /// immediately undo a deliberate disconnect; it stays set until the
        /// receiver actually goes away, so the next plug-in re-arms it.
        var suppressedByManualStop: Bool
        /// Time since the last attempt on this session, or nil if none yet.
        var secondsSinceLastAttempt: TimeInterval?
        /// `id` of every receiver currently visible.
        var candidateIDs: [String]
    }

    /// Bonjour service names are stable across a cable reconnect, a receiver
    /// reboot and a DHCP change; the `id` they are embedded in is not, because it
    /// also carries the IP. Matching on the name is what makes "the same iMac"
    /// mean the same iMac after its address moves.
    static func serviceName(ofReceiverID id: String) -> String {
        guard let separator = id.firstIndex(of: "|") else { return id }
        return String(id[id.startIndex..<separator])
    }

    static func decide(_ input: Input) -> Decision {
        guard input.enabled else { return .wait(reason: "auto-cast off for this session") }
        guard !input.sessionIsBusy else { return .wait(reason: "session already active") }
        guard !input.suppressedByManualStop else {
            return .wait(reason: "disconnected by hand; waiting for the receiver to reappear")
        }
        guard !input.rememberedReceiverID.isEmpty else {
            return .wait(reason: "no receiver configured for this session yet")
        }
        if let elapsed = input.secondsSinceLastAttempt, elapsed < retryInterval {
            return .wait(reason: String(format: "retry backoff (%.1fs of %.0fs)", elapsed, retryInterval))
        }

        let wanted = serviceName(ofReceiverID: input.rememberedReceiverID)
        guard let match = input.candidateIDs.first(where: { serviceName(ofReceiverID: $0) == wanted })
        else { return .wait(reason: "configured receiver '\(wanted)' not on the network") }

        return .connect(receiverID: match)
    }
}
