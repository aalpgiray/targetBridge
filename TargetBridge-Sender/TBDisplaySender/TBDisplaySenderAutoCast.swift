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

    /// A receiver currently visible on the network, and every address it
    /// advertises.
    struct Candidate: Equatable {
        let id: String
        /// preferred / thunderbolt / network, minus the empty ones.
        let ips: [String]

        init(id: String, ips: [String]) {
            self.id = id
            self.ips = ips.filter { !$0.isEmpty }
        }
    }

    struct Input {
        var enabled: Bool
        /// Connected, connecting or streaming — anything where a second dial
        /// would be wrong.
        var sessionIsBusy: Bool
        /// The receiver this session was last pointed at, as persisted. Empty
        /// for a session configured by typing an address instead of choosing
        /// from discovery.
        var rememberedReceiverID: String
        /// The address the session is pointed at. This is what makes auto-cast
        /// work for a hand-configured session: it is perfectly reasonable to
        /// type 10.0.1.2 rather than pick from a menu, and a toggle that
        /// silently does nothing in that case is a broken toggle, not a
        /// documented limitation.
        var rememberedReceiverIP: String
        /// Set when the user stopped this session by hand. Auto-cast must not
        /// immediately undo a deliberate disconnect; it stays set until the
        /// receiver actually goes away, so the next plug-in re-arms it.
        var suppressedByManualStop: Bool
        /// Time since the last attempt on this session, or nil if none yet.
        var secondsSinceLastAttempt: TimeInterval?
        /// Every receiver currently visible.
        var candidates: [Candidate]
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
        guard !input.rememberedReceiverID.isEmpty || !input.rememberedReceiverIP.isEmpty else {
            return .wait(reason: "no receiver configured for this session yet")
        }
        if let elapsed = input.secondsSinceLastAttempt, elapsed < retryInterval {
            return .wait(reason: String(format: "retry backoff (%.1fs of %.0fs)", elapsed, retryInterval))
        }

        // Service name first — it survives an address change, which is the whole
        // reason it is preferred over the id.
        if !input.rememberedReceiverID.isEmpty {
            let wanted = serviceName(ofReceiverID: input.rememberedReceiverID)
            if let match = input.candidates.first(where: { serviceName(ofReceiverID: $0.id) == wanted }) {
                return .connect(receiverID: match.id)
            }
        }

        // Then the address. A session configured by hand has no service name to
        // match, so without this the toggle would appear on and do nothing.
        if !input.rememberedReceiverIP.isEmpty {
            if let match = input.candidates.first(where: { $0.ips.contains(input.rememberedReceiverIP) }) {
                return .connect(receiverID: match.id)
            }
        }

        let wanted = input.rememberedReceiverID.isEmpty
            ? input.rememberedReceiverIP
            : serviceName(ofReceiverID: input.rememberedReceiverID)
        return .wait(reason: "configured receiver '\(wanted)' not on the network")
    }
}
