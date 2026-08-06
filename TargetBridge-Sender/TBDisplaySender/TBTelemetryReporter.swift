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
            TBLog.connection.info("cadence send(wall)   \(fmt(sendBins), privacy: .public)  drops \(drops, privacy: .public)")
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
