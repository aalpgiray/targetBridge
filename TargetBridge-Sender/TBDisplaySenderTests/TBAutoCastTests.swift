import XCTest
@testable import TargetBridge

/// The auto-cast rule: when may the sender dial a receiver without being asked?
///
/// WHY THESE ARE WORTH WRITING
///
/// A missed auto-connect is visible and recoverable — the Connect button is right
/// there. The failures worth defending against are the opposite, and none of them
/// reproduce on demand:
///
///   - dialling while a session is already coming up, because Bonjour republishes
///     the same service several times a second and the in-flight window between
///     "dialling" and "connected" is wide open
///   - re-connecting a session the user just disconnected on purpose, which turns
///     the Disconnect button into a no-op
///   - retrying a failing dial as fast as discovery fires
final class TBAutoCastTests: XCTestCase {

    /// A configured, idle session with its receiver present — the happy path, and
    /// the baseline every other test mutates one field of.
    private func armed(
        enabled: Bool = true,
        busy: Bool = false,
        remembered: String = "iMac-5K._targetbridge._tcp.|10.0.1.2",
        rememberedIP: String = "10.0.1.2",
        suppressed: Bool = false,
        sinceLastAttempt: TimeInterval? = nil,
        candidates: [String] = ["iMac-5K._targetbridge._tcp.|10.0.1.2"],
        candidateIPs: [String] = ["10.0.1.2"]
    ) -> TBAutoCast.Input {
        TBAutoCast.Input(
            enabled: enabled,
            sessionIsBusy: busy,
            rememberedReceiverID: remembered,
            rememberedReceiverIP: rememberedIP,
            suppressedByManualStop: suppressed,
            secondsSinceLastAttempt: sinceLastAttempt,
            candidates: candidates.map { TBAutoCast.Candidate(id: $0, ips: candidateIPs) }
        )
    }

    private func assertWaits(_ input: TBAutoCast.Input, _ message: String) {
        guard case .wait = TBAutoCast.decide(input) else {
            return XCTFail("expected no connect: \(message)")
        }
    }

    // MARK: - the one case that should connect

    func testConnectsWhenTheConfiguredReceiverAppears() {
        XCTAssertEqual(TBAutoCast.decide(armed()),
                       .connect(receiverID: "iMac-5K._targetbridge._tcp.|10.0.1.2"))
    }

    /// The reason matching is on the service name and not the whole `id`: the id
    /// embeds the IP, so a DHCP change, a receiver reboot or a cable reconnect can
    /// all produce a different id for the same physical iMac. Matching the full id
    /// would silently stop auto-casting the first time the address moved.
    func testStillMatchesAfterTheReceiverChangesAddress() {
        let decision = TBAutoCast.decide(armed(
            remembered: "iMac-5K._targetbridge._tcp.|10.0.1.2",
            candidates: ["iMac-5K._targetbridge._tcp.|192.168.4.31"],
            candidateIPs: ["192.168.4.31"]
        ))
        XCTAssertEqual(decision, .connect(receiverID: "iMac-5K._targetbridge._tcp.|192.168.4.31"),
                       "must follow the service name to its new address")
    }

    /// And the converse — a *different* receiver appearing must not be treated as
    /// the configured one just because something showed up.
    func testDoesNotConnectToAStrangerOnTheNetwork() {
        assertWaits(armed(rememberedIP: "10.0.1.2",
                          candidates: ["SomeoneElse-iMac._targetbridge._tcp.|10.0.1.9"],
                          candidateIPs: ["10.0.1.9"]),
                    "an unrelated receiver is not the configured one")
    }

    // MARK: - the cases that must not connect

    func testOffByDefaultMeansOff() {
        assertWaits(armed(enabled: false), "the toggle is off")
    }

    /// The redundant-callback guard. `sessionIsBusy` includes a non-nil connection,
    /// so this covers the in-flight dial, not just a live session.
    func testDoesNotDialASessionThatIsAlreadyComingUp() {
        assertWaits(armed(busy: true), "a dial is already in flight")
    }

    /// Auto-cast must never make the Disconnect button look broken.
    func testRespectsADeliberateDisconnect() {
        assertWaits(armed(suppressed: true), "the user stopped this session by hand")
    }

    func testNeedsAReceiverToHaveBeenConfigured() {
        assertWaits(armed(remembered: "", rememberedIP: ""), "nothing has been configured to connect to")
        assertWaits(armed(remembered: "", rememberedIP: "", candidates: []), "no receiver, no candidates")
    }

