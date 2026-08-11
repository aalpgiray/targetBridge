import XCTest
@testable import TargetBridge

/// Locks down the capture-preset invariants that carry the 5K lossless link.
///
/// WHY THESE, AND NOT OTHERS
///
/// Every assertion here is a regression that actually happened, most of them on
/// the same day. They share a shape: a one-line property, buried in a 5000-line
/// file, whose wrong value costs performance rather than correctness — so nothing
/// crashes, no test fails, and the link merely feels worse. That is the least
/// detectable kind of defect this project has, and the only defence is to state
/// the value out loud somewhere a build will check.
///
/// A merge that reverts any of these now fails here instead of surfacing weeks
/// later as "it feels slow again".
final class TBCapturePresetTests: XCTestCase {

    // MARK: - the settings that produced 60 fps

    /// queueDepth was 2 against Apple's default of 8. At 5K the capture callback
    /// runs 10-14 ms against a 16.7 ms period, so a shallow queue leaves
    /// ScreenCaptureKit nowhere to put the next frame — and a stalled stream
    /// delivers NOTHING rather than an idle frame, so the loss reads as "macOS
    /// did not draw it". It was misattributed that way for a long time.
    ///
    /// An upstream merge later set this to 5 for its own presets, which would
    /// have quietly undone it for ours.
    func testFiveKPresetsKeepAppleDefaultQueueDepth() {
        for preset in [TBDisplayCapturePreset.native5k,
                       .native5kRaw60,
                       .native5k60Experimental] {
            XCTAssertEqual(preset.queueDepth, 8,
                           "\(preset.rawValue): 5K needs the full queue; a shallower one starves SCK")
        }
    }

    /// The lossless preset must want at least 60, because that is what selects
    /// `minimumFrameInterval = .zero`. That property is a THROTTLE, not a target:
    /// asking for CMTime(1, 60) makes SCK police a 16.67 ms gate with a timer of
    /// its own that is not phase-locked to the compositor, and frames landing a
    /// hair inside it are held. It showed up as 2-period gaps in the capture
    /// cadence.
    func testLosslessPresetRunsAtNativeRefresh() {
        XCTAssertGreaterThanOrEqual(TBDisplayCapturePreset.native5kRaw60.expectedFrameRate, 60,
                                    "below 60 the capture throttle re-engages")
    }

    // MARK: - the lossless path cannot half-apply

    /// The whole point of the consolidation: the pixel format follows this one
    /// property. It used to be a conjunction of it plus two user toggles, with a
    /// silent fall-through to 4:2:0 — three ways to end up subsampled while
    /// believing lossless had been asked for.
    func testOnlyTheLosslessPresetIsRawPassthrough() {
        XCTAssertTrue(TBDisplayCapturePreset.native5kRaw60.isRawPassthrough)
        for preset in TBDisplayCapturePreset.allCases where preset != .native5kRaw60 {
            XCTAssertFalse(preset.isRawPassthrough,
                           "\(preset.rawValue) would take the raw path and bypass the encoder")
        }
    }

    /// The panel read "(5K, HEVC)" for a session sending bit-exact 10-bit 4:4:4,
    /// because the codec name was derived from codecType — and a raw-passthrough
    /// preset never reaches the hardware encoder at all.
    func testLosslessPresetDoesNotClaimAHardwareCodec() {
        let name = TBDisplayCapturePreset.native5kRaw60.codecName
        XCTAssertEqual(name, "Lossless")
        XCTAssertFalse(name.localizedCaseInsensitiveContains("hevc"))
        XCTAssertFalse(name.localizedCaseInsensitiveContains("h.264"))
    }

    /// Resolution, rate and depth all belong in the picker, because that is where
    /// somebody decides whether this preset is better than the others. "5K RAW"
    /// said none of it, and implied uncompressed, which stopped being true when
    /// the lossless codec landed.
    func testLosslessPresetIsSelfDescribing() {
        let d = TBDisplayCapturePreset.native5kRaw60.description
        XCTAssertTrue(d.contains("5120"), "resolution missing from \(d)")
        XCTAssertTrue(d.contains("60"), "refresh rate missing from \(d)")
        XCTAssertTrue(d.contains("10-bit"), "depth missing from \(d)")
    }

    // MARK: - the damage feature is gone, not dormant

    /// Damage rectangles were built, measured, and never once engaged: 0 rect
    /// against 49440 whole frames, because WindowServer damage is spatially
    /// scattered, so a single rect covering it is nearly the whole screen.
    ///
    /// Asserting the ABSENCE of the wire types is what stops it coming back by
    /// accident in a merge — the sender would start emitting packets no receiver
    /// handles any more.
    func testDamageWireTypesAreRetired() {
        // Asserting the raw values no longer MAP is stronger than checking a
        // case list: it fails if anyone reintroduces either number, whatever
        // they call it.
        XCTAssertNil(TBMonitorPacketType(rawValue: 0x24), "0x24 rawDamage is retired")
        XCTAssertNil(TBMonitorPacketType(rawValue: 0x27), "0x27 rawDPCMRect is retired")
    }

    /// The lossless wire types the link actually depends on. Their numbers are a
    /// contract with a separately built receiver, so a renumbering has to be a
    /// deliberate act rather than a side effect.
    func testLosslessWireTypesKeepTheirNumbers() {
        XCTAssertEqual(TBMonitorPacketType.rawDPCM.rawValue, 0x25)
        XCTAssertEqual(TBMonitorPacketType.rawDPCMSlice.rawValue, 0x26)
        XCTAssertEqual(TBMonitorPacketType.rawFrame.rawValue, 0x22)
    }
}
