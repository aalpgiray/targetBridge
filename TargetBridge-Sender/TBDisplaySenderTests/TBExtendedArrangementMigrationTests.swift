import XCTest
@testable import TargetBridge

final class TBExtendedArrangementMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let prefix = "com.targetbridge.sender.extended-arrangement"
    private let identity = "receiver:A4E28721-22A7-42A9-89D7-70F3DBB0E906"
    private let legacy = "service:TargetBridge Test-iMac"

    override func setUp() {
        suite = "TargetBridge.arrangement.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func key(_ identity: String, width: Int = 5120) -> String {
        TBExtendedArrangementMigration.key(prefix: prefix, identity: identity, width: width, height: 2880)
    }

    private func load() -> [String: Any]? {
        TBExtendedArrangementMigration.load(
            defaults: defaults, prefix: prefix, identity: identity,
            legacyIdentities: [legacy], width: 5120, height: 2880
        )
    }

    func testLegacyRelativeArrangementIsCopiedAndRetained() {
        defaults.set(["dx": -2560, "dy": 20], forKey: key(legacy))
        XCTAssertEqual(load()?["dx"] as? Int, -2560)
        XCTAssertEqual(defaults.dictionary(forKey: key(identity))?["dy"] as? Int, 20)
        XCTAssertNotNil(defaults.dictionary(forKey: key(legacy)))
    }

    func testExistingUUIDArrangementWins() {
        defaults.set(["dx": -2560, "dy": 20], forKey: key(legacy))
        defaults.set(["dx": 2560, "dy": 0], forKey: key(identity))
        XCTAssertEqual(load()?["dx"] as? Int, 2560)
    }

    func testLegacyAbsoluteArrangementIsPreserved() {
        defaults.set(["x": -1920, "y": 0], forKey: key(legacy))
        XCTAssertEqual(load()?["x"] as? Int, -1920)
    }

    func testWrongPanelSizeAndMalformedArrangementAreIgnored() {
        defaults.set(["dx": 1920, "dy": 0], forKey: key(legacy, width: 1920))
        XCTAssertNil(load())
        defaults.set(["dx": "invalid", "dy": 0], forKey: key(legacy))
        XCTAssertNil(load())
        XCTAssertNil(defaults.dictionary(forKey: key(identity)))
    }

    func testLegacyKeyEncodingRemainsCompatible() {
        XCTAssertEqual(key(legacy), "\(prefix).service-TargetBridge-Test-iMac.5120x2880")
    }
}