    func testDoesNotConnectWhenTheReceiverIsAbsent() {
        assertWaits(armed(candidates: [], candidateIPs: []), "the configured receiver is not on the network")
    }

    // MARK: - backoff

    /// Discovery republishes far faster than a dial can fail, so without a floor
    /// a receiver that is present but not yet accepting would be hammered.
    func testBacksOffBetweenAttempts() {
        assertWaits(armed(sinceLastAttempt: 0), "an attempt just happened")
        assertWaits(armed(sinceLastAttempt: TBAutoCast.retryInterval - 0.1), "still inside the interval")
    }

    /// But it must genuinely retry afterwards. One attempt per appearance would
    /// leave a session stuck whenever the first dial lost a race with the
    /// receiver's listener coming up.
    func testRetriesOnceTheIntervalHasPassed() {
        XCTAssertEqual(TBAutoCast.decide(armed(sinceLastAttempt: TBAutoCast.retryInterval + 0.1)),
                       .connect(receiverID: "iMac-5K._targetbridge._tcp.|10.0.1.2"))
    }

    // MARK: - service-name parsing

    func testServiceNameIgnoresTheAddressHalf() {
        XCTAssertEqual(TBAutoCast.serviceName(ofReceiverID: "iMac._tb._tcp.|10.0.1.2"), "iMac._tb._tcp.")
        // No separator: the whole string is the name rather than nothing, so a
        // malformed id degrades to "never matches" instead of "matches everything".
        XCTAssertEqual(TBAutoCast.serviceName(ofReceiverID: "iMac"), "iMac")
        XCTAssertEqual(TBAutoCast.serviceName(ofReceiverID: ""), "")
    }

    /// The regression that made the shipped toggle look broken: a session
    /// configured by TYPING an address has no selectedReceiverID at all, so
    /// matching only on service name meant auto-cast silently never fired while
    /// the UI cheerfully showed it enabled. Typing 10.0.1.2 is a perfectly
    /// ordinary way to set this up.
    func testWorksForASessionConfiguredByTypingAnAddress() {
        XCTAssertEqual(TBAutoCast.decide(armed(remembered: "", rememberedIP: "10.0.1.2")),
                       .connect(receiverID: "iMac-5K._targetbridge._tcp.|10.0.1.2"),
                       "a hand-typed receiver IP must still auto-cast")
    }

    /// The address may be advertised as any of preferred/thunderbolt/network,
    /// and the one the user typed can be any of them.
    func testMatchesAnyAdvertisedAddress() {
        let input = TBAutoCast.Input(
            enabled: true, sessionIsBusy: false,
            rememberedReceiverID: "", rememberedReceiverIP: "192.168.0.192",
            suppressedByManualStop: false, secondsSinceLastAttempt: nil,
            candidates: [TBAutoCast.Candidate(id: "iMac._tb._tcp.|10.0.1.2",
                                              ips: ["10.0.1.2", "", "192.168.0.192"])]
        )
        XCTAssertEqual(TBAutoCast.decide(input), .connect(receiverID: "iMac._tb._tcp.|10.0.1.2"))
    }

    /// Service name wins when both could match, because it is the identity that
    /// survives the address moving.
    func testServiceNameTakesPrecedenceOverAddress() {
        let input = TBAutoCast.Input(
            enabled: true, sessionIsBusy: false,
            rememberedReceiverID: "wanted._tb._tcp.|10.0.0.1",
            rememberedReceiverIP: "10.0.0.9",
            suppressedByManualStop: false, secondsSinceLastAttempt: nil,
            candidates: [TBAutoCast.Candidate(id: "other._tb._tcp.|10.0.0.9", ips: ["10.0.0.9"]),
                         TBAutoCast.Candidate(id: "wanted._tb._tcp.|10.0.0.5", ips: ["10.0.0.5"])]
        )
        XCTAssertEqual(TBAutoCast.decide(input), .connect(receiverID: "wanted._tb._tcp.|10.0.0.5"))
    }

    /// An empty remembered id must not match an empty-named candidate through the
    /// service-name comparison — the empty check has to come first, which is easy
    /// to reorder away.
    func testEmptyConfigurationNeverMatchesAnything() {
        assertWaits(armed(remembered: "", rememberedIP: "", candidates: ["|10.0.1.2"], candidateIPs: []),
                    "an unconfigured session must not match a nameless service")
    }
}
