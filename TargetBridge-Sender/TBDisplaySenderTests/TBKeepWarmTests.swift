import XCTest
import AppKit
@testable import TargetBridge

/// Guards the one property that made keep-warm crash the app.
///
/// WHY A TEST FOR A SINGLE BOOL
///
/// `isReleasedWhenClosed` defaults to true on a window built with
/// init(contentRect:…). That is a manual-retain-counting convention ARC knows
/// nothing about, so `close()` releases the window and the strong property
/// releases it again. The object dies twice.
///
/// What makes it worth a test rather than a comment is how the failure presents:
/// not a crash in the code that did it, but a segfault later in objc_release
/// under -[NSAutoreleasePool drain], with a stack containing nothing of ours.
/// It surfaced as two apparently unrelated bugs — "crashes when I unplug the
/// cable" and "crashes when I unlock the Mac" — which are simply the two paths
/// that reach stop(). It was misdiagnosed repeatedly and cost most of a day.
///
/// Deleting one line would bring all of that back with no compiler complaint and
/// no test failure anywhere else, because nothing else looks at window lifetime.
@MainActor
final class TBKeepWarmTests: XCTestCase {

    /// The default is the dangerous value, so this documents what we are guarding
    /// against as much as it verifies AppKit. If a future macOS changes the
    /// default, this test failing is useful news rather than a nuisance.
    func testAppKitDefaultIsStillTheDangerousOne() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                         styleMask: .borderless,
                         backing: .buffered,
                         defer: false)
        XCTAssertTrue(w.isReleasedWhenClosed,
                      "if this is now false by default, the guard in TBKeepWarm is merely redundant, not wrong")
        w.isReleasedWhenClosed = false
    }

    /// A full start/stop cycle must leave nothing behind and must not over-release.
    /// Under ARC a double release usually survives the immediate call and only
    /// bites when a pool drains, so this drains one explicitly.
    func testStartThenStopSurvivesAnAutoreleasePoolDrain() {
        let keepWarm = TBKeepWarm()
        // The main display stands in for the virtual one: the class only needs a
        // display with real bounds, and CI has no CGVirtualDisplay.
        autoreleasepool {
            keepWarm.start(displayID: CGMainDisplayID())
            keepWarm.stop()
        }
        // Reaching here without a segfault is the assertion. Stopping twice is
        // also legal — teardown paths overlap, and the second call must be inert
        // rather than closing an already-closed window.
        keepWarm.stop()
    }

    /// start() is guarded by `window == nil`, so a second call must not build a
    /// second window and orphan the first — that would leak a display link and
    /// double the compositing cost with no way to stop the extra one.
    func testStartIsIdempotent() {
        let keepWarm = TBKeepWarm()
        keepWarm.start(displayID: CGMainDisplayID())
        keepWarm.start(displayID: CGMainDisplayID())
        keepWarm.stop()
        keepWarm.stop()
    }

    /// A display with no bounds means the display is gone. Starting against one
    /// must be refused rather than producing a window pinned to nothing — this is
    /// the state the cable pull leaves behind.
    func testRefusesToStartOnAMissingDisplay() {
        let keepWarm = TBKeepWarm()
        // An ID that cannot correspond to a live display; CGDisplayBounds returns
        // .zero, which is what the guard checks.
        keepWarm.start(displayID: CGDirectDisplayID(0xFFFF_FFFE))
        keepWarm.stop()
    }
}
