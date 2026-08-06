import Foundation

/// Formats and emits the capture telemetry, off the capture thread.
///
/// The formatting used to happen inline in the capture callback: four os_log
/// calls plus two histograms built with enumerated/filter/map/joined. That is a
/// lot of allocation for a thread with a 16.7 ms budget, and it ran once per 240
/// frames -- which is exactly how often `send(wall)` showed a single 2-period
/// gap. It was the last 1%, and the one cost `process` could never reveal,
/// because the report is emitted after the measurement it reports.
///
/// A diagnostic that perturbs what it measures is worse than no diagnostic.
enum TBTelemetryReporter {
    private static let queue = DispatchQueue(label: "com.targetbridge.telemetry",
                                             qos: .utility)

    /// Spacing of packets ACTUALLY leaving, binned here rather than at the
    /// caller.
    ///
    /// `send(wall)` used to be sampled where the frame was submitted to the
    /// encoder. Once the encode went async that stopped being when packets left
    /// -- emission happens later, from the completion callback -- and the metric
    /// read a clean 100% while the receiver was visibly bunching frames into
    /// pairs. A measurement taken at the wrong point is worse than none.
    ///
    /// It lives here because emission happens on the encoder's queue while the
    /// capture histogram is written on the capture thread; binning on this
    /// queue keeps both off each other's memory.
    /// `nonisolated(unsafe)` is accurate: both are read and written only inside
    /// `queue`, which is serial.
    nonisolated(unsafe) private static var emitBins = [Int](repeating: 0, count: 8)
    nonisolated(unsafe) private static var lastEmit = 0.0

    /// Call as the frame's LAST band goes to the socket. Cheap: a timestamp and
    /// an async hop, no formatting.
    static func noteEmit() {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        queue.async {
            if lastEmit > 0 {
                let periods = Int(((now - lastEmit) / (1.0 / 60.0)).rounded())
                emitBins[max(0, min(7, periods))] += 1
            }
            lastEmit = now
        }
    }

    private static func fmt(_ bins: [Int]) -> String {
        let total = max(1, bins.reduce(0, +))
        return bins.enumerated()
            .filter { $0.element > 0 }
            .map { "\($0.offset):\($0.element) (\(Int(100.0 * Double($0.element) / Double(total)))%)" }
            .joined(separator: "  ")
    }

    static func report(capBins: [Int], sendBins: [Int], drops: Int, idle: Int,
                       probe: Double, lock: Double, ctx: Double, submit: Double,
                       hadProcess: Bool,
                       deliverySum: Double, deliveryMax: Double,
                       processSum: Double, processMax: Double, samples: Int,
                       inflight: Int, budget: Int) {
        queue.async {
            TBLog.connection.info("cadence capture(pts) \(fmt(capBins), privacy: .public)  idle \(idle, privacy: .public)")
            TBLog.connection.info("cadence emit(wall)   \(fmt(emitBins), privacy: .public)  drops \(drops, privacy: .public)")
            emitBins = [Int](repeating: 0, count: 8)
            if hadProcess {
                TBLog.connection.info("stage worst ms: probe \(String(format: "%.1f", probe), privacy: .public) | lock \(String(format: "%.1f", lock), privacy: .public) | ctx \(String(format: "%.1f", ctx), privacy: .public) | submit \(String(format: "%.1f", submit), privacy: .public)")
            }
            if samples > 0 {
                let n = Double(samples)
                TBLog.connection.info("latency delivery \(String(format: "%.1f", deliverySum / n), privacy: .public) ms avg / \(String(format: "%.1f", deliveryMax), privacy: .public) max | process \(String(format: "%.1f", processSum / n), privacy: .public) ms avg / \(String(format: "%.1f", processMax), privacy: .public) max | inflight \(inflight, privacy: .public)/\(budget, privacy: .public)")
            }
        }
    }
}
