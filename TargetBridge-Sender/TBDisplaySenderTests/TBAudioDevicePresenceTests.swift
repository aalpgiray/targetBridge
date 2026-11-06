import Foundation
import XCTest
@testable import TargetBridge

/// The sender answers the driver's UDP probe on 127.0.0.1:51710 only while a
/// receiver is streaming, plus a short grace. These tests are the grace rules.
/// They do not open a socket and they do not need the HAL plugin installed.
final class TBAudioDevicePresenceTests: XCTestCase {

    func testGraceOutlastsThreeProbeIntervals() {
        // The driver probes once a second and withdraws on the third refusal.
        // The sink has to stay up longer than that, or a single slow handshake
        // during a reconnect removes the device and puts it back.
        XCTAssertGreaterThanOrEqual(TBAudioDevicePresence.withdrawGrace, 3)
        XCTAssertEqual(TBAudioDevicePresence.withdrawGrace, 8)
    }

    func testDeviceStaysUnpublishedUntilAReceiverIsStreaming() {
        let state = TBAudioDevicePresence.State()
        XCTAssertEqual(
            TBAudioDevicePresence.step(addonEnabled: true, anyStreaming: false, state: state),
            .idle
        )
        XCTAssertEqual(
            TBAudioDevicePresence.step(addonEnabled: false, anyStreaming: false, state: state),
            .idle
        )
        XCTAssertEqual(
            TBAudioDevicePresence.step(addonEnabled: true, anyStreaming: true, state: state),
            .bind
        )
    }

    func testShortReconnectKeepsTheSinkBound() {
        var state = TBAudioDevicePresence.State()
        var closed = false

        func apply(_ step: TBAudioDevicePresence.Step) {
            switch step {
            case .bind:
                state.withdrawArmed = false
                state.sinkBound = true
            case .hold:
                state.withdrawArmed = false
                XCTAssertTrue(state.sinkBound)
            case .armWithdraw:
                XCTAssertFalse(state.withdrawArmed)
                state.withdrawArmed = true
                XCTAssertTrue(state.sinkBound)
            case .keepWithdraw:
                XCTAssertTrue(state.withdrawArmed)
                XCTAssertTrue(state.sinkBound)
            case .close:
                closed = true
                state.sinkBound = false
                state.withdrawArmed = false
            case .idle:
                XCTAssertFalse(state.sinkBound)
            }
        }

        apply(TBAudioDevicePresence.step(addonEnabled: true, anyStreaming: true, state: state))
        apply(TBAudioDevicePresence.step(addonEnabled: true, anyStreaming: false, state: state))
        // A second idle report, from another session stopping, must not move the deadline.
        apply(TBAudioDevicePresence.step(addonEnabled: true, anyStreaming: false, state: state))
        apply(TBAudioDevicePresence.step(addonEnabled: true, anyStreaming: true, state: state))

        XCTAssertTrue(state.sinkBound)
        XCTAssertFalse(state.withdrawArmed)
        XCTAssertFalse(closed)

        // The grace timer losing the race with the reconnect must not close.
        XCTAssertEqual(
            TBAudioDevicePresence.stepAfterGrace(addonEnabled: true, anyStreaming: true, state: state),
            .hold
        )
    }

    func testGraceCloseOnlyHappensWhenStillIdle() {
        var state = TBAudioDevicePresence.State(sinkBound: true, withdrawArmed: true)
        XCTAssertEqual(
            TBAudioDevicePresence.stepAfterGrace(addonEnabled: true, anyStreaming: false, state: state),
            .close
        )
        state.sinkBound = false
        XCTAssertEqual(
            TBAudioDevicePresence.stepAfterGrace(addonEnabled: true, anyStreaming: false, state: state),
            .idle
        )
    }

    func testOneLiveSessionKeepsTheDeviceUp() {
        let state = TBAudioDevicePresence.State(sinkBound: true, withdrawArmed: false)
        XCTAssertEqual(
            TBAudioDevicePresence.step(addonEnabled: true, anyStreaming: true, state: state),
            .hold
        )
    }

    func testDisablingTheAddonClosesImmediately() {
        let streaming = TBAudioDevicePresence.State(sinkBound: true, withdrawArmed: false)
        XCTAssertEqual(
            TBAudioDevicePresence.step(addonEnabled: false, anyStreaming: true, state: streaming),
            .close
        )
        let inGrace = TBAudioDevicePresence.State(sinkBound: true, withdrawArmed: true)
        XCTAssertEqual(
            TBAudioDevicePresence.step(addonEnabled: false, anyStreaming: false, state: inGrace),
            .close
        )
    }

    func testFloatFramesNarrowToInt16WithoutWrapping() {
        func sample(_ value: Float32) -> Int16 {
            var raw = value
            let data = Data(bytes: &raw, count: MemoryLayout<Float32>.size)
            let narrowed = TBAudioWireFormat.int16Data(fromFloat32: data)
            var out: Int16 = 0
            _ = withUnsafeMutableBytes(of: &out) { narrowed.copyBytes(to: $0) }
            return out
        }

        XCTAssertEqual(sample(0), 0)
        XCTAssertEqual(sample(1), 32767)
        XCTAssertEqual(sample(-1), -32767)
        XCTAssertEqual(sample(2), 32767)
        XCTAssertEqual(sample(-2), -32767)
        XCTAssertEqual(TBAudioWireFormat.Port.output, 51710)
        XCTAssertEqual(TBAudioWireFormat.loopbackAddress, "127.0.0.1")
    }
}
