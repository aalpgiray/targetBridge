import Foundation

/// Where the sender's CPU actually goes on the capture path.
///
/// The sender burns ~64% of a core while its stage timings total ~2ms a frame and
/// the packet copy measures 2-5%. Roughly 56% was unaccounted for, and two
/// hypotheses about it were already measured and killed: the packet copy (assumed
/// two thirds, measured a ninth or less) and wasted captures (60Hz took `skipped`
/// from 110 to 0 and CPU went UP).
///
/// So this splits the capture callback in two. `rejected` is the cost of frames
/// the throttle discards -- ScreenCaptureKit has already built the IOSurface and
/// the CMSampleBuffer by then, so it is not free. `kept` is everything downstream:
/// texture wrap, GPU submit, packet build, send.
///
/// Reported once a second next to the other stage timings, in the same file sink,
/// because os_log .info records are evicted within minutes and every number this
/// project has trusted came from the file.
enum TBCaptureCostStats {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var keptNanos: UInt64 = 0
    nonisolated(unsafe) private static var keptCount = 0
    nonisolated(unsafe) private static var rejNanos: UInt64 = 0
    nonisolated(unsafe) private static var rejCount = 0
    nonisolated(unsafe) private static var passNanos: UInt64 = 0
    nonisolated(unsafe) private static var passCount = 0
    nonisolated(unsafe) private static var lastReport: UInt64 = 0

    static func noteKept(nanos: UInt64) {
        lock.lock(); keptNanos += nanos; keptCount += 1; report(); lock.unlock()
    }

    /// The synchronous cost of a frame that survived decimation: everything from
    /// the gate to the end of the capture handler.
    static func notePassed(nanos: UInt64) {
        lock.lock(); passNanos += nanos; passCount += 1; report(); lock.unlock()
    }

    static func noteRejected(nanos: UInt64) {
        lock.lock(); rejNanos += nanos; rejCount += 1; report(); lock.unlock()
    }

    /// Caller holds the lock.
    private static func report() {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastReport == 0 { lastReport = now; return }
        let elapsed = now - lastReport
        guard elapsed >= 1_000_000_000 else { return }
        let keptMs = Double(keptNanos) / 1_000_000.0
        let rejMs  = Double(rejNanos) / 1_000_000.0
        let keptPct = Double(keptNanos) / Double(elapsed) * 100.0
        let rejPct  = Double(rejNanos) / Double(elapsed) * 100.0
        let k = keptCount, r = rejCount
        let passMs = Double(passNanos) / 1_000_000.0
        let passPct = Double(passNanos) / Double(elapsed) * 100.0
        let p = passCount
        keptNanos = 0; keptCount = 0; rejNanos = 0; rejCount = 0
        passNanos = 0; passCount = 0; lastReport = now
        let line = String(
            format: "capture cost: kept %.1f ms/s (%.1f%%) n=%d | rejected %.1f ms/s (%.1f%%) n=%d",
            keptMs, keptPct, k, rejMs, rejPct, r)
        let line2 = String(format: "  passed-frame path: %.1f ms/s (%.1f%% of one core) n=%d",
                           passMs, passPct, p)
        TBLog.connection.info("\(line2, privacy: .public)")
        TBReceiverLogSink.shared.note(line2)
        TBLog.connection.info("\(line, privacy: .public)")
        TBReceiverLogSink.shared.note(line)
    }
}
