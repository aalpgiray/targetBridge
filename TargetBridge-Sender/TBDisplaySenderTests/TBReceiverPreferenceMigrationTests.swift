import XCTest
@testable import TargetBridge

final class TBReceiverPreferenceMigrationTests: XCTestCase {
    private let uuid = "A4E28721-22A7-42A9-89D7-70F3DBB0E906"
    private var receiver: TBDiscoveredReceiver {
        TBDiscoveredReceiver(
            serviceName: "TargetBridge Test-iMac", receiverName: "Test-iMac",
            receiverID: uuid, preferredIP: "169.254.2.3", thunderboltIP: "169.254.2.3",
            networkIP: "", panelSummary: "", version: "3.6.0",
            supportsHEVCDecode: true, hostName: nil
        )
    }

    func testLegacyProfileSurvivesChangedReceiverIP() {
        var values = ["id:TargetBridge Test-iMac|169.254.1.2": "work5k"]
        TBReceiverPreferenceMigration.migrateProfiles(
            &values, identity: receiver.stableIdentity,
            matchesIdentity: receiver.matchesPersistedIdentity
        )
        XCTAssertEqual(values["id:\(receiver.stableIdentity)"], "work5k")
        XCTAssertEqual(values["id:TargetBridge Test-iMac|169.254.1.2"], "work5k")
    }

    func testCurrentProfileWinsAndUnrelatedProfileIsNotMigrated() {
        let current = "id:\(receiver.stableIdentity)"
        var values = [current: "presentation", "id:TargetBridge Test-iMac|old": "work5k"]
        TBReceiverPreferenceMigration.migrateProfiles(
            &values, identity: receiver.stableIdentity,
            matchesIdentity: receiver.matchesPersistedIdentity
        )
        XCTAssertEqual(values[current], "presentation")
        values = ["id:TargetBridge Other-iMac|169.254.2.3": "work5k"]
        TBReceiverPreferenceMigration.migrateProfiles(
            &values, identity: receiver.stableIdentity,
            matchesIdentity: receiver.matchesPersistedIdentity
        )
        XCTAssertNil(values[current])
    }

    func testCodecSaveAndRestoreUseSameUUIDKey() {
        let savedKey = TBReceiverPreferenceMigration.codecKey(
            identity: receiver.stableIdentity, receiverIP: receiver.preferredIP
        )
        XCTAssertEqual(savedKey, receiver.stableIdentity)
        XCTAssertEqual(TBReceiverPreferenceMigration.codecKey(identity: uuid, receiverIP: ""), savedKey)
    }

    func testLegacyServiceAndManualIPCodecKeys() {
        XCTAssertEqual(TBReceiverPreferenceMigration.codecKey(
            identity: "TargetBridge Test-iMac|169.254.1.2", receiverIP: ""
        ), "service:TargetBridge Test-iMac")
        XCTAssertEqual(TBReceiverPreferenceMigration.codecKey(
            identity: "service:TargetBridge Test-iMac", receiverIP: ""
        ), "service:TargetBridge Test-iMac")
        XCTAssertEqual(TBReceiverPreferenceMigration.codecKey(identity: "", receiverIP: "192.168.1.2"), "ip:192.168.1.2")
        XCTAssertNil(TBReceiverPreferenceMigration.codecKey(identity: "", receiverIP: ""))
    }

    func testDoubledPrefixCodecWinsOverOlderServicePreference() {
        var values = ["service:\(receiver.stableIdentity)": "h264", "service:\(receiver.serviceName)": "hevc"]
        TBReceiverPreferenceMigration.migrateCodecs(
            &values, identity: receiver.stableIdentity, serviceName: receiver.serviceName,
            matchesIdentity: receiver.matchesPersistedIdentity
        )
        XCTAssertEqual(values[receiver.stableIdentity], "h264")
    }

    func testCurrentCodecPreferenceIsNeverOverwritten() {
        var values = [receiver.stableIdentity: "automatic", "service:\(receiver.serviceName)": "h264"]
        TBReceiverPreferenceMigration.migrateCodecs(
            &values, identity: receiver.stableIdentity, serviceName: receiver.serviceName,
            matchesIdentity: receiver.matchesPersistedIdentity
        )
        XCTAssertEqual(values[receiver.stableIdentity], "automatic")
    }

    func testOldServiceCodecPreferenceMigrates() {
        var values = ["service:\(receiver.serviceName)": "hevc"]
        TBReceiverPreferenceMigration.migrateCodecs(
            &values, identity: receiver.stableIdentity, serviceName: receiver.serviceName,
            matchesIdentity: receiver.matchesPersistedIdentity
        )
        XCTAssertEqual(values[receiver.stableIdentity], "hevc")
    }
}
