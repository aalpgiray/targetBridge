import XCTest
@testable import TargetBridge

/// Tests for the discovered-receiver value model: per-transport address
/// selection and the human-readable summary. These pin down which IP the
/// sender dials for Thunderbolt vs Network Link — the exact decision that
/// determines whether traffic goes over the bridge or the LAN.
final class TBReceiverDiscoveryModelTests: XCTestCase {

    private func makeReceiver(
        serviceName: String = "TargetBridge Test-iMac",
        receiverName: String = "Test-iMac",
        preferredIP: String = "192.168.1.64",
        thunderboltIP: String = "",
        networkIP: String = "",
        panelSummary: String = "",
        version: String = "3.1.0",
        supportsHEVCDecode: Bool = true,
        hostName: String? = nil
    ) -> TBDiscoveredReceiver {
        TBDiscoveredReceiver(
            serviceName: serviceName,
            receiverName: receiverName,
            preferredIP: preferredIP,
            thunderboltIP: thunderboltIP,
            networkIP: networkIP,
            panelSummary: panelSummary,
            version: version,
            supportsHEVCDecode: supportsHEVCDecode,
            hostName: hostName
        )
    }

    // MARK: - ip(for:) transport selection

    func testThunderboltTransportPrefersThunderboltIP() {
        let receiver = makeReceiver(preferredIP: "192.168.1.64", thunderboltIP: "169.254.89.80", networkIP: "192.168.1.64")
        XCTAssertEqual(receiver.ip(for: .thunderboltBridge), "169.254.89.80")
    }

    func testThunderboltTransportFallsBackToPreferredIP() {
        let receiver = makeReceiver(preferredIP: "192.168.1.64", thunderboltIP: "", networkIP: "192.168.1.64")
        XCTAssertEqual(receiver.ip(for: .thunderboltBridge), "192.168.1.64")
    }

    func testNetworkTransportPrefersNetworkIP() {
        let receiver = makeReceiver(preferredIP: "169.254.89.80", thunderboltIP: "169.254.89.80", networkIP: "192.168.1.64")
        XCTAssertEqual(receiver.ip(for: .networkLink), "192.168.1.64")
    }

    func testNetworkTransportFallsBackToPreferredIP() {
        let receiver = makeReceiver(preferredIP: "169.254.89.80", thunderboltIP: "169.254.89.80", networkIP: "")
        XCTAssertEqual(receiver.ip(for: .networkLink), "169.254.89.80")
    }

    // MARK: - Identity

    func testIDCombinesServiceNameAndPreferredIP() {
        let receiver = makeReceiver(serviceName: "TargetBridge Jonathans-iMac", preferredIP: "192.168.1.64")
        XCTAssertEqual(receiver.id, "TargetBridge Jonathans-iMac|192.168.1.64")
    }

    // MARK: - shortHostName

    func testShortHostNameStripsTrailingDotAndDomain() {
        let receiver = makeReceiver(hostName: "Jonathans-iMac.local.")
        XCTAssertEqual(receiver.shortHostName, "Jonathans-iMac")
    }

    func testShortHostNameNilWhenHostMissingOrEmpty() {
        XCTAssertNil(makeReceiver(hostName: nil).shortHostName)
        XCTAssertNil(makeReceiver(hostName: "").shortHostName)
    }

    // MARK: - displayText

    func testDisplayTextShowsBothTransportsWhenAvailable() {
        let receiver = makeReceiver(
            thunderboltIP: "169.254.89.80",
            networkIP: "192.168.1.64",
            hostName: "Jonathans-iMac.local."
        )
        XCTAssertEqual(receiver.displayText, "Jonathans-iMac (TB 169.254.89.80 · NET 192.168.1.64)")
    }

    func testDisplayTextSingleTransportOnly() {
        XCTAssertEqual(makeReceiver(thunderboltIP: "169.254.89.80").displayText, "169.254.89.80")
        XCTAssertEqual(makeReceiver(networkIP: "192.168.1.64").displayText, "192.168.1.64")
    }

    func testDisplayTextFallsBackToPreferredIPWithoutTransportIPs() {
        let receiver = makeReceiver(preferredIP: "192.168.1.64")
        XCTAssertEqual(receiver.displayText, "192.168.1.64")
    }

    func testDisplayTextAppendsPanelSummary() {
        let receiver = makeReceiver(networkIP: "192.168.1.64", panelSummary: "iMac 5K (5120x2880)")
        XCTAssertEqual(receiver.displayText, "192.168.1.64 · iMac 5K (5120x2880)")
    }
}

// MARK: - The name used where there is one line to spend

/// Cover for the menu bar row that truncated mid-address.
///
/// `displayText` lists every address a receiver advertises, which is what the
/// window's pickers need to tell two receivers apart and far more than a menu row
/// can render: "Atess-iMac (TB 10.0.1.2 · NET 192.1..." was the visible result.
extension TBReceiverDiscoveryModelTests {

    func testTheShortNamePrefersTheHostAndDropsEveryAddress() {
        let receiver = makeReceiver(
            thunderboltIP: "10.0.1.2",
            networkIP: "192.168.0.192",
            panelSummary: "iMac (2560x1440)",
            hostName: "Atess-iMac.local.")
        XCTAssertEqual(receiver.shortDisplayName, "Atess-iMac")
        XCTAssertTrue(receiver.displayText.contains("10.0.1.2"),
                      "displayText keeps the addresses the pickers rely on")
    }

    func testTheShortNameFallsBackToTheAdvertisedNameWithoutAHost() {
        let receiver = makeReceiver(receiverName: "Studio Display",
                                    thunderboltIP: "10.0.1.2",
                                    hostName: nil)
        XCTAssertEqual(receiver.shortDisplayName, "Studio Display")
    }

    func testTheShortNameFallsBackToTheAddressWhenNothingIsNamed() {
        let receiver = makeReceiver(receiverName: "",
                                    preferredIP: "10.0.1.2",
                                    hostName: nil)
        XCTAssertEqual(receiver.shortDisplayName, "10.0.1.2")
    }
}
