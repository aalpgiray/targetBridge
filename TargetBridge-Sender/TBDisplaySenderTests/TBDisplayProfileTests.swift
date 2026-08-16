import XCTest
@testable import TargetBridge

final class TBDisplayProfileTests: XCTestCase {
    func testWork5KUsesAnExtendedNative5KDisplay() {
        let settings = TBDisplayProfile.work5K.settings

        XCTAssertEqual(settings.captureSource, .extendedDesktop)
        XCTAssertEqual(settings.capturePreset, .native5k)
        XCTAssertTrue(settings.matchRenderToStream)
        XCTAssertFalse(settings.audioEnabled)
    }

    func testLowLatencyPrioritizesSmoothVideoWithoutAudio() {
        let settings = TBDisplayProfile.lowLatency.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .smooth1440p60)
        XCTAssertFalse(settings.matchRenderToStream)
        XCTAssertFalse(settings.audioEnabled)
    }

    func testPresentationUsesACompatibleMirrorProfileWithAudio() {
        let settings = TBDisplayProfile.presentation.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .standard1440p)
        XCTAssertTrue(settings.audioEnabled)
    }
}

// MARK: - Re-applying a stored profile

/// Regression cover for the settings that "forgot themselves" on every stop.
///
/// A profile was re-applied on each discovery refresh, including the one right
/// after a stream ended. The stored `work5K` carries HEVC and matchRenderToStream
/// true, so a session deliberately running lossless with matching off was flipped
/// back both ways every single time -- and macOS, seeing the mode change, lost the
/// display arrangement with it.
extension TBDisplayProfileTests {

    func testAProfileMayBeReappliedWhileTheSettingsStillMatchIt() {
        let settings = TBDisplayProfile.work5K.settings
        XCTAssertTrue(settings.matchesStreamSettings(
            captureSource: settings.captureSource,
            capturePreset: settings.capturePreset,
            matchRenderToStream: settings.matchRenderToStream))
    }

    func testChangingTheCodecByHandStopsTheProfileBeingReapplied() {
        // The exact reported case: work5K stores HEVC (.native5k); the user is
        // running the lossless preset. Re-applying would undo that.
        let settings = TBDisplayProfile.work5K.settings
        XCTAssertNotEqual(settings.capturePreset, .native5kRaw60,
                          "work5K is expected to store an HEVC preset; update this test if it changes")
        XCTAssertFalse(settings.matchesStreamSettings(
            captureSource: settings.captureSource,
            capturePreset: .native5kRaw60,
            matchRenderToStream: settings.matchRenderToStream))
    }

    func testTurningRenderMatchingOffStopsTheProfileBeingReapplied() {
        let settings = TBDisplayProfile.work5K.settings
        XCTAssertTrue(settings.matchRenderToStream,
                      "work5K is expected to enable render matching; update this test if it changes")
        XCTAssertFalse(settings.matchesStreamSettings(
            captureSource: settings.captureSource,
            capturePreset: settings.capturePreset,
            matchRenderToStream: false))
    }

    func testChangingTheCaptureSourceStopsTheProfileBeingReapplied() {
        let settings = TBDisplayProfile.presentation.settings
        XCTAssertFalse(settings.matchesStreamSettings(
            captureSource: .extendedDesktop,
            capturePreset: settings.capturePreset,
            matchRenderToStream: settings.matchRenderToStream))
    }
}
