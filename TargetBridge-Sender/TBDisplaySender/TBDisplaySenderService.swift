import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import AVFoundation
import IOSurface
import Network
import os
@preconcurrency import ScreenCaptureKit
import VideoToolbox

/// Idle capture frames seen since the last cadence report.
///
/// ScreenCaptureKit ticks even when nothing was composited, marking the frame
/// `.idle` with pixels identical to the last. Reported alongside the capture
/// cadence so a gap in that histogram can be attributed: frames we filtered, or
/// refreshes where the compositor produced nothing at all. The two want
/// different fixes and are indistinguishable from the histogram alone.
///
/// Single writer (the capture callback queue) and a single reader on the same
/// queue, so a plain var is honest here rather than lucky.
nonisolated(unsafe) var tbIdleFramesSeen = 0

/// The smallest "seconds since the last local input event" seen at the moment
/// an idle frame arrived, since the last cadence report.
///
/// This is the discriminator for the intermittent stall. A burst of idle frames
/// has two completely different causes that the idle count alone cannot tell
/// apart: nobody was touching the machine, or the virtual display stopped
/// producing while somebody was actively using it. Only the second is a bug,
/// and it is the one that gets reported as "everything bogged down".
///
/// Local HID rather than the forwarded input events: those only arrive when the
/// receiver holds input control, and in the setup where the stall shows up it
/// does not — the keyboard and trackpad being used are the sender's own, so
/// counting wire events would read zero all through a genuine wedge and look
/// like proof of the opposite.
///
/// Sampled only on idle frames, which is both what the question is about and
/// what keeps it off the hot path in normal operation.
nonisolated(unsafe) var tbIdleInputGapMin = Double.greatestFiniteMagnitude

/// `kCGAnyInputEventType`, which Swift does not surface as a constant.
private let tbAnyInputEvent = CGEventType(rawValue: ~0)!

/// How long the first NEW frame took to arrive after a quiet stretch.
///
/// This is the number behind "it feels sluggish when I start typing again".
/// Every aggregate we had said 60 fps and said it honestly: the link carries
/// what it is given, on time, and the frame rate while reading is low because
/// a still screen produces nothing. None of that can see the one moment that
/// actually feels bad — the wait between a keystroke and the pixels for it.
///
/// Measured as: on the first content frame ending a run of idle frames, how
/// long ago the machine last saw input.
///
/// The trap, and the reason this is more than a subtraction: plenty of things
/// end an idle run without anybody touching the machine. A blinking text caret
/// is the worst of them — it ticks about twice a second, forever, and the first
/// version of this counted every blink as a wake-up, then reported how long ago
/// the last keypress was. That is where the 1.4 s "worst cases" came from, and
/// it made the average a blend of two unrelated quantities that shifted with
/// whatever window happened to be focused.
///
/// So the input must have arrived DURING the quiet stretch to count. If the
/// last event predates the idle run, this frame was produced by something else
/// and the sample is discarded rather than averaged in. Requiring causation to
/// be at least possible is the whole difference between a number and a mood.
///
/// Split by how long the screen had been quiet first, because two different
/// events were being averaged together and only one of them is a complaint.
///
/// Typing a word leaves ~60 ms gaps between keystrokes; each one ends a tiny
/// idle run and resumes almost instantly. Reading for fifteen seconds and then
/// typing is the case that feels bad. Pooled, twenty of the former bury one of
/// the latter — a run measured 27 ms average with a 479 ms sample inside it.
/// The average was not wrong, it was answering a question nobody asked.
///
/// So: `long` is the resumption after a real pause and the only number worth
/// optimising; `short` is ordinary typing and was never a problem. A change
/// that moves the pooled average proves nothing, because that average also
/// moves with how much someone happened to type in a row.
///
/// Single writer on the capture queue, read there too.
nonisolated(unsafe) var tbWakeShortSum = 0.0
nonisolated(unsafe) var tbWakeShortCount = 0
nonisolated(unsafe) var tbWakeLongSum = 0.0
nonisolated(unsafe) var tbWakeLongMax = 0.0
nonisolated(unsafe) var tbWakeLongCount = 0
nonisolated(unsafe) var tbWakeRejected = 0
/// Where a quiet stretch stops being a gap between keystrokes and starts being
/// somebody reading.
private let tbWakeLongIdle = 1.0
/// When the current run of idle frames began, on the monotonic clock. Zero when
/// not currently idle.
nonisolated(unsafe) var tbWakeIdleSince = 0.0
private let tbWakeMaxPlausible = 1.5

private func tbMonotonicNow() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}


enum TBDisplayCapturePreset: String, CaseIterable, Identifiable {
    case standard1440p
    case smooth1440p60
    case smooth1800p60
    case crisp2160p60
    case native5k
    case native5kRaw60
    case native5k60Experimental

    var id: String { rawValue }

    /// Raw NV12 passthrough presets stream uncompressed frames (no encoder on the
    /// sender, no decoder on the receiver). Meant for a fat, direct Thunderbolt
    /// link to a receiver that can't decode HEVC at this resolution/rate.
    var isRawPassthrough: Bool {
        switch self {
        case .native5kRaw60:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .standard1440p:
            return "Standard"
        case .smooth1440p60:
            return "Smooth"
        case .smooth1800p60:
            return "Smooth+"
        case .crisp2160p60:
            return "Crisp"
        case .native5k:
            return "5K"
        case .native5kRaw60:
            return "5K Lossless"
        case .native5k60Experimental:
            return "5K 60 Experimental"
        }
    }

    var description: String {
        switch self {
        case .standard1440p:
            return "2560 × 1440"
        case .smooth1440p60:
            return "2560 × 1440 @ 60"
        case .smooth1800p60:
            return "3200 × 1800 @ 60"
        case .crisp2160p60:
            return "3840 × 2160 @ 60"
        case .native5k:
            return "5120 × 2880 @ 48"
        case .native5kRaw60:
            // The picker shows "title · description", so depth belongs here: it
            // makes the preset self-describing at the point of choice, which is
            // where someone decides whether this one is better than the others.
            // "Lossless" stays in the title so the pair never repeats a word.
            return "5120 × 2880 @ 60 · 10-bit"
        case .native5k60Experimental:
            return "5120 × 2880 @ 60"
        }
    }

    var width: Int {
        switch self {
        case .standard1440p, .smooth1440p60:
            return 2560
        case .smooth1800p60:
            return 3200
        case .crisp2160p60:
            return 3840
        case .native5k, .native5kRaw60, .native5k60Experimental:
            return 5120
        }
    }

    var height: Int {
        switch self {
        case .standard1440p, .smooth1440p60:
            return 1440
        case .smooth1800p60:
            return 1800
        case .crisp2160p60:
            return 2160
        case .native5k, .native5kRaw60, .native5k60Experimental:
            return 2880
        }
    }

    var averageBitRate: Int {
        switch self {
        case .standard1440p:
            return 36_000_000
        case .smooth1440p60:
            return 52_000_000
        case .smooth1800p60:
            return 78_000_000
        case .crisp2160p60:
            return 105_000_000
        case .native5k, .native5kRaw60:
            return 120_000_000
        case .native5k60Experimental:
            return 150_000_000
        }
    }

    var codecName: String {
        switch self {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return "H.264"
        case .crisp2160p60, .native5k, .native5k60Experimental:
            return "HEVC"
        case .native5kRaw60:
            // Not "HEVC" — this preset never touches the hardware encoder — and
            // not "RAW NV12" either, which was true only before the lossless
            // codec existed. The panel showed "(5K, HEVC)" for a session sending
            // bit-exact 10-bit 4:4:4.
            return "Lossless"
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return kCMVideoCodecType_H264
        case .crisp2160p60, .native5k, .native5kRaw60, .native5k60Experimental:
            return kCMVideoCodecType_HEVC
        }
    }

    /// Frames ScreenCaptureKit may hold for us before it stalls.
    ///
    /// This was 2, against Apple's default of 8. The header is explicit that
    /// more frames "may allow you to process frame data without stalling the
    /// display stream", and our capture callback runs 10-14 ms against a
    /// 16.7 ms period -- so with two buffers SCK regularly had nowhere to put
    /// the next frame.
    ///
    /// That matters more than it sounds: a stalled stream delivers NOTHING, not
    /// an idle frame. So a queue stall and a compositor that genuinely drew
    /// nothing look identical from the frame-status counters, and the 4-5% of
    /// refreshes missing from the capture cadence were attributed to the
    /// compositor on exactly that evidence. 8 is Apple's default and the
    /// documented maximum.
    var queueDepth: Int {
        if let envVal = ProcessInfo.processInfo.environment["QD"], let parsed = Int(envVal) {
            return parsed
        }
        return 8
    }

    var expectedFrameRate: Int {
        switch self {
        case .standard1440p:
            return 30
        case .smooth1440p60:
            return 60
        case .smooth1800p60:
            return 60
        case .crisp2160p60:
            return 60
        case .native5k:
            return 48
        case .native5kRaw60, .native5k60Experimental:
            return 60
        }
    }

    var maxKeyFrameInterval: Int {
        switch self {
        case .standard1440p:
            return 60
        case .smooth1440p60:
            return 60
        case .smooth1800p60:
            return 60
        case .crisp2160p60:
            return 60
        case .native5k:
            return 48
        case .native5kRaw60, .native5k60Experimental:
            return 60
        }
    }

    var maxKeyFrameIntervalDuration: Int {
        switch self {
        case .standard1440p:
            return 2
        case .smooth1440p60:
            return 1
        case .smooth1800p60, .crisp2160p60:
            return 1
        case .native5k, .native5kRaw60, .native5k60Experimental:
            return 1
        }
    }

    var prioritizeSpeed: Bool {
        switch self {
        case .standard1440p:
            return false
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .native5k, .native5kRaw60, .native5k60Experimental:
            return true
        }
    }

    var maxPendingVideoPackets: Int {
        if let envVal = ProcessInfo.processInfo.environment["MPVP"], let parsed = Int(envVal) {
            return parsed
        }
        return 3
    }

    var maxFrameDelayCount: Int {
        switch self {
        case .standard1440p:
            return 1
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .native5k, .native5kRaw60, .native5k60Experimental:
            return 0
        }
    }

    var dropsBeforeEncodeWhenBacklogged: Bool {
        switch self {
        case .standard1440p:
            return false
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .native5k, .native5kRaw60, .native5k60Experimental:
            return true
        }
    }

    var maxInFlightEncodeFrames: Int {
        if let envVal = ProcessInfo.processInfo.environment["MIFEF"], let parsed = Int(envVal) {
            return parsed
        }
        return 5
    }

    var captureResolution: SCCaptureResolutionType {
        switch self {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return .nominal
        case .crisp2160p60, .native5k, .native5kRaw60, .native5k60Experimental:
            return .best
        }
    }

    var virtualDisplayRefreshRate: Double {
        switch self {
        case .standard1440p:
            return 60
        case .smooth1440p60, .smooth1800p60:
            return 60
        case .crisp2160p60:
            return 60
        case .native5k:
            return 48
        case .native5kRaw60, .native5k60Experimental:
            return 60
        }
    }

    /// Virtual display mode that makes the render resolution equal the stream
    /// resolution. macOS HiDPI is strictly 2x, so a (w/2, h/2) mode backs onto a
    /// (w, h) framebuffer, which ScreenCaptureKit then captures 1:1.
    ///
    /// Costs screen real estate: the desktop reports "looks like w/2 x h/2" rather
    /// than the receiver's default 2560 x 1440.
    var renderMatchedDisplayMode: TBVirtualDisplayModeSize {
        TBVirtualDisplayModeSize(width: width / 2, height: height / 2)
    }

    /// Logical desktop size the user ends up with under render matching.
    var renderMatchedDesktopDescription: String {
        "\(width / 2) × \(height / 2)"
    }
}

enum TBDisplayCaptureSource: String, CaseIterable, Identifiable {
    case desktopMirror
    case extendedDesktop

    var id: String { rawValue }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch self {
        case .desktopMirror:
            return TBDisplaySenderL10n.text("sender.source.desktop_mirror", language)
        case .extendedDesktop:
            return TBDisplaySenderL10n.text("sender.source.extended_desktop", language)
        }
    }

    func virtualDisplayIdentity(receiverKey: String) -> TBVirtualDisplayIdentity {
        switch self {
        case .desktopMirror:
            return .desktopMirror
        case .extendedDesktop:
            return .extendedDesktop(receiverKey: receiverKey)
        }
    }
}

enum TBInputControlRole: String, CaseIterable, Identifiable {
    case off
    case senderMaster
    case receiverMaster

    var id: String { rawValue }
}

enum TBInputGestureMode: String, CaseIterable, Identifiable {
    case native
    case relayToSlave

    var id: String { rawValue }
}

private final class TBDirectDisplayStreamCapture {
    // Strong reference so the pipeline (and its delivery queue) outlives every
    // frame callback — a stray frame must never deref a freed pipeline.
    private let pipeline: TBVideoPipeline
    private let queue: DispatchQueue
    private var stream: CGDisplayStream?
    // CGDisplayStreamStop is asynchronous: frames already in flight keep arriving
    // until the stream delivers a final `.stopped` frame, and releasing the
    // CGDisplayStream before then crashes inside SkyLight's
    // `_CGYDisplayStreamFrameAvailable`. This self-reference keeps the capture
    // object (and the stream) alive from stop() until that `.stopped` frame.
    private var pendingStopRetain: TBDirectDisplayStreamCapture?

    init(pipeline: TBVideoPipeline, queue: DispatchQueue) {
        self.pipeline = pipeline
        self.queue = queue
    }

    func start(displayID: CGDirectDisplayID, preset: TBDisplayCapturePreset, showCursor: Bool) -> Bool {
        let properties: NSDictionary = [
            CGDisplayStream.showCursor: showCursor,
            CGDisplayStream.queueDepth: preset.queueDepth,
            CGDisplayStream.minimumFrameTime: 1.0 / Double(preset.expectedFrameRate)
        ]

        let displayStream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: preset.width,
            outputHeight: preset.height,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: properties,
            queue: queue
        ) { [weak self] status, displayTime, surface, _ in
            // Delivered on `queue` — the pipeline's own serial queue — so encode
            // runs here, off the main thread, with no extra hop.
            guard let self else { return }
            if status == .stopped {
                // The stream has fully drained; no further frames will arrive, so
                // it is now safe to release the stream and drop the self-retain.
                self.stream = nil
                self.pendingStopRetain = nil
                return
            }
            guard status == .frameComplete, let surface else { return }
            // After pipeline.stop(), encodeDisplaySurface() no-ops on its `running`
            // guard, so a late in-flight frame here is harmless.
            self.pipeline.encodeDisplaySurface(surface, displayTime: displayTime)
        }

        guard let displayStream, displayStream.start() == .success else {
            return false
        }

        stream = displayStream
        return true
    }

    func stop() {
        guard stream != nil else { return }
        // Stay alive until the `.stopped` frame arrives (see pendingStopRetain);
        // the stream is released in the handler, never here, so it is never freed
        // with frame events still queued on `queue`.
        pendingStopRetain = self
        stream?.stop()
    }

    deinit {
        stop()
    }
}

/// Owns the capture→encode→send video pipeline and runs it entirely on a
/// dedicated serial queue, off the main thread. SwiftUI layout (or any other
/// main-thread work) therefore cannot stall frame delivery. All mutable encode
/// state is confined to `queue`; the two values the main thread polls
/// (`sentFrames`, `lastCaptureFrameAt`) are guarded by a small lock instead of
/// a per-frame hop back to main.
private final class TBVideoPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "fd.tbmonitor.sender.pipeline", qos: .userInteractive)

    private let preset: TBDisplayCapturePreset
    private let codecType: CMVideoCodecType
    private let connection: NWConnection
    private let displayName: String
    private let displayID: CGDirectDisplayID
    private let usesRawNV12: Bool
    private let onFirstFrame: @Sendable () -> Void

    /// Damage streaming: send whole frames only when we must (first frame,
    /// format/size change, too much changed, or a periodic resync) and send
    /// just the changed rectangles otherwise.
    /// Send only changed rectangles instead of whole frames. Set from the
    /// session's user-facing toggle before start().
    /// Whether the receiver can decode tile-DPCM on its GPU, from its display
    /// profile. A receiver that says nothing is an older one and keeps getting
    /// uncompressed frames. Set before start().
    ///
    /// When this is on, damage is not used at all: a compressed full frame fits
    /// inside a 60 Hz period, and the receiver decodes into VRAM where there is
    /// no CPU-side image for a rectangle to patch.
    var dpcmEnabled = false
    /// Whether the receiver can place bands at a row offset. Slices are only
    /// worth sending to a receiver that can overlap them; one that cannot keeps
    /// getting whole frames.
    var dpcmSlicesEnabled = false

    /// Cap on frames actually sent, independent of how fast we capture.
    ///
    /// Pairs with running the VIRTUAL display faster than the receiver's panel.
    /// Sending 120 to a 60 Hz panel failed: the iMac decodes about 70 fps of 5K,
    /// so its queue pinned and 8-20% of frames arrived with missing bands.
    ///
    /// But the win was never in DISPLAYING more frames. At 120 the compositor
    /// samples the content every 8.3 ms instead of 16.7, so a mouse move is
    /// picked up about 4 ms sooner on average — and that is latency you feel
    /// rather than a number in a histogram. Capture at 120, send 60, and the
    /// receiver's load is exactly what it is today.
    ///
    ///   defaults write com.targetbridge.sender TBVirtualRefresh -float 120
    ///   defaults write com.targetbridge.sender TBMaxSendFPS -int 60
    ///
    /// 0 (the default) sends everything captured, which is today's behaviour.
    private let maxSendFPS = UserDefaults.standard.integer(forKey: "TBMaxSendFPS")
    /// When the next send slot opens. A SCHEDULE, not "time since last send" —
    /// see the throttle for why that difference matters once capture is
    /// oversampled.
    private var nextSendHostTime = 0.0
    /// Measured mean interval between captured frames, in seconds — the arrival
    /// rate the compositor is ACTUALLY producing, not the rate we asked for.
    ///
    /// The throttle's tolerance has to be smaller than this or one slot admits
    /// two consecutive arrivals, so it must follow the real capture rate.
    /// Deriving it from `TBVirtualRefresh` would be a guess: that default is a
    /// request, the display may land on a different mode, and the compositor is
    /// demand-driven so it can produce below its mode rate. Measuring costs one
    /// multiply-add per frame on a delta we were already computing.
    ///
    /// Seeded from the configured refresh purely so the first few frames have a
    /// sane bound; it converges on the truth within ~20 frames either way.
    private var captureIntervalEMA: Double = {
        let hz = UserDefaults.standard.double(forKey: "TBVirtualRefresh")
        return 1.0 / (hz > 1 ? hz : 60.0)
    }()
    /// Frames skipped by the cap. Kept apart from `cadenceDrops`, which means
    /// "the link could not keep up" — these are deliberate and healthy.
    private var oversampleSkips = 0

    // MARK: Phase lock
    //
    // The schedule above fixes how OFTEN we send. Nothing fixes WHERE inside the
    // receiver's refresh cycle those sends land, and that phase is set by whenever
    // the session happened to start. Land just after the receiver's deadline and
    // every present waits nearly a full refresh for the next vblank — measured as
    // `drawable 16.6ms` with `submit` at 98% and cursor latency at 27ms, while
    // still holding a full 60 fps. It is not a throughput problem, so no rate
    // counter shows it.
    //
    // It used to average out. Once the slot schedule cut send jitter from ±10ms to
    // ±1ms, the phase became stable too, so a bad one now persists for minutes.
    // Making the link steadier is what made this failure durable.
    //
    // The fix walks the schedule to a better phase. Two things make it cheap now
    // and did not before:
    //   - the receiver's `nextDrawable` wait is a ready-made error signal
    //   - at 240 Hz capture a fresh frame exists every 4.17ms, so moving the send
    //     instant costs at most that much staleness. At 60 Hz capture the same
    //     move would cost up to 16.7ms and hand back everything it won, which is
    //     why this idea was rejected earlier.
    //
    /// Off by default: this is a feedback loop over a one-second average, so it
    /// can hunt, and the flag makes an A/B against `drawable` cost nothing.
    ///   defaults write com.targetbridge.sender TBPhaseLock -bool true
    private let phaseLockEnabled = UserDefaults.standard.bool(forKey: "TBPhaseLock")
    /// Guards `pendingPhaseShift` alone: reports arrive on the connection queue and
    /// the schedule is owned by the capture queue.
    private let phaseShiftLock = NSLock()
    private var pendingPhaseShift = 0.0
    /// Checked before taking the lock so the per-frame cost on the capture thread
    /// is one Bool read rather than a lock acquisition 240 times a second. A torn
    /// read of a flag that is only ever set true or false cannot mislead by more
    /// than one frame, and the next report would set it again.
    private var phaseShiftPending = false
    /// Connection queue only — no lock needed.
    private var phaseCorrecting = false
    private var phaseStepsApplied = 0
    /// Enter correcting above this, leave below the other: hysteresis, or a mean
    /// hovering near one threshold would step on every report forever. The good
    /// phase measures 0.0–0.1ms and the bad one a full 16.6ms, so there is a wide
    /// gap to place these in and no need for them to be finely tuned.
    private static let phaseBadMs = 3.0
    private static let phaseGoodMs = 1.0
    /// Phase is circular, so stepping steadily in ONE direction sweeps every phase
    /// and is guaranteed to cross the good region — which is why no attempt is made
    /// to work out the sign of the error. Eight steps of an eighth of a period make
    /// one full sweep; three sweeps without success means the cause is not phase,
    /// so stop rather than churn the schedule forever. Reset on any good report.
    /// One full sweep is 8 steps of period/8. Three sweeps was chosen to be
    /// generous, but a sweep that finds the SAME wait at every phase has already
    /// proved the cause is not phase -- 12 steps of an unchanging 11.3ms was that,
    /// and it kept going. Give up after ten, and only count a step as progress if
    /// the wait actually moved.
    private static let phaseMaxSteps = 10

    /// One phase report from the receiver. Called on the connection queue; the
    /// resulting shift is handed to the capture queue through `pendingPhaseShift`
    /// so the schedule keeps a single writer.
    ///
    /// The controller lives here rather than beside the packet decoding because
    /// this is the type that owns the schedule — the decision and the thing it
    /// acts on stay together, and the session only has to decode bytes.
    func notePhaseReport(meanMs: Double, samples: UInt32) {
        // No schedule means nothing to shift: the phase is then whatever the
        // compositor produces and we have no handle on it. Still logged — the
        // number is the only view we get of where our sends land in the receiver's
        // refresh cycle, and it is what an A/B of this feature is judged on.
        // Only steer a session that is actually streaming.
        //
        // The loop kept stepping after the receiver went quiet -- shifting the send
        // schedule of a session with no peer, which cannot converge and cannot
        // help. Seen at 14:04:56: steps 11 and 12 applied a second AFTER the
        // receiver's last frame.
        // `running` is the pipeline's own liveness; it is cleared by stop().
        guard running else {
            phaseCorrecting = false
            phaseStepsApplied = 0
            return
        }
        guard phaseLockEnabled, maxSendFPS > 0 else {
            TBTelemetryReporter.emit(
                "phase drawable \(String(format: "%.2f", meanMs))ms n=\(samples) (lock off)")
            return
        }

        if phaseCorrecting {
            if meanMs < Self.phaseGoodMs {
                TBTelemetryReporter.emit(
                    "phase locked: drawable \(String(format: "%.2f", meanMs))ms"
                    + " after \(phaseStepsApplied) step(s)")
                phaseCorrecting = false
                phaseStepsApplied = 0
                return
            }
            if phaseStepsApplied >= Self.phaseMaxSteps {
                // Swept every phase three times over and the wait did not come
                // down, so the cause is not where we send. Stop stepping and say
                // so — silently continuing would leave a moving schedule looking
                // like a fixed one.
                TBTelemetryReporter.emit(
                    "phase giving up: drawable \(String(format: "%.2f", meanMs))ms"
                    + " unchanged after \(phaseStepsApplied) steps — not a phase problem")
                phaseCorrecting = false
                phaseStepsApplied = 0
                return
            }
        } else if meanMs > Self.phaseBadMs {
            phaseCorrecting = true
            phaseStepsApplied = 0
        } else {
            phaseStepsApplied = 0
            return
        }

        let step = (1.0 / Double(maxSendFPS)) / 8.0
        phaseShiftLock.lock()
        pendingPhaseShift += step
        phaseShiftPending = true
        phaseShiftLock.unlock()
        phaseStepsApplied += 1
        TBTelemetryReporter.emit(
            "phase stepping: drawable \(String(format: "%.2f", meanMs))ms n=\(samples)"
            + " -> shift \(String(format: "%.2f", step * 1000.0))ms"
            + " (step \(phaseStepsApplied)/\(Self.phaseMaxSteps))")
    }
    /// Bands per frame. 18 or 20 measured best on this hardware: encode grows
    /// ~0.26 ms per slice (two GPU round trips each), so past ~20 it overtakes the
    /// wire and becomes the slowest stage, and the makespan turns back up.
    /// Must divide the frame into whole 8-row tiles.
    /// `defaults write com.targetbridge.sender TBSliceCount -int 18` to try it,
    /// 1 to go back. A runtime knob rather than a constant because the gain is a
    /// model prediction until it is measured on the link, and because a bad value
    /// should be one command to undo rather than a reinstall.
    /// 4, measured 2026-08-06: zero incomplete frames over long runs, full rate,
    /// and ~9 ms of the ~11.8 ms the flow-shop model says slicing can recover —
    /// 79% of the win. 8 and 18 degrade on this receiver for reasons not yet
    /// diagnosed, so 4 is the value that is actually known to work rather than
    /// the one the model prefers. `defaults write com.targetbridge.sender
    /// TBSliceCount -int 1` returns to whole frames.
    /// Back to 1 on 2026-08-06. N=4 measures clean — zero incomplete frames over
    /// long runs — and is worth ~9 ms, but in real use it still shows visible
    /// glitches and the frame rate degrades until the sender is restarted, and
    /// neither is understood yet. `process` also goes from 9.2 ms to 15-17,
    /// leaving almost nothing spare in a 16.7 ms budget.
    ///
    /// A latency win that costs usability is not a win. N=4 comes back when the
    /// async encode has bought the headroom back and the degradation is
    /// diagnosed. `TBSliceCount -int 4` to try it.
    var dpcmSliceCount = max(1, (UserDefaults.standard.object(forKey: "TBSliceCount") as? Int) ?? 1)
    private var dpcmFrameID: UInt32 = 0
    /// Encoding runs on the GPU. The reference C encoder costs ~118 ms/frame at
    /// 5K single-threaded; this measures 5.7 ms, and more to the point it leaves
    /// the CPU to whoever is using the machine, which is the whole reason the
    /// second display is being driven at all.
    ///
    /// Created lazily because building it compiles shaders, and nil if this Mac
    /// cannot host it — in which case frames go out uncompressed rather than
    /// stalling the capture queue on a software encoder.
    /// Cadence diagnostic for judder on low-frame-rate content.
    ///
    /// The receiver showed 25 fps arriving at the right AVERAGE rate (2.39
    /// refresh periods per frame, against the 2.4 that 25 fps demands) but
    /// smeared across gaps of 1 to 5 periods instead of a clean alternating 2
    /// and 3. Its own loop was idle 80% of the time, so the irregularity is
    /// already present by the time frames reach it.
    ///
    /// These two histograms split what is left. `capture` bins the interval
    /// between sample buffers' own PRESENTATION TIMESTAMPS — when the compositor
    /// produced each frame, independent of any delay our queue adds, so it
    /// measures what we were handed. `send` bins wall-clock intervals between
    /// packets actually going out. Ragged capture means the compositor is doing
    /// this and it is not ours to fix; clean capture with ragged send means we
    /// are the cause.
    /// Latency accounting, to replace guesses with measurements.
    ///
    /// The end-to-end estimate had four assumed terms and only three measured
    /// ones, and the assumptions were the biggest. Two of them can be measured
    /// here with no cross-machine clock sync at all, because a sample buffer's
    /// presentation timestamp is on the host time clock:
    ///
    ///   delivery = now - PTS at callback entry, i.e. how long the compositor and
    ///              ScreenCaptureKit took to hand us a frame after it existed.
    ///              This was the single largest assumed term (~8 ms, a guess).
    ///   process  = callback entry to the send call, i.e. encode plus the copies.
    ///              Bounds what pipelining the encoder or removing a copy could
    ///              possibly win, before building either.
    /// Worst time seen in each stage of the capture callback since the last
    /// report.
    ///
    /// `process` spiked to ~30 ms against a 2.4 ms average and three separate
    /// theories for it were wrong -- the Data copy, the MTLBuffer wrap, the
    /// 10-bit probe. Sampling found none of our code on the capture queue at
    /// all, which means the spike is either somewhere unsampled or is not where
    /// the aggregate suggests. Splitting the number is cheaper than a fourth
    /// guess: whichever stage owns the maximum is the answer.
    /// Frames sent as damage rects vs as whole frames, since the last report.
    /// Without this the only evidence was a once-per-session log line describing
    /// the FIRST frame, which is always a keyframe — so it said "whole frame"
    /// regardless of what followed.
    /// Why the rect path was skipped, counted per reason. Two guesses at this
    /// were wrong, so it reports rather than infers.

    private var stageProbeMax = 0.0     // depth/alpha probe
    private var stageLockMax = 0.0      // CVPixelBufferLockBaseAddress
    private var stageCtxMax = 0.0       // frame context + closures
    private var stageSubmitMax = 0.0    // encoder submission

    private var latDeliverySum = 0.0, latDeliveryMax = 0.0
    private var latProcessSum = 0.0, latProcessMax = 0.0
    private var latSamples = 0

    private var capCadenceBin = [Int](repeating: 0, count: 8)
    private var sendCadenceBin = [Int](repeating: 0, count: 8)
    private var capCadenceCount = 0
    private var lastCapturePTS: Double = 0
    private var lastSendAt: Double = 0
    private var cadenceDrops = 0

    private var dpcmGPU: OpaquePointer?
    private var dpcmGPUTried = false
    /// The compression ratio is worth seeing once per session, not 60 times a
    /// second.
    private var dpcmLogged = false
    private var pathLogged = false

    /// States, once per session, which video path actually carried a frame — and
    /// when it is not the best one available, WHY.
    ///
    /// This exists because every downgrade in this file used to be silent. The
    /// lossless path logged its compression ratio on success; the fallbacks
    /// logged nothing at all, so "we quietly sent 4:2:0 NV12 instead" looked
    /// exactly like "everything is fine" until somebody noticed it felt slow.
    /// Diagnosing one such downgrade cost most of a day and three wrong
    /// theories, every one of them an inference about which path was live that
    /// could have been a fact instead.
    ///
    /// The existing "pipeline started ... codec=HEVC rawNV12=false" line is
    /// actively misleading — it reports what was CONFIGURED, and reads the same
    /// whether the frames then go out as HEVC, raw NV12 or lossless DPCM. This
    /// one reports what happened.
    private func noteResolvedPath(_ what: String) {
        guard !pathLogged else { return }
        pathLogged = true
        // emit() already writes to os_log AND the durable file; logging here as
        // well only duplicated it in Console.
        TBTelemetryReporter.emit("video path: \(what)")
    }

    // Confined to `queue`.
    private var vtEncoder: VTCompressionSession?
    private var vtEncoderRef: Unmanaged<TBVideoPipeline>?
    /// Packets handed to the transport and not yet reported back as processed.
    ///
    /// This said "confined to `queue`" and was not. THREE queues touch it: the
    /// capture queue reads it for the backpressure test and increments it on the
    /// raw paths, the encoder's own `plan_q` increments it from the DPCM `send`
    /// callback, and `queue` ran every decrement. A plain `Int` under
    /// `+= 1` / `= max(0, x - 1)` is a read-modify-write, so a collision loses
    /// one of the two updates.
    ///
    /// Losing them is not symmetric, which is what makes it worth a lock rather
    /// than a shrug. The clamp absorbs a lost increment — the count simply
    /// floors at zero — while a lost DECREMENT is permanent. So the value is a
    /// random walk against a reflecting barrier, and it can only drift upward.
    /// Drift far enough and `backedUp` is true for every frame, which is a
    /// stream that decays to nothing and recovers only when the sender is
    /// restarted. That is not the stall we chased on 2026-08-07 (this read
    /// 0-1/12 throughout it) but it is a faithful reproduction of the symptom,
    /// waiting to happen.
    private let pendingVideoPackets = OSAllocatedUnfairLock(initialState: 0)
    private var inFlightEncodeFrames = 0
    private var displayStreamFrameSequence: CMTimeValue = 0
    private var lastEncodedDisplayPTS: CMTime?
    private var ackSent: Bool
    private var running = false

    /// The in-flight count for whichever cable a frame is going out on.
    ///
    /// Retain before handing the packet to the transport, release when it
    /// reports the packet processed. Both are atomic, and the release no longer
    /// hops through `queue` to get there: the hop existed to make the mutation
    /// safe, the lock does that now, and going direct means the backpressure
    /// test reads a count that is current rather than one queue-hop stale.
    private func pendingRetain()  { pendingVideoPackets.withLock { $0 += 1 } }
    private func pendingRelease() { pendingVideoPackets.withLock { $0 = max(0, $0 - 1) } }
    private func pendingCount() -> Int { pendingVideoPackets.withLock { $0 } }

    // Read from the main thread (fps timer / watchdog); guarded by `lock`.
    private let lock = NSLock()
    private var _sentFrames = 0
    private var _lastCaptureFrameAt = Date()

    init(preset: TBDisplayCapturePreset,
         codecType: CMVideoCodecType,
         connection: NWConnection,
         displayName: String,
         displayID: CGDirectDisplayID,
         usesRawNV12: Bool,
         ackAlreadySent: Bool,
         onFirstFrame: @escaping @Sendable () -> Void) {
        self.preset = preset
        self.codecType = codecType
        self.connection = connection
        self.displayName = displayName
        self.displayID = displayID
        self.usesRawNV12 = usesRawNV12
        self.ackSent = ackAlreadySent
        self.onFirstFrame = onFirstFrame
    }

    // MARK: - Lifecycle (called from the main actor)

    /// Sets up the encoder on `queue`. Returns false if the hardware encoder
    /// could not be created.
    func start() -> Bool {
        queue.sync {
            if usesRawNV12 {
                running = true
                return true
            }
            setupEncoder()
            running = vtEncoder != nil
            return running
        }
    }

    /// Tears the encoder down on `queue`. Because the queue is serial, any
    /// in-flight `encode` completes before `VTCompressionSessionInvalidate`,
    /// so a frame can never encode into an invalidated session.
    func stop() {
        queue.sync {
            running = false
            if let encoder = vtEncoder { VTCompressionSessionInvalidate(encoder) }
            vtEncoder = nil
            vtEncoderRef?.release()
            vtEncoderRef = nil
            // The DPCM encoder holds a Metal device and ~60-90 MB of reusable
            // buffers; without this every session start/stop stranded a copy.
            // Safe here for the same reason the VT teardown is: `queue` is
            // serial, so no encode is mid-flight when this runs.
            if let e = dpcmGPU { tb_dpcm_gpu_destroy(e) }
            dpcmGPU = nil
            dpcmGPUTried = false
        }
    }

    // MARK: - Snapshots for the main thread

    var sentFramesSnapshot: Int {
        lock.lock(); defer { lock.unlock() }
        return _sentFrames
    }

    var lastCaptureFrameAtSnapshot: Date {
        lock.lock(); defer { lock.unlock() }
        return _lastCaptureFrameAt
    }

    func diagnosticsSnapshot() -> (pending: Int, inFlight: Int, ptsSeq: CMTimeValue) {
        queue.sync { (pending: pendingCount(), inFlight: inFlightEncodeFrames, ptsSeq: displayStreamFrameSequence) }
    }

    private func markCaptureFrame() {
        lock.lock(); _lastCaptureFrameAt = Date(); lock.unlock()
    }

    // MARK: - Encoder setup (on `queue`)

    private func setupEncoder() {
        if let encoder = vtEncoder { VTCompressionSessionInvalidate(encoder) }
        vtEncoder = nil
        vtEncoderRef?.release()
        vtEncoderRef = nil

        let spec: NSDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        let retained = Unmanaged.passRetained(self)
        vtEncoderRef = retained

        let callback: VTCompressionOutputCallback = { ref, _, status, _, sampleBuffer in
            guard let ref else { return }
            let pipeline = Unmanaged<TBVideoPipeline>.fromOpaque(ref).takeUnretainedValue()
            pipeline.queue.async {
                pipeline.inFlightEncodeFrames = max(0, pipeline.inFlightEncodeFrames - 1)
                guard status == noErr, let sampleBuffer else { return }
                pipeline.handleEncoded(sampleBuffer)
            }
        }

        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(preset.width),
            height: Int32(preset.height),
            codecType: codecType,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: retained.toOpaque(),
            compressionSessionOut: &session
        ) == noErr, let session else {
            retained.release()
            vtEncoderRef = nil
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        if codecType == kCMVideoCodecType_HEVC {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: preset.expectedFrameRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: preset.maxKeyFrameInterval))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: preset.maxKeyFrameIntervalDuration))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: preset.maxFrameDelayCount))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: preset.averageBitRate))
        if preset.prioritizeSpeed {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        vtEncoder = session
    }

    // MARK: - Encode paths (on `queue`)

    /// Opt-in raw passthrough (`RAW=1`): ScreenCaptureKit already captures NV12,
    /// so we can forward the planes uncompressed and skip the encoder entirely.
    /// This removes all decode cost on the receiver — useful when the receiver is
    /// an older Intel Mac whose HEVC decoder struggles at high resolutions — at
    /// the price of much higher bandwidth (~10.6 Gb/s for 5K@60 4:2:0), which a
    /// direct Thunderbolt Bridge link comfortably sustains.
    /// Env override for power users / automation. The UI toggle is the primary
    /// switch; `RAW=1` in the environment forces it on regardless of the setting.
    private var rawEnvOverride: Bool {
        guard let v = ProcessInfo.processInfo.environment["RAW"] else { return false }
        return v == "1" || v.lowercased() == "true"
    }

    private var rawEnabled: Bool { preset.isRawPassthrough || rawEnvOverride }

    /// Read-only view of the active video path, for the UI and telemetry.
    /// Reports the *same* flag `encode()` branches on, so what the UI shows can
    /// never disagree with what the wire actually carries.
    var rawPassthroughActive: Bool { rawEnabled }

    /// Pixel format and link usage as *observed while sending*, not as derived
    /// from configuration. A 4:4:4 session that silently fell back to one cable
    /// is indistinguishable from a bandwidth fault unless the UI reports what
    /// actually went out, so these are recorded in `sendRawFrame` itself.
    private var _dpcmRatio: Double = 0
    /// Compression achieved by the lossless codec, or 0 when it did not run.
    /// Guarded by `lock` like the other fields the UI reads off this thread.
    var dpcmRatio: Double { lock.lock(); defer { lock.unlock() }; return _dpcmRatio }
    private var _rawFormatIsBGRA = false
    private var _rawFormatIsTenBit = false
    var rawFormatIsBGRA: Bool { lock.lock(); defer { lock.unlock() }; return _rawFormatIsBGRA }
    var rawFormatIsTenBit: Bool { lock.lock(); defer { lock.unlock() }; return _rawFormatIsTenBit }
    /// SCStream capture path. Must be dispatched onto `queue` by the caller.
    func encode(_ sampleBuffer: CMSampleBuffer) {
        markCaptureFrame()
        if rawEnabled {
            sendRawFrame(sampleBuffer)
            return
        }
        noteResolvedPath("HEVC hardware encoder — preset \(preset.rawValue) is not raw passthrough, so the lossless path does not apply")
        guard running, let encoder = vtEncoder,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        if preset.dropsBeforeEncodeWhenBacklogged,
           (pendingCount() >= preset.maxPendingVideoPackets ||
            inFlightEncodeFrames >= preset.maxInFlightEncodeFrames) {
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts, using: encoder)
    }

    /// CGDisplayStream capture path. Delivered directly on `queue` by
    /// `TBDirectDisplayStreamCapture`.
    func encodeDisplaySurface(_ surface: IOSurfaceRef, displayTime: UInt64) {
        markCaptureFrame()
        guard running, let encoder = vtEncoder else { return }
        if preset.dropsBeforeEncodeWhenBacklogged,
           (pendingCount() >= preset.maxPendingVideoPackets ||
            inFlightEncodeFrames >= preset.maxInFlightEncodeFrames) {
            return
        }

        let attrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: preset.width,
            kCVPixelBufferHeightKey: preset.height,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()
        ]
        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            attrs,
            &unmanagedPixelBuffer
        ) == kCVReturnSuccess, let unmanagedPixelBuffer else {
            return
        }
        let pixelBuffer = unmanagedPixelBuffer.takeRetainedValue()

        displayStreamFrameSequence += 1
        // Derive PTS from the frame's actual capture time. CGDisplayStream
        // delivers frames irregularly (event-driven on screen changes), so a
        // frame-counter PTS would drift away from real wall-clock time over a
        // long session and pace the receiver progressively wrong. displayTime is
        // in mach-absolute units, the same host clock the SCStream path uses.
        var pts = displayTime != 0
            ? CMClockMakeHostTimeFromSystemUnits(displayTime)
            : CMClockGetTime(CMClockGetHostTimeClock())
        if let last = lastEncodedDisplayPTS, CMTimeCompare(pts, last) <= 0 {
            // VTCompressionSession requires strictly increasing PTS.
            pts = CMTimeAdd(last, CMTime(value: 1, timescale: 600))
        }
        lastEncodedDisplayPTS = pts
        encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts, using: encoder)
    }

    private func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp pts: CMTime, using encoder: VTCompressionSession) {
        inFlightEncodeFrames += 1
        let status = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            inFlightEncodeFrames = max(0, inFlightEncodeFrames - 1)
        }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard running else { return }

        if !ackSent {
            ackSent = true
            let ack = TBMonitorCreateSessionAck(
                accepted: true,
                displayName: displayName,
                displayID: displayID
            )
            if let packet = TBMonitorProtocol.makeJSONPacket(type: .createSessionAck, value: ack) {
                connection.send(content: packet, completion: .contentProcessed({ _ in }))
            }
            onFirstFrame()
        }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        if !isKeyframe, pendingCount() >= preset.maxPendingVideoPackets {
            return
        }

        if isKeyframe,
           let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let packet = buildParamSetsPacket(from: format, codecType: codecType) {
            connection.send(content: packet, completion: .contentProcessed({ _ in }))
        }

        if let packet = buildFramePacket(from: sampleBuffer) {
            pendingRetain()
            connection.send(content: packet, completion: .contentProcessed({ [weak self] _ in
                guard let self else { return }
                self.pendingRelease()
            }))
            lock.lock(); _sentFrames += 1; lock.unlock()
        }
    }

    /// A new link starts with no base image on the far side.

    /// Raw passthrough: package the two NV12 planes of the captured pixel buffer
    /// and send them uncompressed. The receiver blits them directly (no decode).
    /// Payload: [1: format=1(NV12)][BE32 w][BE32 h][BE32 yStride][BE32 uvStride]
    ///          [Y plane: yStride*h][CbCr plane: uvStride*(h/2)]
    /// One 60 Hz refresh period, the unit both cadence histograms are binned in.
    private static let refreshPeriod = 1.0 / 60.0

    private func cadenceBin(_ seconds: Double) -> Int {
        let periods = Int((seconds / Self.refreshPeriod).rounded())
        return max(0, min(7, periods))
    }

    /// Bin a CAPTURE gap in units of the measured arrival interval.
    ///
    /// `cadenceBin` divides by a hardcoded 1/60, which is right for sends — we
    /// send 60 — but wrong for arrivals the moment capture is oversampled, and
    /// wrong in the worst way: at 120 Hz an 8.33 ms gap is 0.5 periods and Swift
    /// rounds that AWAY from zero, so every arrival landed in bin 1 and the
    /// histogram read as a flawless 60 Hz cadence. It was not reporting the
    /// capture rate at all. At 240 Hz the same divisor collapses everything into
    /// bin 0. Both hide exactly what the oversampling experiment needs to see.
    ///
    /// Binning against the arrival interval keeps the meaning that made this
    /// histogram useful: 1 is on time, 2 is one missed arrival, whatever the rate.
    /// The absolute rate is reported separately as `interval`, since a histogram
    /// normalised by its own rate can no longer show it.
    private func captureBin(_ seconds: Double) -> Int {
        let periods = Int((seconds / max(captureIntervalEMA, 0.0005)).rounded())
        return max(0, min(7, periods))
    }

    /// Host-clock seconds, the same timebase sample buffer timestamps use.
    private static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    private func noteCapture(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let delivery = (Self.hostNow() - pts) * 1000.0
        // Negative or absurd values mean the buffer is not on the host clock as
        // expected; ignore rather than poison the average.
        if delivery > 0, delivery < 500 {
            latDeliverySum += delivery
            latDeliveryMax = max(latDeliveryMax, delivery)
        }
        if lastCapturePTS > 0, pts > lastCapturePTS {
            let delta = pts - lastCapturePTS
            capCadenceBin[captureBin(delta)] += 1
            capCadenceCount += 1
            // Track the real arrival interval for the throttle's tolerance.
            // Bounded to 1..50ms (240 Hz .. 20 Hz) so a stall or a resume does not
            // drag the estimate somewhere that makes the tolerance unsafe; alpha
            // 1/16 settles in ~20 frames, which is well inside a second.
            if delta > 0.001, delta < 0.050 {
                captureIntervalEMA += (delta - captureIntervalEMA) / 16.0
            }
        }
        lastCapturePTS = pts

        guard capCadenceCount >= 240 else { return }

        // Snapshot, reset, and format somewhere else.
        //
        // This block used to run on the capture thread: four os_log calls and
        // two histograms built with enumerated/filter/map/joined, which is a lot
        // of allocation. It fired once per 240 frames and produced exactly one
        // 2-period gap per 240 frames -- the last 1% of `send(wall)`, and the
        // one thing `process` could never show, because the report happens after
        // the measurement it reports.
        //
        // Diagnostics must not perturb what they measure. Copying eight ints and
        // a few doubles is cheap; formatting them is not.
        let capBins = capCadenceBin
        let sendBins = sendCadenceBin
        let capInterval = captureIntervalEMA
        let skips = oversampleSkips
        let drops = cadenceDrops
        let idle = tbIdleFramesSeen
        let idleGap = tbIdleInputGapMin
        let wShortSum = tbWakeShortSum, wShortN = tbWakeShortCount
        let wLongSum = tbWakeLongSum, wLongMax = tbWakeLongMax, wLongN = tbWakeLongCount
        let wakeRej = tbWakeRejected
        let sProbe = stageProbeMax, sLock = stageLockMax
        let sCtx = stageCtxMax, sSubmit = stageSubmitMax
        let hadProcess = latProcessMax > 0
        let dSum = latDeliverySum, dMax = latDeliveryMax
        let pSum = latProcessSum, pMax = latProcessMax
        let samples = latSamples
        let inflight = pendingCount()
        let budget = preset.maxPendingVideoPackets
            * ((dpcmEnabled && dpcmSlicesEnabled) ? max(1, dpcmSliceCount) : 1)

        oversampleSkips = 0
        tbIdleFramesSeen = 0
        tbIdleInputGapMin = .greatestFiniteMagnitude
        tbWakeShortSum = 0; tbWakeShortCount = 0
        tbWakeLongSum = 0; tbWakeLongMax = 0; tbWakeLongCount = 0
        tbWakeRejected = 0
        stageProbeMax = 0; stageLockMax = 0; stageCtxMax = 0; stageSubmitMax = 0

        TBTelemetryReporter.report(capBins: capBins, sendBins: sendBins,
                                   capIntervalMs: capInterval * 1000.0,
                                   oversampleSkips: skips,
                                   drops: drops, idle: idle,
                                   probe: sProbe, lock: sLock,
                                   ctx: sCtx, submit: sSubmit,
                                   hadProcess: hadProcess,
                                   deliverySum: dSum, deliveryMax: dMax,
                                   processSum: pSum, processMax: pMax,
                                   samples: samples,
                                   inflight: inflight, budget: budget,
                                   idleInputGap: idleGap,
                                   wakeShortSum: wShortSum, wakeShortCount: wShortN,
                                   wakeLongSum: wLongSum, wakeLongMax: wLongMax,
                                   wakeLongCount: wLongN, wakeRejected: wakeRej)

        latDeliverySum = 0; latDeliveryMax = 0
        latProcessSum = 0; latProcessMax = 0
        latSamples = 0
        capCadenceBin = [Int](repeating: 0, count: 8)
        sendCadenceBin = [Int](repeating: 0, count: 8)
        capCadenceCount = 0
        cadenceDrops = 0
    }

    private func noteSend() {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        if lastSendAt > 0 { sendCadenceBin[cadenceBin(now - lastSendAt)] += 1 }
        lastSendAt = now
    }

    private func sendRawFrame(_ sampleBuffer: CMSampleBuffer) {
        guard running,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        noteCapture(sampleBuffer)

        // Deliberate decimation, before any work is done on this frame.
        //
        // Placed after noteCapture so the capture cadence still reports what the
        // compositor produced — that is the number that tells us the
        // oversampling is actually happening.
        if maxSendFPS > 0 {
            let now = Self.hostNow()
            let period = 1.0 / Double(maxSendFPS)

            // Slide the schedule if the receiver reported a bad phase. Applied
            // here, on the thread that owns `nextSendHostTime`, so the schedule has
            // exactly one writer. The shift moves WHEN a slot opens, never how far
            // apart slots are, so the send rate is untouched: one interval comes out
            // 2.08ms long and every interval after it is a normal period again.
            if phaseShiftPending {
                phaseShiftLock.lock()
                let shift = pendingPhaseShift
                pendingPhaseShift = 0
                phaseShiftPending = false
                phaseShiftLock.unlock()
                nextSendHostTime += shift
            }

            // A SLOT SCHEDULE, not a minimum gap.
            //
            // The old rule was "at least 0.95 of a period since the last send". At
            // 60 Hz capture that is safe: arrivals are 16.67ms apart against a
            // 15.83ms gate, so every frame passes. Oversample capture to 120 Hz and
            // it inverts — two arrivals are 16.67ms, leaving 0.83ms of headroom,
            // while measured arrival jitter is several milliseconds. A pair landing
            // slightly early is skipped, the next chance is a whole 8.33ms later,
            // and that send lands ~25ms after the last one, which the receiver bins
            // as a dropped 60 Hz period. Measured 5-8% late frames at 120 Hz against
            // 0.3-1% at 60 Hz.
            //
            // Advancing a schedule by exactly one period cannot drift, and the
            // tolerance accepts a frame arriving slightly early rather than
            // forfeiting the slot.
            //
            // The tolerance is bounded by the ARRIVAL interval, not the send
            // period. A fixed quarter-period is 4.17ms at 60 fps out, which is
            // safely below a 120 Hz arrival gap (8.33ms) but exactly EQUAL to a
            // 240 Hz one — so at 240 Hz a slot would admit the next arrival too
            // and we would send in pairs, doubling the wire rate and putting the
            // sends back into the bursty pattern the schedule exists to remove.
            // 40% of the measured arrival gap keeps a comfortable margin at any
            // capture rate, and stays far above the ±1ms jitter we now have.
            let tolerance = min(period * 0.25, captureIntervalEMA * 0.4)
            if now + tolerance < nextSendHostTime {
                oversampleSkips += 1
                return
            }
            nextSendHostTime += period
            // More than a period behind (a stall, or the first frame): resync rather
            // than firing a catch-up burst.
            if nextSendHostTime < now { nextSendHostTime = now + period }
        }

        let frameEnteredAt = Self.hostNow()
        let planar = CVPixelBufferGetPlaneCount(pixelBuffer) >= 2

        // The threshold means "roughly this many FRAMES of work in flight", and
        // the counter used to agree because a frame was one packet. Slicing
        // changed the unit without changing the number: at 18 bands a single
        // frame emits 18 packets, so from the fourth band on the gate was
        // permanently tripped and nearly every later frame was dropped before it
        // was even encoded. Scale the budget by the band count so the intent —
        // three frames, not three packets — survives.
        let packetsPerFrame = (dpcmEnabled && dpcmSlicesEnabled) ? max(1, dpcmSliceCount) : 1
        let inFlightBudget = preset.maxPendingVideoPackets * packetsPerFrame
        // Reserve the WHOLE frame, not one packet.
        //
        // This checked `pending >= budget` once and then sent packetsPerFrame
        // packets, so it could pass at 17 and land at 25 against a budget of 24.
        // Observed exactly that at N=8 -- `inflight 25/24` with 167 drops -- and
        // it is the same frame-versus-band unit confusion that has bitten this
        // code repeatedly: the check counted packets, the send counted frames.
        let pendingNow = pendingCount()
        let backedUp = pendingNow + packetsPerFrame > inFlightBudget
        if backedUp {
            // A skipped frame's damage would otherwise be lost for good, since
            // the receiver cannot know it missed an update. Carry the rects
            // forward and fold them into the next packet we do send — the
            // pixels come from the newer frame, which is what we want anyway.
            // (Forcing a full frame here instead caused a feedback loop: 59 MB
            // takes longer than a frame period, producing more backpressure,
            // more drops and more full frames — it pinned the stream at 26 fps.)
            cadenceDrops += 1
            return
        }

        let lockStart = Self.hostNow()
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        stageLockMax = max(stageLockMax, (Self.hostNow() - lockStart) * 1000.0)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Send the session ack on the first frame, mirroring the encoded path.
        if !ackSent {
            ackSent = true
            let ack = TBMonitorCreateSessionAck(accepted: true, displayName: displayName, displayID: displayID)
            if let packet = TBMonitorProtocol.makeJSONPacket(type: .createSessionAck, value: ack) {
                connection.send(content: packet, completion: .contentProcessed({ _ in }))
            }
            onFirstFrame()
        }

        let payload: Data
        if planar {
            // NV12 (4:2:0) — two planes. format byte = 1.
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
            else { return }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            let ySize = yStride * height
            let uvSize = uvStride * uvHeight

            var p = Data(capacity: 17 + ySize + uvSize)
            p.append(1) // format: NV12 4:2:0
            TBMonitorProtocol.appendBE32(&p, UInt32(width))
            TBMonitorProtocol.appendBE32(&p, UInt32(height))
            TBMonitorProtocol.appendBE32(&p, UInt32(yStride))
            TBMonitorProtocol.appendBE32(&p, UInt32(uvStride))
            p.append(UnsafeBufferPointer(start: yBase.assumingMemoryBound(to: UInt8.self), count: ySize))
            p.append(UnsafeBufferPointer(start: uvBase.assumingMemoryBound(to: UInt8.self), count: uvSize))
            payload = p
        } else {
            // Packed 4:4:4, one plane: BGRA8888 (format 2) or 2-10-10-10
            // (format 3). Both are 4 bytes/pixel, so the layout is identical
            // apart from the format byte the receiver keys its texture off.
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
            let isTenBit = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_ARGB2101010LEPacked
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let size = stride * height
            let probeStart = Self.hostNow()
            if isTenBit {
                probeTenBitDepth(base, width: width, height: height, stride: stride)
            } else {
                probeAlphaConstant(base, width: width, height: height, stride: stride)
            }
            stageProbeMax = max(stageProbeMax, (Self.hostNow() - probeStart) * 1000.0)
            let fmt: UInt8 = isTenBit ? 3 : 2

            // Lossless tile-DPCM, when the receiver can decode it on its GPU.
            //
            // This replaces both the full-frame and the damage paths rather than
            // layering on top of them. A compressed frame is ~20 MB at 5K in the
            // worst case and ~4 MB on ordinary desktop content, which the
            // receiver takes ~8 ms to read and ~7.5 ms to decode — inside a 60 Hz
            // period without any incremental update. Damage would buy nothing
            // here and cost a great deal: the decoded frame lives in the
            // receiver's VRAM, where there is no CPU-side copy to patch.
            //
            // Both depths. 10-bit compresses worse — 1.85x on photographic
            // content against 2.89x at 8-bit, measured — because two extra bits
            // per sample widen every residual. It is carried anyway because the
            // depth is visible: the virtual display's framebuffer is 8-bit, but
            // the capture-side P3 conversion deposits sub-8-bit detail in the
            // low bits, and on the panel that detail is the difference between a
            // smooth gradient and a banded one.
            if !dpcmEnabled {
                // The single most likely reason to be sending 4:2:0 when 4:4:4
                // lossless was expected, and it used to be invisible.
                noteResolvedPath("RAW \(planar ? "NV12 4:2:0" : (isTenBit ? "10-bit 4:4:4" : "BGRA 4:4:4")) — the receiver did not advertise DPCM support")
            }
            if dpcmEnabled {
                if !dpcmGPUTried {
                    dpcmGPUTried = true
                    dpcmGPU = tb_dpcm_gpu_create()
                    if let e = dpcmGPU {
                        TBLog.connection.info("dpcm: gpu encoder on \(String(cString: tb_dpcm_gpu_device_name(e)), privacy: .public)")
                    } else {
                        TBLog.connection.error("dpcm: gpu encoder unavailable; sending uncompressed")
                        noteResolvedPath("RAW uncompressed — the DPCM GPU encoder could not be created")
                    }
                }
                // The encoder leaves room for the packet header ahead of the
                // blob, so the header is written in place and the packet is one
                // copy rather than two. Two copies of a ~30 MB frame measured
                // ~3 ms of the 10.1 ms this stage costs.
                // Slice the frame into bands so the receiver can decode band k
                // while band k+1 is still on the wire. N=1 is the whole-frame
                // case and behaves exactly as before.
                //
                // Bands must be whole 8-row tiles, so the count has to divide the
                // frame that way; anything else falls back to one band rather
                // than silently sending a geometry the receiver will reject.
                // Every frame is a whole frame, sent as bands.
                let wantSlices = dpcmSlicesEnabled ? max(1, dpcmSliceCount) : 1
                let bandRows = height / wantSlices
                let sliceCount = (wantSlices > 1 && bandRows % Int(TB_DPCM_TILE) == 0
                                  && bandRows * wantSlices == height) ? wantSlices : 1
                let rowsPerBand = height / sliceCount
                let reserve = TBMonitorProtocol.headerSize
                    + (sliceCount > 1 ? TBMonitorProtocol.sliceHeaderSize : 0)

                dpcmFrameID &+= 1
                let captureNanos = UInt64(max(0, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds) * 1_000_000_000)

                // Encode WITHOUT blocking this thread.
                //
                // This is ScreenCaptureKit's capture queue: the one thread that
                // must keep pace with the display. Waiting on the GPU here cost
                // 13-15 ms of a 16.7 ms period -- not for our own work, but for
                // a device shared with WindowServer -- so any spike pushed a
                // frame into the next period and two went out together. Capture
                // measured a clean 100% while `send` sat at 85-90%, with 7% of
                // packets leaving within 8 ms of the one before.
                //
                // Batching the bands into two submissions bought only ~1 ms,
                // because the cost was never the NUMBER of waits.
                //
                // The GPU reads these pixels after this returns, so the frame
                // context holds the pixel buffer locked and referenced until the
                // callback fires; ScreenCaptureKit would otherwise recycle it
                // mid-encode. `passRetained` is balanced by the `takeRetained`
                // in tbDPCMAsyncDone.
                let ctxStart = Self.hostNow()
                let frameCtx = TBDPCMFrameContext(
                    sampleBuffer: sampleBuffer,
                    pixelBuffer: pixelBuffer,
                    captureNanos: captureNanos,
                    frameID: dpcmFrameID,
                    sliceCount: sliceCount,
                    rowsPerBand: rowsPerBand,
                    width: width,
                    height: height,
                    send: { [weak self] packet in
                        guard let self else { return }
                        self.pendingRetain()
                        connection.send(content: packet, completion: .contentProcessed({ [weak self] _ in
                            guard let self else { return }
                            self.pendingRelease()
                        }))
                    },
                    finished: { [weak self] written, ok in
                        // The last band just went to the socket: this is when
                        // the frame actually reached the wire.
                        TBTelemetryReporter.noteEmit()
                        guard let self, ok, written > 0 else { return }
                        self.queue.async {
                            guard !self.dpcmLogged else { return }
                            self.dpcmLogged = true
                            let raw = stride * height
                            TBLog.connection.info("dpcm: \(width, privacy: .public)x\(height, privacy: .public) \(isTenBit ? 10 : 8, privacy: .public)-bit \(raw / 1_000_000, privacy: .public) MB -> \(written / 1_000_000, privacy: .public) MB (\(String(format: "%.2fx", Double(raw) / Double(written)), privacy: .public)) \(sliceCount, privacy: .public) slice(s) async")
                            self.lock.lock()
                            self._dpcmRatio = Double(raw) / Double(written)
                            self.lock.unlock()
                            self.noteResolvedPath("lossless DPCM · \(width)x\(height) \(isTenBit ? 10 : 8)-bit · \(sliceCount) slice(s) · \(String(format: "%.2fx", Double(raw) / Double(written)))")
                        }
                    })

                stageCtxMax = max(stageCtxMax, (Self.hostNow() - ctxStart) * 1000.0)

                // The retain is handed to C, so it must be balanced on BOTH
                // paths: the callback takes it on success, and we take it back
                // here on refusal. Leaking it would strand a LOCKED pixel
                // buffer, and ScreenCaptureKit's pool is small enough that a
                // few of those stop capture entirely.
                let submitStart = Self.hostNow()
                var submitted: Int32 = -1
                if let enc = dpcmGPU {
                    let opaque = Unmanaged.passRetained(frameCtx).toOpaque()
                    submitted = tb_dpcm_gpu_encode_bands_async(
                        enc,
                        base.assumingMemoryBound(to: UInt8.self),
                        Int32(stride), Int32(width),
                        Int32(rowsPerBand), Int32(sliceCount),
                        isTenBit ? 1 : 0, reserve,
                        tbDPCMAsyncDone, opaque)
                    if submitted != 0 {
                        Unmanaged<TBDPCMFrameContext>.fromOpaque(opaque).release()
                    }
                }

                stageSubmitMax = max(stageSubmitMax, (Self.hostNow() - submitStart) * 1000.0)

                if submitted == 0 {
                    // `process` now measures submission, which is the part that
                    // actually occupies this thread.
                    let process = (Self.hostNow() - frameEnteredAt) * 1000.0
                    if process >= 0, process < 500 {
                        latProcessSum += process
                        latProcessMax = max(latProcessMax, process)
                        latSamples += 1
                    }


                    lock.lock()
                    _sentFrames += 1
                    _rawFormatIsBGRA = true
                    _rawFormatIsTenBit = isTenBit
                    lock.unlock()
                    return
                }

                // Refused: every encoder slot is busy, or the geometry is one
                // it will not take. Either way this frame is dropped rather than
                // queued -- waiting would put the block back on this thread. The
                // retain was already released above, so the pixel buffer unlocks
                // when the context goes out of scope here.
                cadenceDrops += 1
                return

                // Encoder refused (only possible on a bad size or capacity):
                // fall through and send the frame uncompressed.
            }

            var p = Data(capacity: 13 + size)
            p.append(fmt) // format: ARGB2101010 / BGRA8888, both 4:4:4
            TBMonitorProtocol.appendBE32(&p, UInt32(width))
            TBMonitorProtocol.appendBE32(&p, UInt32(height))
            TBMonitorProtocol.appendBE32(&p, UInt32(stride))
            p.append(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: size))
            payload = p
        }

        let packet = TBMonitorProtocol.makePacket(type: .rawFrame, payload: payload)
        pendingRetain()
        connection.send(content: packet, completion: .contentProcessed({ [weak self] _ in
            guard let self else { return }
            self.pendingRelease()
        }))
        lock.lock()
        _sentFrames += 1
        _rawFormatIsBGRA = !planar
        _rawFormatIsTenBit = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_ARGB2101010LEPacked
        lock.unlock()
    }


    /// Is the alpha byte in captured BGRA actually constant?
    ///
    /// The desktop is opaque, so it should be 0xFF everywhere — which makes it
    /// a quarter of the wire carrying nothing. Worth 7 Gb/s at 5K60 4:4:4. But
    /// this is exactly the kind of assumption that turns out to be wrong on
    /// some machine or some content, so it is measured rather than assumed, and
    /// only reported until something depends on it.
    private func probeAlphaConstant(_ base: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int) {
        if alphaProbeCountdown > 0 { alphaProbeCountdown -= 1; return }
        alphaProbeCountdown = alphaProbeInterval
        alphaProbeInterval = Swift.min(alphaProbeInterval * 2, 216_000)

        var sampled = 0
        var opaque = 0
        let rowWords = stride / 4
        var index = 0
        let total = rowWords * height
        while index < total && sampled < 20_000 {
            let word = base.load(fromByteOffset: index * 4, as: UInt32.self)
            if (word >> 24) == 0xFF { opaque += 1 }
            sampled += 1
            index += 997
        }
        guard sampled > 0 else { return }
        TBLog.connection.notice(
            "alpha probe: \(opaque, privacy: .public)/\(sampled, privacy: .public) sampled pixels are fully opaque — all of them means the alpha byte is pure padding"
        )
    }

    /// Is the captured 10-bit frame *actually* carrying 10 bits?
    ///
    /// `CGVirtualDisplay` exposes no way to request a 10-bit framebuffer (the
    /// private API has no depth property at all), so the desktop may well be
    /// composited at 8-bit and merely widened into 'l10r' on capture. In that
    /// case every channel is a multiple of 4 and the low 2 bits are always
    /// zero — which is directly measurable. Sampled on a prime stride so we
    /// cover the frame without walking all 14.7M pixels.
    private var tenBitProbeCountdown = 0
    /// Frames to skip before the next depth probe, doubling each time.
    ///
    /// The probe touches ~143,000 scattered locations across a 59 MB buffer --
    /// 20,000 at a 997-word stride plus 48 rows of 2560 -- and every one is a
    /// cache and TLB miss. Measured at 12-38 ms ON THE CAPTURE THREAD, which was
    /// the entire `process` spike: 2.7 ms average against a 40.7 ms maximum,
    /// with the stage breakdown reading `probe 38.4 | lock 9.0 | ctx 0.0 |
    /// submit 0.4`.
    ///
    /// It is pure diagnostics, and the answer cannot change during a session:
    /// the framebuffer's depth is fixed when the display is created. Early
    /// frames are worth probing (the first ones can carry a partially drawn
    /// desktop and read low), so back off rather than probe once — the interval
    /// doubles until it is effectively never, and a format change resets it.
    private var tenBitProbeInterval = 180
    private var alphaProbeInterval = 300
    private var alphaProbeCountdown = 0
    private func probeTenBitDepth(_ base: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int) {
        if tenBitProbeCountdown > 0 { tenBitProbeCountdown -= 1; return }
        tenBitProbeCountdown = tenBitProbeInterval
        // ~3s, then 6, 12, 24... capped where it stops mattering.
        tenBitProbeInterval = Swift.min(tenBitProbeInterval * 2, 216_000)

        var sampled = 0
        var deep = 0
        let rowWords = stride / 4
        var index = 0
        let total = rowWords * height
        while index < total && sampled < 20_000 {
            let word = base.load(fromByteOffset: index * 4, as: UInt32.self)
            let r = (word >> 20) & 0x3FF
            let g = (word >> 10) & 0x3FF
            let b = word & 0x3FF
            // Non-zero low bits do NOT mean real depth. The standard 8->10
            // widening is bit replication, v10 = (v8 << 2) | (v8 >> 6), which
            // sets the low 2 bits on almost every sample — so the old test
            // reported ~99% on padded 8-bit data and was worthless. What
            // separates the two is whether the low bits are PREDICTABLE from
            // the high 8: under replication they always are.
            func isReplicated(_ v: UInt32) -> Bool { (v & 3) == (v >> 8) }
            if !(isReplicated(r) && isReplicated(g) && isReplicated(b)) { deep += 1 }
            sampled += 1
            index += 997      // prime: spreads samples across rows and columns
        }
        // Distinct values, taking the richest row found rather than one fixed
        // row: whatever is being measured rarely fills the screen, and a row of
        // flat desktop reports a handful of levels and tells us nothing. An
        // 8-bit source cannot exceed 256 however it is converted afterwards; a
        // 10-bit one can reach 1024. Counting non-zero low bits cannot separate
        // real depth from bits a conversion invents.
        // A bitmap, not a Set. The values are 10 bits, so the whole domain is
        // 1024 flags = 16 words on the stack: no hashing, no allocation, no
        // growth. The Set version did 48 x 2560 = 122,880 inserts across 48
        // freshly grown Sets, on the CAPTURE thread, and that was the spike --
        // `process` averaged 2.4 ms and topped 34, once per cadence window,
        // which is exactly this probe's period. The spike bunched the next
        // frame against the late one and cost ~4% of send cadence.
        var best = 0
        var bestRow = 0
        let rowStep = Swift.max(1, height / 48)
        var row = 0
        while row < height {
            var bits = [UInt64](repeating: 0, count: 16)
            var distinct = 0
            bits.withUnsafeMutableBufferPointer { b in
                for x in 0..<Swift.min(width, 2560) {
                    let word = base.load(fromByteOffset: (row * rowWords + x) * 4, as: UInt32.self)
                    let v = Int((word >> 10) & 0x3FF)
                    let mask: UInt64 = 1 << UInt64(v & 63)
                    if b[v >> 6] & mask == 0 { b[v >> 6] |= mask; distinct += 1 }
                }
            }
            if distinct > best { best = distinct; bestRow = row }
            row += rowStep
        }
        TBLog.connection.notice(
            "10-bit depth: richest row (y=\(bestRow, privacy: .public)) has \(best, privacy: .public) distinct green levels — >256 means the source is deeper than 8-bit"
        )

        guard sampled > 0 else { return }
        let pct = Double(deep) * 100.0 / Double(sampled)
        TBLog.connection.notice(
            "10-bit probe: \(deep, privacy: .public)/\(sampled, privacy: .public) samples carry REAL sub-8-bit detail (\(String(format: "%.2f", pct), privacy: .public)%) — near 0% means 8-bit bit-replicated into l10r, not true 10-bit"
        )
    }



    private func buildParamSetsPacket(from format: CMVideoFormatDescription, codecType: CMVideoCodecType) -> Data? {
        if codecType == kCMVideoCodecType_HEVC {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            guard count > 0 else { return nil }

            var payload = Data([2, UInt8(count)])
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard let pointer else { continue }
                TBMonitorProtocol.appendBE32(&payload, UInt32(size))
                payload.append(UnsafeBufferPointer(start: pointer, count: size))
            }
            return TBMonitorProtocol.makePacket(type: .paramSets, payload: payload)
        } else {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            guard count > 0 else { return nil }

            var payload = Data([1, UInt8(count)])
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard let pointer else { continue }
                TBMonitorProtocol.appendBE32(&payload, UInt32(size))
                payload.append(UnsafeBufferPointer(start: pointer, count: size))
            }
            return TBMonitorProtocol.makePacket(type: .paramSets, payload: payload)
        }
    }

    private func buildFramePacket(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return nil }

        var payload = Data(count: totalLength)
        let status = payload.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        return TBMonitorProtocol.makePacket(type: .frame, payload: payload)
    }
}

/// Live, frequently-updating session readouts (currently just the FPS counter),
/// split out of `TBDisplaySenderSession` so their ~1 Hz changes only invalidate
/// the small subview that displays them rather than the whole session card.
@MainActor
final class TBSessionLiveMetrics: ObservableObject {
    @Published var senderFPS = 0
}

/// Thread-safe one-shot latch. `NWConnection` state handlers run on an
/// arbitrary queue and can fire more than once; a continuation must be resumed
/// exactly once.
private final class TBOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

@MainActor
final class TBDisplaySenderSession: NSObject, ObservableObject, Identifiable, @unchecked Sendable {
    private static let receiverIPDefaultsKey = "fd.tbdisplaysender.receiverIP"
    private struct SavedExtendedDisplayArrangement {
        let x: Int32
        let y: Int32
        let isRelativeToMainDisplay: Bool
    }

    private static let extendedArrangementDefaultsPrefix = "com.targetbridge.sender.extended-arrangement"

    private static func normalizedPng(for image: NSImage) -> Data? {
        let targetSize = NSSize(width: 32, height: 32)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        // Clear canvas
        NSColor.clear.set()
        NSRect(origin: .zero, size: targetSize).fill()

        // Draw the image centered
        let x = (targetSize.width - image.size.width) / 2
        let y = (targetSize.height - image.size.height) / 2
        image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height))

        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }

    private static let standardCursorPngs: [Data: Int] = {
        let standardCursors: [(Int, NSCursor)] = [
            (0, NSCursor.arrow),
            (1, NSCursor.iBeam),
            (2, NSCursor.pointingHand),
            (3, NSCursor.resizeLeft),
            (3, NSCursor.resizeRight),
            (3, NSCursor.resizeLeftRight),
            (4, NSCursor.resizeUp),
            (4, NSCursor.resizeDown),
            (4, NSCursor.resizeUpDown),
            (5, NSCursor.closedHand),
            (5, NSCursor.openHand),
            (6, NSCursor.crosshair)
        ]
        var dict = [Data: Int]()
        for (type, cursor) in standardCursors {
            if let png = normalizedPng(for: cursor.image) {
                dict[png] = type
            }
        }

        // Dynamically load private system window resize cursors to support macOS window borders perfectly
        let privateCursors: [(Int, String)] = [
            (3, "_windowResizeEastWestCursor"),
            (4, "_windowResizeNorthSouthCursor"),
            (7, "_windowResizeNorthWestSouthEastCursor"),
            (8, "_windowResizeNorthEastSouthWestCursor"),
            (3, "_horizontalResizeCursor"),
            (4, "_verticalResizeCursor")
        ]
        for (type, selName) in privateCursors {
            let sel = NSSelectorFromString(selName)
            if NSCursor.responds(to: sel),
               let cursorObj = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor,
               let png = normalizedPng(for: cursorObj.image) {
                dict[png] = type
            }
        }

        return dict
    }()

    let id = UUID()

    init(
        language: TBDisplaySenderLanguage,
        largeCursor: Bool,
        preventDisplaySleep: Bool,
        autoRestartOnWake: Bool,
        audioEnabled: Bool,
        verboseDisplayLogging: Bool = false
    ) {
        self.statusText = TBDisplaySenderStatusState.ready.text(language)
        self.receiverPanelText = TBDisplaySenderL10n.waitingReceiverProfile(language)
        self.virtualDisplayText = TBDisplaySenderL10n.virtualDisplayNotCreated(language)
        self.captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        self.displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
        self.language = language
        self.largeCursor = largeCursor
        self.preventDisplaySleep = preventDisplaySleep
        self.autoRestartOnWake = autoRestartOnWake
        self.audioEnabled = audioEnabled
        self.verboseDisplayLogging = verboseDisplayLogging
        self.streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: .standard1440p,
            source: .desktopMirror,
            language: language
        )
        super.init()
        // The saved name is keyed on the receiver address, and `receiverIP` is
        // restored from defaults as an INITIAL VALUE -- so its didSet never fires
        // at launch and the name was written but never read back. It looked like
        // naming worked until the app was relaunched.
        loadCustomNameForCurrentReceiver()
        registerWakeObservers()
        registerDisplayReconfigurationCallback()
    }

    deinit {
        for token in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            DistributedNotificationCenter.default().removeObserver(token)
        }
        if displayReconfigurationCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                Self.displayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }

    @Published var isConnected = false
    @Published var isStreaming = false
    @Published var statusText: String
    @Published var transportKind: TBTransportKind = .thunderboltBridge
    @Published var localInterfaceIP = ""

    /// The local interface the user actually chose, remembered separately from
    /// the one in use. `localInterfaceIP` is allowed to fall back to something
    /// else while this one is unplugged; normalizeSessionInterfaces restores it
    /// the moment it comes back. Without the split, one cable unplug silently
    /// and permanently repoints the session at whatever else was available.
    @Published var preferredLocalInterfaceIP = ""
    // Full-color 4:4:4: capture 8-bit BGRA instead of 4:2:0 NV12 — no chroma
    // subsampling, so colored edges/text are crisp. ~28 Gb/s at 5K@60, so it
    // realistically needs dual-cable. Raw presets only.
    @Published var selectedReceiverID = "" {
        didSet {
            if selectedReceiverID.isEmpty {
                receiverSupportsHEVCDecodeHint = nil
                receiverInputMonitoringTrustedHint = nil
                receiverAccessibilityTrustedHint = nil
            }
        }
    }
    @Published var isCableTesting = false
    @Published var cableTestResult: Double? = nil
    /// Per-cable breakdown for a dual-cable run; nil for a single-cable test.
    @Published var cableTestDetail: String? = nil
    private var isCableTestConnection = false
    @Published var receiverIP: String = UserDefaults.standard.string(forKey: receiverIPDefaultsKey) ?? "" {
        didSet {
            UserDefaults.standard.set(receiverIP, forKey: Self.receiverIPDefaultsKey)
            if receiverIP != oldValue {
                receiverSupportsHEVCDecodeHint = nil
                receiverInputMonitoringTrustedHint = nil
                receiverAccessibilityTrustedHint = nil
                // The address is what a name is stored against, so this is the
                // moment we learn which monitor's name to show.
                loadCustomNameForCurrentReceiver()
            }
        }
    }
    var shortHostName: String? {
        if let receiver = TBDisplaySenderService.shared.discoveredReceivers.first(where: {
            $0.id == selectedReceiverID ||
            $0.preferredIP == receiverIP ||
            $0.thunderboltIP == receiverIP ||
            $0.networkIP == receiverIP
        }) {
            return receiver.shortHostName
        }
        return nil
    }

    var receiverDisplayName: String {
        if let host = shortHostName {
            return host
        }
        return receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var receiverSubtitle: String {
        var parts: [String] = []
        let ip = receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ip.isEmpty {
            parts.append("\(TBDisplaySenderL10n.receiverIP(language)) \(ip)")
        }
        if !receiverPanelText.isEmpty {
            parts.append(receiverPanelText)
        }
        return parts.joined(separator: "\n")
    }

    private var micForwarder: TBMicForwarder?
    private var audioVolumeObserver: TBAudioDeviceVolumeObserver?
    @Published var audioEnabled: Bool
    @Published var brightness: Double = 1.0 {
        didSet {
            sendBrightnessUpdate()
        }
    }
    @Published var volume: Double = 0.5 {
        didSet {
            sendVolumeUpdate()
        }
    }
    /// Night Shift / True Tone on the receiver's own panel. Only offered when
    /// the receiver reports it can honour them (both are private CoreBrightness
    /// features, and True Tone needs supporting hardware).
    /// Receiver presents without waiting for its refresh boundary. Trades tearing
    /// for ~8 ms of latency — the largest addressable term left in the budget, and
    /// a question of taste rather than of measurement, so it is exposed rather
    /// than decided here.
    @Published var vsyncEnabled = (UserDefaults.standard.object(forKey: "TBVsync") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(vsyncEnabled, forKey: "TBVsync")
            if !adoptingReportedTweaks { sendDisplayTweaks() }
        }
    }

    @Published var nightShiftEnabled = false {
        didSet { if !adoptingReportedTweaks { sendDisplayTweaks() } }
    }
    @Published var trueToneEnabled = false {
        didSet { if !adoptingReportedTweaks { sendDisplayTweaks() } }
    }
    /// Set while adopting state the receiver reported, so the didSet observers
    /// above don't echo it back and start a loop.
    private var adoptingReportedTweaks = false
    @Published var receiverSupportsNightShift = false
    @Published var receiverSupportsTrueTone = false
    var audioAddonAvailable = true
    /// Mirrors the service's Audio Driver addon state. Stored rather than read
    /// through, because the session is a separate object from the service.
    var audioDriverAvailable = false
    var receiverSupportsHEVCDecodeHint: Bool?
    var receiverInputMonitoringTrustedHint: Bool?
    var receiverAccessibilityTrustedHint: Bool?
    @Published var senderFPS = 0
    /// Active video path for this session, mirrored from the pipeline on the first
    /// frame. `true` = raw NV12 passthrough (`RAW=1`), `false` = HEVC. Drives the
    /// "Video path" row in the session card.
    @Published var videoPathIsRaw = false
    /// Both observed from the pipeline, not from config — see `rawFormatIsBGRA`.
    @Published var videoPathIsBGRA = false
    @Published var videoPathIsTenBit = false
    /// Whether the LOSSLESS codec carried the frame, and at what ratio.
    ///
    /// Reported separately from `videoPathIsRaw` because they answer different
    /// questions. Raw means "bypassed the hardware encoder"; this means "the
    /// bytes were compressed losslessly rather than sent whole". The panel used
    /// to say "RAW · uncompressed 10-bit 4:4:4" while the log said 4.71x — both
    /// describing the same frames.
    @Published var videoPathIsLossless = false
    @Published var videoPathRatio: Double = 0
    // Live FPS readout. Kept on a dedicated observable so its once-per-second
    // update only re-renders the small FPS subview — not the whole session card
    // or (via the manager's objectWillChange bubble-up) the entire window.
    let liveMetrics = TBSessionLiveMetrics()
    /// What the user calls this monitor. Empty means "no name given", which falls
    /// back to the receiver's own name and then to a positional label.
    ///
    /// Persisted per session, because a display you have named is a thing you
    /// expect to still be named tomorrow. Keyed on the session's id, which is
    /// stable across launches.
    @Published var customName: String = "" {
        didSet {
            guard customName != oldValue else { return }
            saveCustomName()
            objectWillChange.send()
        }
    }

    /// Keyed on the RECEIVER ADDRESS, not the session id.
    ///
    /// `id` is a fresh UUID every launch, so a name stored under it could never be
    /// read back — it would look like it persisted until the app restarted. The
    /// address is what identifies a monitor across launches, which is also how the
    /// user thinks about it: the name belongs to the iMac, not to a session object.
    private static func nameKey(for receiverIP: String) -> String? {
        let trimmed = receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "TBMonitorName.\(trimmed)"
    }

    private func saveCustomName() {
        guard let key = Self.nameKey(for: receiverIP) else { return }
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }

    /// Called when the receiver address settles — at init and whenever it changes,
    /// since that is the moment we learn which monitor this session refers to.
    func loadCustomNameForCurrentReceiver() {
        guard let key = Self.nameKey(for: receiverIP) else { return }
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        if stored != customName {
            // Assign through the backing store to avoid didSet writing it straight
            // back out, which would be harmless but pointless.
            _customName = Published(initialValue: stored)
            objectWillChange.send()
        }
    }

    @Published var receiverPanelText: String
    @Published var virtualDisplayText: String
    @Published var captureDisplayText: String
    @Published var displayStateText: String
    @Published var language: TBDisplaySenderLanguage {
        didSet {
            refreshLocalizedText()
        }
    }
    @Published var largeCursor: Bool
    @Published var preventDisplaySleep: Bool = true
    @Published var autoRestartOnWake: Bool = true
    @Published var verboseDisplayLogging: Bool = false {
        didSet {
            if verboseDisplayLogging {
                startVerboseLoggingTimer()
            } else {
                stopVerboseLoggingTimer()
            }
        }
    }
    /// When enabled, the virtual display's backing store is sized to the capture
    /// preset instead of the receiver-advertised 5120x2880. Removes the capture-side
    /// downsample and the GPU cost of rendering pixels that get thrown away.
    @Published var matchRenderToStream: Bool = false

    @Published var capturePreset: TBDisplayCapturePreset = .standard1440p {
        didSet {
            if !isStreaming {
                streamResolutionText = TBDisplaySenderL10n.streamSummary(preset: capturePreset, source: captureSource, language: language)
            }
        }
    }
    @Published var captureSource: TBDisplayCaptureSource = .desktopMirror {
        didSet {
            if !isStreaming {
                streamResolutionText = TBDisplaySenderL10n.streamSummary(preset: capturePreset, source: captureSource, language: language)
            }
        }
    }
    @Published var streamResolutionText: String
    var inputRelayActive = false {
        didSet {
            guard inputRelayActive != oldValue else { return }
            applyCursorOverlayMode()
        }
    }
    @Published var inputControlRole: TBInputControlRole = .off {
        didSet {
            inputRelayActive = (inputControlRole == .senderMaster)
            if inputControlRole != .receiverMaster {
                injectedRemoteMouseLocation = nil
                injectedLeftClickTracker.reset()
                releaseInjectedModifiersIfNeeded()
                remoteHeldModifierKeyCodes.removeAll()
                suppressedTriggerKeyCode = nil
            }
        }
    }
    @Published var inputGestureMode: TBInputGestureMode = .native
    /// User-defined receiver-master shortcuts for this session. See
    /// TBInputBinding.
    @Published var inputBindings: [TBInputBinding] = []

    private var connection: NWConnection?
    /// Pending confirmation that a non-viable path is a real disconnection
    /// rather than a flap. Non-nil only while that timer is armed.
    private var pendingViabilityTeardown: DispatchWorkItem?
    /// How long a path must stay non-viable before we believe it. Long enough
    /// to outlast route churn, far short of TCP's own ~10s surrender.
    private static let viabilityGrace: TimeInterval = 2.5
    /// Holds the virtual display at a full compositing rate — see TBKeepWarm.
    private let keepWarm = TBKeepWarm()
    private let connectionQueue = DispatchQueue(label: "fd.tbmonitor.sender.connection", qos: .userInteractive)
    private var recvBuffer = Data()

    private var session = ReceiverBackedVirtualDisplaySession()

    /// This session's virtual display, or `kCGNullDirectDisplay` when it has none.
    ///
    /// Exposed so the menu bar can tell WHICH display it was opened on: macOS puts
    /// the menu bar on every screen, so opening it on a streamed display identifies
    /// that display, and the menu can show only its controls. That removes a
    /// monitor picker and any notion of a "selected" monitor.
    var virtualDisplayID: CGDirectDisplayID { session.displayID }
    private let audioConverter = SBAudioConverter()
    /// False until the receiver says otherwise, so an unknown receiver gets the
    /// older format instead of noise.
    private var receiverSupportsFloat32Audio = false
    private var receiverSupportsDPCM = false
    private var receiverSupportsDPCMSlices = false
    private var activeProfile: TBMonitorDisplayProfile?
    private var activeCodecType: CMVideoCodecType?
    private var activeCodecName: String?

    private var captureDelegate: CaptureDelegate?
    private var scStream: SCStream?
    private var directDisplayStream: TBDirectDisplayStreamCapture?
    private var pipeline: TBVideoPipeline?

    private var sentSnapshot = 0
    private var sessionAckSent = false
    private var fpsTimer: Timer?
    private var heartbeatTimer: Timer?
    private var firstFrameTimer: Timer?
    private var cursorTimer: Timer?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    /// Name of the local interface the current connect attempt is bound to
    /// (e.g. "bridge0"), resolved when dialing. Diagnostic context only.
    private var connectInterfaceName: String?
    /// Last state reported by NWConnection for the current attempt (e.g.
    /// "waiting(No route to host)") — surfaced when a connect fails or times
    /// out so the real reason is not lost.
    private var lastConnectionStateDetail: String?
    private var heartbeatSequence: UInt64 = 0
    private var statusState: TBDisplaySenderStatusState = .ready
    private var streamingActivity: NSObjectProtocol?
    /// Identity of the last cursor bitmap shipped, so we resend only on change.
    private var lastSentCursorImage: NSImage?
    /// Last size actually sent, so a pure resize is not skipped by identity.
    private var lastSentCursorSize: CGSize = .zero

    /// The accessibility pointer size, 1.0 when unset.
    ///
    /// Read from the same preference System Settings writes. Shake-to-find is NOT
    /// visible here -- NSCursor reports a fixed 28x40 throughout a shake -- so that
    /// magnification cannot currently be mirrored; this covers the setting a user
    /// actually chooses, which is what "Large cursor on receiver" was meant to be.
    static func systemCursorScale() -> CGFloat {
        let v = UserDefaults(suiteName: "com.apple.universalaccess")?
            .double(forKey: "mouseDriverCursorSize") ?? 0
        return v > 0 ? CGFloat(v) : 1.0
    }
    private var lastCheckedCursor: NSCursor?
    private var lastCheckedCursorType: Int = 0
    private var baselineDisplayIDs = Set<CGDirectDisplayID>()
    private var cursorDisplayID: CGDirectDisplayID = kCGNullDirectDisplay
    private var lastCursorPacket: TBMonitorCursor?
    private var injectedRemoteMouseLocation: CGPoint?
    private var injectedLeftClickTracker = TBInjectedClickStateTracker()
    private var injectedCommandDown = false
    private var injectedShiftDown = false
    private var injectedOptionDown = false
    private var injectedControlDown = false
    private var injectedCapsDown = false
    // Tracks the actual modifier keys still held on the receiver while a
    // System Events shortcut is running, so released keys are never restored.
    private var remoteHeldModifierKeyCodes = Set<UInt16>()
    /// While a binding trigger key is held (matched), swallow its key-up so the
    /// raw trigger key never reaches the slave.
    private var suppressedTriggerKeyCode: UInt16?
    private static var cachedSupportsHEVCHardwareEncode: Bool?
    private var receivedInputEventCount: UInt64 = 0
    var onRemoteSwitchRequest: ((Int) -> Void)?
    var onRemoteDeactivateInputRequest: (() -> Void)?
    nonisolated(unsafe) private var wakeObservers: [NSObjectProtocol] = []
    private var isRestartingCaptureAfterWake = false
    nonisolated(unsafe) private var displayReconfigurationCallbackRegistered = false
    private var verboseLoggingTimer: Timer?
    private var captureHealthWatchdog: Timer?

    nonisolated(unsafe) private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo else { return }
        let service = Unmanaged<TBDisplaySenderSession>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                service.handleDisplayReconfiguration(displayID: displayID, flags: flags)
            }
        }
    }

    private final class CaptureDelegate: NSObject, SCStreamOutput, SCStreamDelegate {
        var onFrame: ((CMSampleBuffer) -> Void)?
        var onAudio: ((CMSampleBuffer) -> Void)?
        var onError: ((Error) -> Void)?

        /// Send an unchanged frame anyway, so the wire runs at a constant rate.
        ///
        /// ScreenCaptureKit still ticks when nothing was composited, marking the
        /// frame `.idle`; its pixels are identical to the last one. Skipping
        /// those is why the frame rate falls on a static screen.
        ///
        /// Off by default because it buys no picture: the receiver would present
        /// the same image again and nothing about it is visible. It also cannot
        /// help judder, which is about when CONTENT changes, not how often we
        /// transmit. What it costs is constant — roughly 3.8 Gbps and a full GPU
        /// encode every refresh, on a laptop, forever.
        ///
        /// It exists because a constant rate is how a real monitor avoids ever
        /// deciding what to drop, and that is worth being able to measure rather
        /// than argue about. `defaults write com.targetbridge.sender
        /// TBAlwaysSend60 -bool true`, and `-bool false` to revert.
        private static let sendIdleFrames =
            UserDefaults.standard.bool(forKey: "TBAlwaysSend60")

        private static func shouldProcessFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: rawStatus)
            else {
                return true
            }

            switch status {
            case .complete, .started:
                if tbWakeIdleSince > 0 {
                    let idleSince = tbWakeIdleSince
                    tbWakeIdleSince = 0
                    let now = tbMonotonicNow()
                    let gap = CGEventSource.secondsSinceLastEventType(
                        .combinedSessionState, eventType: tbAnyInputEvent)
                    // Did that input land inside the quiet stretch? If it
                    // predates it, this frame is a caret blink or a clock and
                    // has nothing to do with the user.
                    if gap >= 0, gap <= tbWakeMaxPlausible, now - gap >= idleSince {
                        if now - idleSince >= tbWakeLongIdle {
                            tbWakeLongSum += gap
                            tbWakeLongMax = max(tbWakeLongMax, gap)
                            tbWakeLongCount += 1
                        } else {
                            tbWakeShortSum += gap
                            tbWakeShortCount += 1
                        }
                    } else {
                        tbWakeRejected += 1
                    }
                }
                return true
            case .idle:
                // Identical pixels. Carried only when the constant-rate
                // experiment is on; `.blank` and the stopped states stay
                // filtered either way, since those are not a picture at all.
                tbIdleFramesSeen += 1
                if tbWakeIdleSince == 0 { tbWakeIdleSince = tbMonotonicNow() }
                let gap = CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState, eventType: tbAnyInputEvent)
                if gap < tbIdleInputGapMin { tbIdleInputGapMin = gap }
                return sendIdleFrames
            case .blank, .suspended, .stopped:
                return false
            @unknown default:
                return true
            }
        }

        nonisolated func stream(_ stream: SCStream,
                                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                                of type: SCStreamOutputType) {
            if type == .audio {
                onAudio?(sampleBuffer)
                return
            }
            guard type == .screen else { return }
            guard Self.shouldProcessFrame(sampleBuffer) else { return }
            onFrame?(sampleBuffer)
        }

        nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
            onError?(error)
        }
    }

    private func setStatus(_ state: TBDisplaySenderStatusState) {
        statusState = state
        statusText = state.text(language)
    }

    private static func probeHEVCHardwareEncoderSupport() -> Bool {
        if let cachedSupportsHEVCHardwareEncode {
            return cachedSupportsHEVCHardwareEncode
        }

        let encoderSpecification: CFDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 1920,
            height: 1080,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session {
            VTCompressionSessionInvalidate(session)
        }

        let supported = status == noErr
        cachedSupportsHEVCHardwareEncode = supported
        return supported
    }

    private func resolvedCodecType(for preset: TBDisplayCapturePreset, profile: TBMonitorDisplayProfile?) -> CMVideoCodecType {
        switch preset {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            let receiverSupportsHEVC = profile?.supportsHEVCDecode ?? receiverSupportsHEVCDecodeHint ?? false
            if receiverSupportsHEVC, Self.probeHEVCHardwareEncoderSupport() {
                return kCMVideoCodecType_HEVC
            }
            return kCMVideoCodecType_H264
        case .crisp2160p60, .native5k, .native5kRaw60, .native5k60Experimental:
            return preset.codecType
        }
    }

    private func codecName(for codecType: CMVideoCodecType) -> String {
        codecType == kCMVideoCodecType_HEVC ? "HEVC" : "H.264"
    }

    private func refreshLocalizedText() {
        statusText = statusState.text(language)
        streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: capturePreset,
            source: captureSource,
            language: language,
            codecName: activeCodecName
        )

        if let profile = activeProfile {
            receiverPanelText = TBDisplaySenderL10n.receiverSummary(profile, language: language)
        } else {
            receiverPanelText = TBDisplaySenderL10n.waitingReceiverProfile(language)
        }

        if session.displayID != kCGNullDirectDisplay, !session.displayName.isEmpty {
            virtualDisplayText = TBDisplaySenderL10n.virtualDisplaySummary(
                name: session.displayName,
                id: session.displayID,
                language: language
            )
        } else {
            virtualDisplayText = TBDisplaySenderL10n.virtualDisplayNotCreated(language)
        }

        if captureDisplayText.isEmpty
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.italian)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.english)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.german)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.french)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.chinese) {
            captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        }

        if displayStateText.isEmpty
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.italian)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.english)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.german)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.french)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.chinese) {
            displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
        }
    }

    private func formattedCaptureErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        let details = "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
        let permissionGranted = CGPreflightScreenCaptureAccess()
        let lowered = nsError.localizedDescription.lowercased()

        if !permissionGranted {
            return TBDisplaySenderL10n.missingScreenRecordingPermission(language: language)
        }

        if lowered.contains("denied")
            || lowered.contains("not authorized")
            || lowered.contains("permission")
            || lowered.contains("tcc") {
            return TBDisplaySenderL10n.screenCaptureKitPermissionMismatch(details: details, language: language)
        }

        return details
    }

    func connect() {
        // A user-visible button must never do nothing silently.
        //
        // This guard used to be a bare `return`: press Connect with a stranded
        // `connection` object and the app did nothing, said nothing, and created
        // no socket. From the outside that is indistinguishable from a network
        // fault, and it sent us chasing the firewall, TCC, entitlements and code
        // signing for two days. The button looked enabled because `isConnected`
        // is a separate flag, and only relaunching the app cleared it.
        //
        // Reported through TBTelemetryReporter, not TBLog: `log stream` has never
        // reliably captured this subsystem, so a diagnostic sent only there is a
        // diagnostic we cannot read. The sink writes to receiver.log, which has
        // captured every other number in this project.
        // Recover only from a DEAD connection. `isConnected` true means the
        // session is live and this is a redundant Connect -- tearing that down
        // and redialling drops a working stream, which is exactly what happened
        // when a second Connect arrived during a healthy session.
        if isConnected, connection != nil {
            TBTelemetryReporter.emit("connect: already connected — nothing to do")
            return
        }
        if !receiverIP.isEmpty, !localInterfaceIP.isEmpty, connection != nil {
            // Non-nil but not connected means the previous connection was never
            // torn down. Recover rather than refuse: the user asked to connect,
            // and the stale object is ours to clean up.
            TBTelemetryReporter.emit(
                "connect: found a stale connection object (isConnected=\(isConnected))"
                + " — tearing it down and dialling again")
            stop(resetStatusTo: nil)
        }
        guard connection == nil else {
            TBTelemetryReporter.emit("connect: refused — teardown left a connection behind")
            return
        }
        guard !receiverIP.isEmpty, !localInterfaceIP.isEmpty else {
            TBTelemetryReporter.emit(
                "connect: refused — receiverIP=\"\(receiverIP)\""
                + " localInterfaceIP=\"\(localInterfaceIP)\" (one is empty)")
            return
        }
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        recvBuffer.removeAll(keepingCapacity: false)
        activeProfile = nil
        activeCodecType = nil
        activeCodecName = nil
        lastConnectionStateDetail = nil
        setStatus(.connecting(receiverDisplayName))

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo
        // Pin the source address ONLY for link-local peers.
        //
        // The pin exists because 169.254/16 has no specific route, so the table
        // sends it out the primary interface (usually Wi-Fi) and a dial to a
        // Thunderbolt Bridge peer leaves by the wrong link. A routable address
        // like 10.0.1.2 has its own route — `route get 10.0.1.2` names en1 — so
        // the pin adds nothing there.
        //
        // And it can cost something: with the pin, Network.framework rejected
        // this exact dial in 29ms with ENETDOWN while `nc` from the same host to
        // the same address over the same interface connected fine. Not pinning
        // when there is nothing to fix is both simpler and strictly safer.
        let needsSourcePin = receiverIP.hasPrefix("169.254.")
        if needsSourcePin, let localPort = NWEndpoint.Port(rawValue: 0) {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localInterfaceIP), port: localPort)
        }

        // Scope link-local dials to the interface that owns the local IP.
        // requiredLocalEndpoint pins the source address but NOT the egress
        // interface — the routing table keeps 169.254/16 on the primary
        // interface (usually Wi-Fi), so an unscoped dial to a Thunderbolt
        // Bridge peer leaves via the wrong link and times out.
        let interfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
        connectInterfaceName = TBConnectionDiagnostics.interfaceName(forLocalIP: localInterfaceIP, in: interfaces)
        let scopedHost = TBConnectionDiagnostics.scopedReceiverHost(
            receiverIP: receiverIP,
            localIP: localInterfaceIP,
            interfaces: interfaces
        )
        let dialHost: NWEndpoint.Host
        if scopedHost != receiverIP, let scopedAddress = IPv4Address(scopedHost) {
            dialHost = .ipv4(scopedAddress)
        } else {
            dialHost = NWEndpoint.Host(receiverIP)
        }
        TBLog.connection.info("connect: dialing \(scopedHost, privacy: .public):\(TBMonitorProtocol.port) from \(self.localInterfaceIP, privacy: .public) (\(self.connectInterfaceName ?? "unknown interface", privacy: .public)) transport=\(self.transportKind.rawValue, privacy: .public)")
        let conn = NWConnection(
            host: dialHost,
            port: NWEndpoint.Port(integerLiteral: TBMonitorProtocol.port),
            using: params
        )
        connection = conn

        // Unplugging the cable does not fail the connection — it just stops
        // being deliverable. TCP has no idea the peer became unreachable, so it
        // retransmits until it gives up, and for about ten seconds the session
        // looks alive: the virtual display stays on screen, capture keeps
        // running, frames go into a socket nobody is reading. Only then does the
        // state handler fire and teardown begin.
        //
        // Viability is the signal for exactly this. Network.framework reports
        // the path becoming undeliverable within about a second of the interface
        // going away, which turns unplug into a prompt, ordinary teardown — and
        // leaves auto-cast a clean slate, so plugging back in reconnects instead
        // of finding a session that still believes in itself.
        //
        // Non-viable is not always permanent (Wi-Fi roaming recovers), but for
        // this link it is: the transport is a cable, and the interface it was
        // pinned to no longer exists. Treating it as the end is right here and
        // still safe elsewhere, because reconnecting is cheap.
        // MUST be debounced. Viability is not a cable-detector: it flaps for
        // route churn, interface reconfiguration and transient conditions that
        // recover on their own in well under a second. Treating the first
        // `false` as fatal tore down healthy sessions several times in ten
        // minutes — a far worse bug than the ten-second teardown it replaced.
        //
        // So: a real unplug is a path that is STILL non-viable a moment later.
        // A flap is one that has already recovered. Waiting costs a couple of
        // seconds on genuine unplug and remains much faster than TCP's ~10s.
        conn.viabilityUpdateHandler = { [weak self, weak conn] viable in
            Task { @MainActor [weak self, weak conn] in
                guard let self, let conn, self.connection === conn else { return }
                guard self.isConnected || self.isStreaming else { return }

                guard !viable else {
                    // Recovered — cancel any pending teardown and say so, since
                    // a flap that never becomes a drop is otherwise invisible.
                    if self.pendingViabilityTeardown != nil {
                        self.pendingViabilityTeardown?.cancel()
                        self.pendingViabilityTeardown = nil
                        TBLog.connection.notice("connect: path recovered; teardown cancelled (flap, not a drop)")
                    }
                    return
                }

                guard self.pendingViabilityTeardown == nil else { return }
                TBLog.connection.notice("connect: path non-viable; confirming over \(Self.viabilityGrace, privacy: .public)s before tearing down")
                let work = DispatchWorkItem { [weak self, weak conn] in
                    MainActor.assumeIsolated {
                        guard let self, let conn, self.connection === conn else { return }
                        self.pendingViabilityTeardown = nil
                        guard self.isConnected || self.isStreaming else { return }
                        TBLog.connection.notice("connect: still non-viable; link is gone, tearing down")
                        self.stop(resetStatusTo: .connectionFailed("Link lost — cable or interface went away"))
                    }
                }
                self.pendingViabilityTeardown = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.viabilityGrace, execute: work)
            }
        }

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor [weak self, weak conn] in
                guard let self, let conn, self.connection === conn else { return }
                switch state {
                case .ready:
                    TBTelemetryReporter.emit("connect: ready")
                    self.connectTimeoutWorkItem?.cancel()
                    self.connectTimeoutWorkItem = nil
                    self.isConnected = true
                    TBLog.connection.info("connect: ready — \(self.receiverIP, privacy: .public) via \(self.connectInterfaceName ?? "?", privacy: .public)")
                    self.setStatus(.waitingDisplayProfile)
                    self.startHeartbeat()
                    self.sendHello()
                    self.sendInputControlModeUpdate()
                    self.sendBrightnessUpdate()
                    self.sendVolumeUpdate()
                    self.receiveLoop(on: conn)
                case .waiting(let error):
                    // The dial cannot proceed yet (no route, host down, cable
                    // unplugged, firewall drop, …). Record and log the real
                    // reason so a later timeout can report it instead of a
                    // bare "Connection timed out".
                    TBTelemetryReporter.emit("connect: waiting — \(error)")
                    self.lastConnectionStateDetail = "waiting(\(error.localizedDescription))"
                    TBLog.connection.warning("connect: waiting — \(error.localizedDescription, privacy: .public)")
                case .failed(let error):
                    TBTelemetryReporter.emit("connect: FAILED — \(error)")
                    self.lastConnectionStateDetail = "failed(\(error.localizedDescription))"
                    let detail = TBConnectionDiagnostics.failureDetail(
                        receiverHost: self.receiverIP,
                        port: TBMonitorProtocol.port,
                        localIP: self.localInterfaceIP,
                        interfaceName: self.connectInterfaceName,
                        transport: self.transportKind.rawValue,
                        lastNetworkState: nil
                    )
                    TBLog.connection.error("connect: failed — \(error.localizedDescription, privacy: .public); \(detail, privacy: .public)")
                    self.setStatus(.connectionFailed("\(error.localizedDescription) — \(detail)"))
                    self.stop(resetStatusTo: nil)
                case .cancelled:
                    // Clear the object, not just the flag.
                    //
                    // This used to set isConnected = false and stop. The UI then
                    // showed "disconnected" while `connection` was still non-nil,
                    // and connect()'s guard turned every later press into a silent
                    // no-op that only an app relaunch cleared. Whether this path is
                    // reachable without stop() having already run is unproven --
                    // but a state that strands the Connect button must not depend
                    // on that being impossible.
                    self.isConnected = false
                    if self.connection != nil {
                        TBTelemetryReporter.emit(
                            "connection cancelled outside teardown — clearing it")
                        self.stop(resetStatusTo: nil)
                    }
                default:
                    break
                }
            }
        }

        startConnectWatchdog()
        // Report exactly what we dial, so a failure can be compared against a
        // probe rather than reasoned about. Every isolated difference (params,
        // bundle id, host form, literal vs string) has been measured to work, so
        // the remaining variable is what THIS call actually receives.
        TBTelemetryReporter.emit(
            "connect: dialing host=\(dialHost) port=\(TBMonitorProtocol.port) "
            + "scoped=\(scopedHost) local=\(localInterfaceIP) "
            + "iface=\(connectInterfaceName ?? "nil") transport=\(transportKind.rawValue) "
            + "pin=\(params.requiredLocalEndpoint != nil)")
        conn.start(queue: connectionQueue)
    }

    func startCableTest() {
        guard !isCableTesting, !isConnected, !receiverIP.isEmpty else { return }
        isCableTesting = true
        cableTestResult = nil
        cableTestDetail = nil
        isCableTestConnection = true
        connect()
    }

    /// Runs the throughput test. With dual cable configured, both links are
    /// driven **concurrently** so the result reflects what the pair can carry
    /// together — a sequential test would just measure each cable twice and
    /// miss any shared ceiling (driver locks, host bus) that only appears
    /// under simultaneous load.
    private func performCableTest() async throws -> Double {
        guard let primary = connection else {
            throw NSError(domain: "TBDisplaySenderService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No connection"])
        }

        let rate = try await pushCableTestBytes(on: primary, totalBytes: 20 * 1000 * 1000 * 1000)
        cableTestDetail = nil
        return rate
    }

    /// Push `totalBytes` down the link as fast as it will accept them and
    /// return the achieved rate in Gb/s.
    private func pushCableTestBytes(on conn: NWConnection, totalBytes: Int64) async throws -> Double {
        let chunkSize = 4 * 1000 * 1000
        let totalChunks = Int(totalBytes / Int64(chunkSize))

        // Pre-allocate the single test packet to avoid memory overhead
        var packet = Data()
        TBMonitorProtocol.appendBE32(&packet, UInt32(1 + chunkSize))
        packet.append(TBMonitorPacketType.testData.rawValue)
        packet.append(Data(repeating: 0, count: chunkSize))

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let startTime = DispatchTime.now()
                let condition = NSCondition()

                let lock = NSLock()
                var sendError: Error?
                var resumed = false
                var inFlightCount = 0

                func finish(with error: Error?) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        let endTime = DispatchTime.now()
                        let nanoTime = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
                        let timeInSeconds = Double(nanoTime) / 1_000_000_000.0

                        // 20 GB = 20,000,000,000 bytes = 160,000,000,000 bits
                        // Decimal Gigabits = bits / 1,000,000,000
                        let totalBits = Double(totalBytes) * 8.0
                        let rate = totalBits / 1_000_000_000.0 / timeInSeconds
                        continuation.resume(returning: rate)
                    }
                }

                for _ in 0..<totalChunks {
                    lock.lock()
                    let err = sendError
                    lock.unlock()
                    if err != nil {
                        break
                    }

                    condition.lock()
                    while inFlightCount >= 8 {
                        lock.lock()
                        let errCheck = sendError
                        lock.unlock()
                        if errCheck != nil {
                            break
                        }
                        condition.wait()
                    }

                    lock.lock()
                    let errCheck2 = sendError
                    lock.unlock()
                    if errCheck2 != nil {
                        condition.unlock()
                        break
                    }

                    inFlightCount += 1
                    condition.unlock()

                    conn.send(content: packet, completion: .contentProcessed({ error in
                        if let error = error {
                            lock.lock()
                            if sendError == nil {
                                sendError = error
                            }
                            lock.unlock()
                        }

                        condition.lock()
                        inFlightCount -= 1
                        condition.broadcast()
                        condition.unlock()
                    }))
                }

                // Wait for all outstanding packets to complete (up to 3 seconds)
                let limitDate = Date().addingTimeInterval(3.0)
                condition.lock()
                while inFlightCount > 0 {
                    if !condition.wait(until: limitDate) {
                        break // Timed out
                    }
                }
                condition.unlock()

                lock.lock()
                let err = sendError
                lock.unlock()

                finish(with: err)
            }
        }
    }

    func stop(persistArrangement: Bool = true) {
        stop(resetStatusTo: .stopped, persistArrangement: persistArrangement)
    }

    func persistExtendedDisplayArrangementSnapshot() {
        persistExtendedDisplayArrangementIfNeeded()
    }

    private func stop(resetStatusTo status: TBDisplaySenderStatusState?, persistArrangement: Bool = true) {
        if persistArrangement {
            persistExtendedDisplayArrangementIfNeeded()
        }
        sendTeardown(reason: "sender_stop")
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        stopCaptureWatchdog()
        if let directDisplayStream {
            directDisplayStream.stop()
            self.directDisplayStream = nil
        }
        if let stream = scStream {
            if let delegate = captureDelegate {
                try? stream.removeStreamOutput(delegate, type: .screen)
                try? stream.removeStreamOutput(delegate, type: .audio)
            }
            stream.stopCapture(completionHandler: nil)
            scStream = nil
        }
        captureDelegate = nil
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
        stopAudioDeviceCapture()
        keepWarm.stop()
        pipeline?.stop()
        pipeline = nil
        releaseInjectedModifiersIfNeeded()
        remoteHeldModifierKeyCodes.removeAll()
        injectedLeftClickTracker.reset()
        suppressedTriggerKeyCode = nil
        connection?.stateUpdateHandler = nil
        // Cleared with the state handler, not left dangling: cancel() drives the
        // path non-viable on its way down, and a live handler would re-enter
        // teardown from inside teardown.
        connection?.viabilityUpdateHandler = nil
        pendingViabilityTeardown?.cancel()
        pendingViabilityTeardown = nil
        connection?.cancel()
        connection = nil
        let currentSession = session
        Task { @MainActor in
            currentSession.destroy()
        }
        activeProfile = nil
        activeCodecType = nil
        activeCodecName = nil
        isConnected = false
        isStreaming = false
        isCableTesting = false
        isCableTestConnection = false
        if let status {
            setStatus(status)
        }
        refreshLocalizedText()
        liveMetrics.senderFPS = 0
        sentSnapshot = 0
        sessionAckSent = false
        baselineDisplayIDs = []
        cursorDisplayID = kCGNullDirectDisplay
        lastCursorPacket = nil
        captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
    }

    /// Stable per-receiver discriminator: the connection address when known
    /// (distinct per machine even when two identical iMacs report the same SDL
    /// display name), falling back to the receiver-reported name.
    private func receiverIdentityDiscriminator(for profile: TBMonitorDisplayProfile) -> String {
        let trimmedIP = receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedIP.isEmpty ? profile.receiverName : trimmedIP
    }

    /// Key used to derive the extended-desktop virtual display identity. Shares
    /// the same receiver discriminator as the saved-arrangement key so a given
    /// receiver maps to one stable virtual display identity across reconnects.
    private func extendedDisplayIdentityKey(for profile: TBMonitorDisplayProfile) -> String {
        "\(receiverIdentityDiscriminator(for: profile))|\(profile.panelWidth)x\(profile.panelHeight)"
    }

    private func extendedArrangementDefaultsKey(for profile: TBMonitorDisplayProfile) -> String {
        let normalizedIdentity = receiverIdentityDiscriminator(for: profile).replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        return "\(Self.extendedArrangementDefaultsPrefix).\(normalizedIdentity).\(profile.panelWidth)x\(profile.panelHeight)"
    }

    private func loadSavedExtendedDisplayArrangement(for profile: TBMonitorDisplayProfile) -> SavedExtendedDisplayArrangement? {
        let key = extendedArrangementDefaultsKey(for: profile)
        guard let stored = UserDefaults.standard.dictionary(forKey: key) else {
            return nil
        }

        if let dx = stored["dx"] as? Int,
           let dy = stored["dy"] as? Int {
            return SavedExtendedDisplayArrangement(
                x: Int32(dx),
                y: Int32(dy),
                isRelativeToMainDisplay: true
            )
        }

        guard let x = stored["x"] as? Int,
              let y = stored["y"] as? Int
        else {
            return nil
        }
        return SavedExtendedDisplayArrangement(
            x: Int32(x),
            y: Int32(y),
            isRelativeToMainDisplay: false
        )
    }

    private func persistExtendedDisplayArrangementIfNeeded() {
        guard captureSource == .extendedDesktop,
              let profile = activeProfile,
              session.displayID != kCGNullDirectDisplay,
              CGDisplayIsInMirrorSet(session.displayID) == 0
        else { return }

        let bounds = CGDisplayBounds(session.displayID)
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let key = extendedArrangementDefaultsKey(for: profile)
        let payload: [String: Int] = [
            "dx": Int((bounds.origin.x - mainBounds.origin.x).rounded()),
            "dy": Int((bounds.origin.y - mainBounds.origin.y).rounded()),
            "x": Int(bounds.origin.x.rounded()),
            "y": Int(bounds.origin.y.rounded())
        ]
        UserDefaults.standard.set(payload, forKey: key)
    }

    private func sendHello() {
        let name = Host.current().localizedName ?? "MacBook"
        let preset = capturePreset
        let helloCodecType = resolvedCodecType(for: preset, profile: activeProfile)
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .helloReceiver,
            value: TBMonitorHelloReceiver(
                senderName: name,
                uiLanguage: language.fileStem,
                capturePreset: preset.title,
                captureSource: captureSource.title(language),
                captureWidth: preset.width,
                captureHeight: preset.height,
                codec: codecName(for: helloCodecType),
                audioFormat: receiverSupportsFloat32Audio ? "f32" : "s16"
            )
        ) else {
            // A hello that fails to encode is the whole session: the receiver
            // waits for it, never gets it, and the link dies ~100ms in looking
            // like a network fault. Say so rather than returning in silence.
            TBTelemetryReporter.emit("hello: FAILED to encode — session cannot start")
            TBLog.connection.error("hello: failed to encode — the receiver will never see it")
            return
        }
        TBTelemetryReporter.emit("hello: sending \(packet.count) bytes")
        send(packet)
    }

    private func sendInputControlModeUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .inputControlMode,
            value: TBMonitorInputControlMode(mode: inputControlRole.rawValue)
        ) else { return }
        TBInputDebugLog.log("sender send control mode update \(inputControlRole.rawValue) to \(receiverIP)")
        send(packet)
    }

    private func sendBrightnessUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .brightness,
            value: TBMonitorBrightness(level: brightness)
        ) else { return }
        send(packet)
    }

    private func applyReportedDisplayTweaks(_ tweaks: TBMonitorDisplayTweaks) {
        // vsync is deliberately absent here: the receiver reports the two panel
        // features it can read back from the hardware, and echoing our own vsync
        // choice would be a round trip that can only lose information.
        guard nightShiftEnabled != tweaks.nightShift || trueToneEnabled != tweaks.trueTone else { return }
        adoptingReportedTweaks = true
        nightShiftEnabled = tweaks.nightShift
        trueToneEnabled = tweaks.trueTone
        adoptingReportedTweaks = false
    }

    private func sendDisplayTweaks() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .displayTweaks,
            value: TBMonitorDisplayTweaks(nightShift: nightShiftEnabled,
                                          trueTone: trueToneEnabled,
                                          vsync: vsyncEnabled)
        ) else { return }
        send(packet)
    }

    private func sendVolumeUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .volume,
            value: TBMonitorVolume(level: volume)
        ) else { return }
        send(packet)
    }

    func sendClipboardText(_ text: String) {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .clipboard,
            value: TBMonitorClipboard(text: text)
        ) else { return }
        send(packet)
    }

    private func sendHeartbeat() {
        heartbeatSequence += 1
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .heartbeat,
            value: TBMonitorHeartbeat(sequence: heartbeatSequence)
        ) else { return }
        send(packet)
    }

    private func sendTeardown(reason: String) {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .teardown,
            value: TBMonitorTeardown(reason: reason)
        ) else { return }
        send(packet)
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isDone, error in
            Task { @MainActor [weak self] in
                // A receive completion for a connection we have already replaced is
                // stale and must not touch current state -- but say so, because a
                // teardown that arrives here is a teardown nobody performs.
                guard let self else { return }
                guard self.connection === connection else {
                    if isDone || error != nil {
                        TBTelemetryReporter.emit(
                            "receive: EOF/error for a superseded connection — ignored")
                    }
                    return
                }
                if let data, !data.isEmpty {
                    self.recvBuffer.append(data)
                    self.drainPackets()
                }
                if error != nil || isDone {
                    // Record which end hung up and in what state. A clean EOF
                    // (isDone, no error) during the handshake is the signature
                    // seen in the receiver's log -- connected, profile sent,
                    // hello never seen, gone ~100ms later -- and without this
                    // line the sender's account of it is a bare status change.
                    TBTelemetryReporter.emit(
                        "receive: ended — isDone=\(isDone) error=\(error.map { "\($0)" } ?? "none") "
                        + "status=\(self.statusState) bytesBuffered=\(self.recvBuffer.count)")
                    TBLog.connection.error(
                        "receive: ended isDone=\(isDone, privacy: .public) error=\(error?.localizedDescription ?? "none", privacy: .public)")
                    if let error {
                        self.setStatus(.connectionClosed(error.localizedDescription))
                    } else if case .startingCapture = self.statusState {
                        self.setStatus(.receiverClosedDuringCapture)
                    } else if case .captureActive = self.statusState {
                        self.setStatus(.receiverClosedConnection)
                    }
                    self.stop(resetStatusTo: nil)
                    return
                }
                self.receiveLoop(on: connection)
            }
        }
    }

    private func drainPackets() {
        do {
            try drainPacketsOrThrow()
        } catch {
            // Corrupt length prefix: the framing is unrecoverable, so tear the
            // connection down instead of buffering inbound data forever.
            TBLog.connection.error("corrupt inbound stream (\(String(describing: error), privacy: .public)); closing connection")
            recvBuffer.removeAll(keepingCapacity: false)
            setStatus(.connectionClosed(String(describing: error)))
            stop(resetStatusTo: nil)
        }
    }

    private func drainPacketsOrThrow() throws {
        while let (type, payload) = try TBMonitorProtocol.drainPacket(from: &recvBuffer) {
            switch type {
            case .displayProfile:
                handleDisplayProfile(payload)
            case .inputEvent:
                if inputControlRole == .receiverMaster,
                   let event = TBMonitorProtocol.decodeJSON(TBMonitorInputEvent.self, from: payload) {
                    receivedInputEventCount += 1
                    if receivedInputEventCount <= 20 || receivedInputEventCount.isMultiple(of: 100) {
                        TBInputDebugLog.log("sender received #\(receivedInputEventCount) kind=\(event.kind) dx=\(event.dx ?? 0) dy=\(event.dy ?? 0) sx=\(event.scrollX ?? 0) sy=\(event.scrollY ?? 0) key=\(event.keyCode ?? 0)")
                    }
                    if event.kind == "switchPrevTarget" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteSwitchRequest?(-1)
                    } else if event.kind == "switchNextTarget" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteSwitchRequest?(1)
                    } else if event.kind == "switchPrevSpace" {
                        releaseInjectedModifiersIfNeeded()
                        postLocalSpaceSwitch(direction: -1)
                    } else if event.kind == "switchNextSpace" {
                        releaseInjectedModifiersIfNeeded()
                        postLocalSpaceSwitch(direction: 1)
                    } else if event.kind == "deactivateInputControl" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteDeactivateInputRequest?()
                    } else {
                        applyIncomingInputEvent(event)
                    }
                }
            case .heartbeat:
                break
            case .teardown:
                setStatus(.receiverTerminatedSession)
                stop(resetStatusTo: nil)
                return
            case .micFrame:
                // Receiver's microphone. Straight into the driver's input
                // stream; already 48 kHz stereo Int16, so nothing to convert.
                if micForwarder == nil { micForwarder = TBMicForwarder() }
                micForwarder?.forward(payload)
            case .receiverLog:
                TBReceiverLogSink.shared.append(payload)
            case .phaseReport:
                handlePhaseReport(payload)
            case .displayTweaks:
                // Receiver reporting its real state (it may have been changed on
                // that Mac directly). Adopt it without sending anything back —
                // the didSet observers would otherwise bounce it straight to the
                // receiver and the two could ping-pong.
                if let tweaks = TBMonitorProtocol.decodeJSON(TBMonitorDisplayTweaks.self, from: payload) {
                    applyReportedDisplayTweaks(tweaks)
                }
            case .clipboard:
                if let clipboard = TBMonitorProtocol.decodeJSON(TBMonitorClipboard.self, from: payload) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(clipboard.text, forType: .string)
                }
            default:
                break
            }
        }
    }

    /// One phase report from the receiver: its mean `nextDrawable` wait.
    /// Decodes and forwards; the controller lives in `TBVideoPipeline`, which owns
    /// the schedule it acts on.
    private func handlePhaseReport(_ payload: Data) {
        guard payload.count >= 8 else { return }
        let b = [UInt8](payload)
        // Assembled byte by byte rather than loaded as a UInt32: the payload sits
        // at an arbitrary offset inside the receive buffer, so it carries no
        // alignment guarantee, and this also states the endianness outright.
        let meanUs = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16)
                   | (UInt32(b[2]) << 8)  |  UInt32(b[3])
        let samples = (UInt32(b[4]) << 24) | (UInt32(b[5]) << 16)
                    | (UInt32(b[6]) << 8)  |  UInt32(b[7])
        guard samples > 0 else { return }
        pipeline?.notePhaseReport(meanMs: Double(meanUs) / 1000.0, samples: samples)
    }

    private func currentLocalMouseLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    // Bounds of every active display, in the Quartz global coordinate space
    // (top-left origin) — matching CGEvent locations and CGWarpMouseCursorPosition.
    // NSScreen.frame uses AppKit's bottom-left origin and must not be mixed in here.
    private func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private func screenFrame(containing point: CGPoint) -> CGRect? {
        activeDisplayBounds().first(where: { $0.contains(point) })
    }

    private func clampedMouseTarget(from current: CGPoint, dx: Int, dy: Int) -> CGPoint {
        let rawTarget = CGPoint(x: current.x + CGFloat(dx), y: current.y + CGFloat(dy))
        let displays = activeDisplayBounds()
        guard !displays.isEmpty else { return rawTarget }

        // If the target lands on any display, allow it unchanged. This lets the
        // relayed cursor cross from one screen onto an adjacent one (e.g. the
        // receiver-backed virtual extended display), matching how the pointer
        // behaves with the local touchpad. Clamping to a single screen's bounds
        // previously trapped the pointer on the sender's main display (issue #97).
        if displays.contains(where: { $0.contains(rawTarget) }) {
            return rawTarget
        }

        // Off every display: keep the pointer on the display it is currently on so
        // the injected cursor can never get lost in a gap between displays.
        let frame = displays.first(where: { $0.contains(current) }) ?? displays[0]
        let minX = frame.minX
        let maxX = frame.maxX - 1
        let minY = frame.minY
        let maxY = frame.maxY - 1

        return CGPoint(
            x: min(max(rawTarget.x, minX), maxX),
            y: min(max(rawTarget.y, minY), maxY)
        )
    }

    private func localInputEventSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }

    private func logLocalInputInjectionStateIfNeeded(context: String) {
        let trusted = AXIsProcessTrusted()
        TBInputDebugLog.log("sender input injection state trusted=\(trusted) context=\(context)")
    }

    private func postLocalMouseMove(dx: Int, dy: Int, type: CGEventType = .mouseMoved, button: CGMouseButton = .left) {
        logLocalInputInjectionStateIfNeeded(context: "mouseMove")
        guard let current = injectedRemoteMouseLocation ?? currentLocalMouseLocation() else { return }
        let target = clampedMouseTarget(from: current, dx: dx, dy: dy)
        injectedRemoteMouseLocation = target
        let shouldWarp = (type == .mouseMoved)
        if shouldWarp {
            CGWarpMouseCursorPosition(target)
        }
        guard let event = CGEvent(mouseEventSource: localInputEventSource(), mouseType: type, mouseCursorPosition: target, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)

        // Auto-hidden menu bar / Dock reveal on macOS depends on the pointer
        // really landing on a screen edge. A second edge-pinned move helps the
        // system treat relayed motion like a native "push against the border".
        if type == .mouseMoved,
           let frame = screenFrame(containing: target),
           target.x <= frame.minX || target.x >= frame.maxX - 1 ||
           target.y <= frame.minY || target.y >= frame.maxY - 1,
           let edgeEvent = CGEvent(mouseEventSource: localInputEventSource(), mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: button) {
            edgeEvent.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
            edgeEvent.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
            edgeEvent.post(tap: .cghidEventTap)
        }
    }

    private func postLocalMouseButton(type: CGEventType, button: CGMouseButton) {
        logLocalInputInjectionStateIfNeeded(context: "mouseButton")
        guard let current = injectedRemoteMouseLocation ?? currentLocalMouseLocation() else { return }
        guard let event = CGEvent(mouseEventSource: localInputEventSource(), mouseType: type, mouseCursorPosition: current, mouseButton: button) else { return }
        if button == .left {
            let clickState: Int
            if type == .leftMouseDown {
                clickState = injectedLeftClickTracker.registerClick(
                    at: current,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    doubleClickInterval: NSEvent.doubleClickInterval
                )
            } else {
                clickState = max(injectedLeftClickTracker.currentClickState, 1)
            }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.post(tap: .cghidEventTap)
    }

    private func postLocalScroll(scrollX: Int, scrollY: Int) {
        logLocalInputInjectionStateIfNeeded(context: "scroll")
        guard let event = CGEvent(
            scrollWheelEvent2Source: localInputEventSource(),
            units: .line,
            wheelCount: 2,
            wheel1: Int32(scrollY),
            wheel2: Int32(scrollX),
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postLocalKey(keyCode: UInt16, isDown: Bool) {
        logLocalInputInjectionStateIfNeeded(context: "key")
        switch keyCode {
        case 54, 55: injectedCommandDown = isDown
        case 56, 60: injectedShiftDown = isDown
        case 58, 61: injectedOptionDown = isDown
        case 59, 62: injectedControlDown = isDown
        case 57: injectedCapsDown = isDown
        default: break
        }
        guard let event = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(keyCode), keyDown: isDown) else { return }
        event.flags = currentInjectedModifierFlags()
        event.post(tap: .cghidEventTap)
    }

    private func currentInjectedModifierFlags() -> CGEventFlags {
        var flags: CGEventFlags = []
        if injectedCommandDown {
            flags.insert(.maskCommand)
        }
        if injectedShiftDown {
            flags.insert(.maskShift)
        }
        if injectedOptionDown {
            flags.insert(.maskAlternate)
        }
        if injectedControlDown {
            flags.insert(.maskControl)
        }
        if injectedCapsDown {
            flags.insert(.maskAlphaShift)
        }
        return flags
    }

    private func releaseInjectedModifiersIfNeeded() {
        if injectedCommandDown {
            postLocalKey(keyCode: 55, isDown: false)
            injectedCommandDown = false
        }
        if injectedShiftDown {
            postLocalKey(keyCode: 56, isDown: false)
            injectedShiftDown = false
        }
        if injectedOptionDown {
            postLocalKey(keyCode: 58, isDown: false)
            injectedOptionDown = false
        }
        if injectedControlDown {
            postLocalKey(keyCode: 59, isDown: false)
            injectedControlDown = false
        }
        if injectedCapsDown {
            postLocalKey(keyCode: 57, isDown: false)
            injectedCapsDown = false
        }
    }

    private func postLocalSpaceSwitch(direction: Int) {
        logLocalInputInjectionStateIfNeeded(context: "spaceSwitch")

        let controlKeyCode: UInt16 = 59
        let arrowKeyCode: UInt16 = direction < 0 ? 123 : 124

        guard let controlDown = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(controlKeyCode), keyDown: true),
              let arrowDown = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(arrowKeyCode), keyDown: true),
              let arrowUp = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(arrowKeyCode), keyDown: false),
              let controlUp = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(controlKeyCode), keyDown: false)
        else {
            return
        }

        controlDown.flags = .maskControl
        arrowDown.flags = .maskControl
        arrowUp.flags = .maskControl
        controlUp.flags = []

        controlDown.post(tap: .cghidEventTap)
        arrowDown.post(tap: .cghidEventTap)
        arrowUp.post(tap: .cghidEventTap)
        controlUp.post(tap: .cghidEventTap)
    }

    private func applyIncomingInputEvent(_ event: TBMonitorInputEvent) {
        TBInputDebugLog.log("sender applying incoming event kind=\(event.kind)")
        switch event.kind {
        case "move":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0)
        case "leftDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .leftMouseDragged, button: .left)
        case "rightDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .rightMouseDragged, button: .right)
        case "otherDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .otherMouseDragged, button: .center)
        case "leftDown":
            postLocalMouseButton(type: .leftMouseDown, button: .left)
        case "leftUp":
            postLocalMouseButton(type: .leftMouseUp, button: .left)
        case "rightDown":
            postLocalMouseButton(type: .rightMouseDown, button: .right)
        case "rightUp":
            postLocalMouseButton(type: .rightMouseUp, button: .right)
        case "otherDown":
            postLocalMouseButton(type: .otherMouseDown, button: .center)
        case "otherUp":
            postLocalMouseButton(type: .otherMouseUp, button: .center)
        case "scroll":
            postLocalScroll(scrollX: event.scrollX ?? 0, scrollY: event.scrollY ?? 0)
        case "keyDown":
            if let keyCode = event.keyCode {
                updateRemoteModifierState(keyCode: keyCode, isDown: true)
                if handleIncomingTriggerKeyDown(keyCode) { return }
                postLocalKey(keyCode: keyCode, isDown: true)
            }
        case "keyUp":
            if let keyCode = event.keyCode {
                updateRemoteModifierState(keyCode: keyCode, isDown: false)
                if keyCode == suppressedTriggerKeyCode {
                    suppressedTriggerKeyCode = nil
                    return
                }
                postLocalKey(keyCode: keyCode, isDown: false)
            }
        default:
            break
        }
    }

    /// receiverMaster: if the incoming key-down completes a binding trigger,
    /// inject the action locally and swallow the trigger. Returns true if handled.
    private func handleIncomingTriggerKeyDown(_ keyCode: UInt16) -> Bool {
        guard !TBInputBindingEngine.isModifierKeyCode(keyCode), !inputBindings.isEmpty else { return false }
        // Debounce key-repeat: ignore repeats while the trigger is still held.
        if keyCode == suppressedTriggerKeyCode { return true }
        let held = currentHeldModifierBits()
        guard let binding = TBInputBindingEngine.match(keyCode: keyCode, modifiers: held, in: inputBindings) else {
            return false
        }
        suppressedTriggerKeyCode = keyCode
        TBInputDebugLog.log("binding MATCH: trigger=\(binding.trigger.displayString) -> inject \(binding.action.displayString)")
        injectActionViaSystemEvents(binding.action)
        return true
    }

    /// Inject a binding action through System Events (AppleScript) rather than a
    /// raw CGEvent. The WindowServer ignores synthetic CGEvent presses for
    /// protected symbolic hotkeys (e.g. ⌃← to switch Spaces), but honors the same
    /// shortcut when it comes from the trusted System Events process.
    ///
    /// The user may be holding the trigger's modifiers, which we inject as held
    /// CGEvent state — that would contaminate the action (e.g. a stray ⌥). So we
    /// release the held modifiers first so System Events sees a clean combo. On
    /// completion, restore only modifiers that the receiver still holds.
    private func injectActionViaSystemEvents(_ action: TBInputShortcut) {
        let heldKeyCodes = currentlyHeldRemoteModifierKeyCodes()
        for keyCode in heldKeyCodes { postLocalKey(keyCode: keyCode, isDown: false) }

        // Run the AppleScript in-process (NSAppleScript), NOT via /usr/bin/osascript:
        // when spawned, osascript is the keystroke-sending client and lacks
        // Accessibility (error 1002). In-process, this app is the client and it
        // already holds Accessibility + Automation, so System Events is allowed
        // to post the shortcut.
        let source = "tell application \"System Events\" to key code \(action.keyCode)\(Self.appleScriptModifierClause(action.modifiers))"
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            let failure: String? = errorInfo.map { "\($0)" }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let failure { TBInputDebugLog.log("system-events inject error: \(failure)") }
                guard self.inputControlRole == .receiverMaster else { return }
                for keyCode in self.currentlyHeldRemoteModifierKeyCodes() {
                    self.postLocalKey(keyCode: keyCode, isDown: true)
                }
            }
        }
    }

    private func updateRemoteModifierState(keyCode: UInt16, isDown: Bool) {
        guard TBInputBindingEngine.modifierBit(for: keyCode) != nil else { return }
        if isDown {
            remoteHeldModifierKeyCodes.insert(keyCode)
        } else {
            remoteHeldModifierKeyCodes.remove(keyCode)
        }
    }

    private func currentlyHeldRemoteModifierKeyCodes() -> [UInt16] {
        TBInputShortcut.modifierTable.compactMap { modifier in
            remoteHeldModifierKeyCodes.first {
                TBInputBindingEngine.modifierBit(for: $0) == modifier.bit
            }
        }
    }

    private static func appleScriptModifierClause(_ modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & TBInputShortcut.control != 0 { parts.append("control down") }
        if modifiers & TBInputShortcut.option  != 0 { parts.append("option down") }
        if modifiers & TBInputShortcut.shift   != 0 { parts.append("shift down") }
        if modifiers & TBInputShortcut.command != 0 { parts.append("command down") }
        guard !parts.isEmpty else { return "" }
        return " using {" + parts.joined(separator: ", ") + "}"
    }

    /// Current held modifier state (our bitmask) reconstructed from injected keys.
    private func currentHeldModifierBits() -> UInt32 {
        var m: UInt32 = 0
        if injectedControlDown { m |= TBInputShortcut.control }
        if injectedOptionDown  { m |= TBInputShortcut.option }
        if injectedShiftDown   { m |= TBInputShortcut.shift }
        if injectedCommandDown { m |= TBInputShortcut.command }
        return m
    }

    private func handleDisplayProfile(_ payload: Data) {
        guard activeProfile == nil,
              let profile = TBMonitorProtocol.decodeJSON(TBMonitorDisplayProfile.self, from: payload)
        else { return }

        activeProfile = profile
        if let supportsHEVCDecode = profile.supportsHEVCDecode {
            receiverSupportsHEVCDecodeHint = supportsHEVCDecode
        }
        if let inputMonitoringTrusted = profile.inputMonitoringTrusted {
            receiverInputMonitoringTrustedHint = inputMonitoringTrusted
        }
        if let accessibilityTrusted = profile.accessibilityTrusted {
            receiverAccessibilityTrustedHint = accessibilityTrusted
        }
        // Receivers predating the Float32 audio change do not advertise it, and
        // would play float samples as noise. Fall back to Int16 for them rather
        // than requiring both ends to be updated together.
        receiverSupportsFloat32Audio = profile.supportsFloat32Audio ?? false
        audioConverter.setFloatOutput(receiverSupportsFloat32Audio)
        // The profile normally arrives before the pipeline is built, so the
        // value is stored and applied at construction; the optional assignment
        // covers a profile that turns up on an already-running pipeline.
        receiverSupportsDPCM = profile.supportsDPCM ?? false
        receiverSupportsDPCMSlices = profile.supportsDPCMSlices ?? false
        pipeline?.dpcmEnabled = receiverSupportsDPCM
        pipeline?.dpcmSlicesEnabled = receiverSupportsDPCMSlices
        TBLog.connection.info("receiver caps: dpcm=\(self.receiverSupportsDPCM, privacy: .public) slices=\(self.receiverSupportsDPCMSlices, privacy: .public) float32Audio=\(self.receiverSupportsFloat32Audio, privacy: .public)")
        // The shipped-log file is a rolling record across sessions, so mark
        // where this one starts; without it a reader cannot tell one run's
        // output from the next.
        TBReceiverLogSink.shared.noteSessionStart("session with \(profile.receiverName)")
        receiverSupportsNightShift = profile.supportsNightShift ?? false
        receiverSupportsTrueTone = profile.supportsTrueTone ?? false
        receiverPanelText = TBDisplaySenderL10n.receiverSummary(profile, language: language)
        sendHello()
        sendInputControlModeUpdate()
        sendBrightnessUpdate()
        sendVolumeUpdate()

        Task { @MainActor in
            if self.isCableTestConnection {
                self.setStatus(.testingCable)
                do {
                    let rate = try await self.performCableTest()
                    self.cableTestResult = rate
                } catch {
                    NSLog("TargetBridge: cable test failed: \(error)")
                    self.stop(resetStatusTo: .connectionFailed(error.localizedDescription))
                    return
                }
                self.isCableTestConnection = false
                self.isCableTesting = false
                self.stop(resetStatusTo: .stopped)
                return
            }

            self.setStatus(.creatingVirtualDisplay)
            self.baselineDisplayIDs = await self.fetchShareableDisplayIDs()
            let receiverKey = self.extendedDisplayIdentityKey(for: profile)
            let modeOverride: TBVirtualDisplayModeSize? = (self.matchRenderToStream && self.captureSource == .extendedDesktop)
                ? self.capturePreset.renderMatchedDisplayMode
                : nil
            if let modeOverride {
                NSLog(
                    "TargetBridge: render matching on, virtual display mode %dx%d (backing %dx%d) for %dx%d stream",
                    modeOverride.width, modeOverride.height,
                    modeOverride.backingWidth, modeOverride.backingHeight,
                    self.capturePreset.width, self.capturePreset.height
                )
            }
            guard self.session.create(
                from: profile,
                refreshRate: self.capturePreset.virtualDisplayRefreshRate,
                modeOverride: modeOverride,
                identity: self.captureSource.virtualDisplayIdentity(receiverKey: receiverKey),
                receiverKey: receiverKey
            ) else {
                self.setStatus(.virtualDisplayCreationFailed)
                self.stop(resetStatusTo: nil)
                return
            }
            if self.captureSource == .desktopMirror {
                let displayReady = await self.waitForOnlineDisplay(self.session.displayID)
                let mirrorConfigured = displayReady && self.configureDesktopMirror(for: self.session.displayID)
                if !mirrorConfigured {
                    NSLog(
                        "TargetBridge: unable to enable mirror mode for virtual display %u on first attempt; scheduling retry",
                        self.session.displayID
                    )
                }
            }
            self.virtualDisplayText = TBDisplaySenderL10n.virtualDisplaySummary(
                name: self.session.displayName,
                id: self.session.displayID,
                language: self.language
            )
            self.displayStateText = self.describeDisplayState(for: self.session.displayID)

            // Reset the first-frame flag BEFORE capture starts. startCapture() is
            // async and frames can begin flowing (firing handleFirstEncodedFrame,
            // which sets sessionAckSent = true) during its suspension. Resetting
            // afterward would clobber that true back to false, leaving the watchdog
            // armed against a session that has already delivered frames — it then
            // tears down a healthy stream ~4s in. See onFirstFrame wiring below.
            self.sessionAckSent = false
            self.setStatus(.startingCapture(self.capturePreset.description, self.captureSource))
            let started = await self.startCapture(for: profile)
            guard started else {
                self.stop(resetStatusTo: nil)
                return
            }

            if self.captureSource == .extendedDesktop {
                self.scheduleExtendedDesktopRecovery(for: self.session.displayID)
            } else if self.captureSource == .desktopMirror {
                self.scheduleDesktopMirrorRecovery(for: self.session.displayID)
            }

            self.setStatus(.captureStartedWaitingFirstFrame)
            self.startFirstFrameWatchdog()
        }
    }

    private func startCapture(for profile: TBMonitorDisplayProfile) async -> Bool {
        do {
            let preset = capturePreset
            let usesRawNV12 = rawNV12Enabled(for: profile)
            let codecType = resolvedCodecType(for: preset, profile: profile)
            // A raw-passthrough preset bypasses the hardware encoder entirely, so
            // naming it after codecType was reporting a codec that never runs —
            // the panel read "(5K, HEVC)" while sending bit-exact 10-bit 4:4:4.
            let codecName = preset.isRawPassthrough
                ? preset.codecName
                : (usesRawNV12 ? "NV12 RAW" : codecName(for: codecType))
            activeCodecType = usesRawNV12 ? nil : codecType
            activeCodecName = codecName
            guard let connection else { return false }

            // The encode/send pipeline runs entirely on its own serial queue,
            // off the main thread, so SwiftUI layout can never stall frame
            // delivery. Preset/dimensions/codec are immutable for a session
            // (the pickers are disabled while streaming), so we capture them once.
            let pipeline = TBVideoPipeline(
                preset: preset,
                codecType: codecType,
                connection: connection,
                displayName: session.displayName,
                displayID: session.displayID,
                usesRawNV12: usesRawNV12,
                ackAlreadySent: sessionAckSent,
                onFirstFrame: { [weak self] in
                    Task { @MainActor in self?.handleFirstEncodedFrame() }
                }
            )
            pipeline.dpcmEnabled = receiverSupportsDPCM
            pipeline.dpcmSlicesEnabled = receiverSupportsDPCMSlices
            guard pipeline.start() else { return false }
            startAudioDeviceCaptureIfNeeded()
            self.pipeline = pipeline
            self.keepWarm.start(displayID: session.displayID)
            TBLog.connection.info("capture: pipeline started preset=\(preset.rawValue, privacy: .public) source=\(String(describing: self.captureSource), privacy: .public) codec=\(codecName, privacy: .public) rawNV12=\(usesRawNV12, privacy: .public)")

            let display: SCDisplay
            if captureSource == .desktopMirror {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                    return false
                }
                display = mainDisplay
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                if session.displayID != kCGNullDirectDisplay,
                   let targetDisplay = content.displays.first(where: { $0.displayID == session.displayID }) {
                    display = targetDisplay
                } else {
                    display = try await waitForCaptureDisplay()
                }
            }

            let configuration = SCStreamConfiguration()
            configuration.width = preset.width
            configuration.height = preset.height
            // A THROTTLE, not a target: it caps how often frames may arrive.
            // Apple's header says "Set this to kCMTimeZero to capture at
            // display's native refresh rate", so asking for 60 was asking SCK
            // to police a 16.67 ms gate with a timer of its own that is not
            // phase-locked to the compositor -- and a frame produced a hair
            // inside that gate can be held or skipped, which is precisely the
            // 2-period gaps in the capture cadence.
            //
            // Presets that deliberately want a LOWER rate keep the throttle;
            // that is what it is for.
            configuration.minimumFrameInterval =
                preset.expectedFrameRate >= 60
                ? .zero
                : CMTime(value: 1, timescale: Int32(preset.expectedFrameRate))
            configuration.queueDepth = preset.queueDepth
            // The preset decides the format. Nothing else.
            //
            // This used to be a conjunction — fullColor444 && tenBit &&
            // isRawPassthrough — with two user toggles feeding it and a silent
            // fall-through to 4:2:0 NV12 if any of them was off. That is three
            // ways to end up subsampled while believing you asked for lossless,
            // and it cost a day: the toggles were both ON and the path still
            // resolved to NV12, which nothing logged. A raw-passthrough preset
            // means lossless 4:4:4 now; there is no other way to configure it,
            // so it cannot half-apply.
            //
            // 10-bit is unconditional on that path because it is free: packed
            // 2-10-10-10 is 4 bytes/pixel, exactly like 8-bit BGRA, so it costs
            // the same bandwidth and the same per-frame work and only removes
            // gradient banding. There was never a reason to offer 8-bit 4:4:4 as
            // a choice — it is strictly worse at identical cost.
            if preset.isRawPassthrough {
                configuration.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
                // Requesting a colour space makes SCK convert, and a conversion
                // computed at 10-bit precision fabricates low-order bits out of
                // 8-bit input — which makes the "is this really 10-bit?" probe
                // meaningless. TB_RAW_NO_COLORSPACE=1 skips it so the captured
                // values are whatever the framebuffer actually holds.
                if ProcessInfo.processInfo.environment["TB_RAW_NO_COLORSPACE"] != "1" {
                    configuration.colorSpaceName = CGColorSpace.displayP3
                }
                // Not requesting EDR capture. It raised the share of pixels with
                // non-zero low bits from ~7% to ~88%, but that is a conversion
                // artefact, not depth: ARGB2101010 is unorm, so extended-range
                // values have to be squeezed into 0...1, which leaves SDR
                // content with *fewer* effective levels and clamps anything
                // above white. Carrying EDR properly would need a float
                // container at 8 bytes/pixel, which buys nothing while the
                // virtual display's framebuffer is 8-bit.
            } else {
                configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }
            // Never let ScreenCaptureKit draw the cursor into the frame.
            //
            // While it did, the cursor WAS the video: it carried the whole
            // pipeline cost — capture, encode, transfer, decode, present, vblank
            // — which is why vsync visibly affected the pointer. The receiver
            // now composites it on its own CALayer instead, so a position
            // reaches the panel without waiting for a frame.
            configuration.showsCursor = false
            configuration.scalesToFit = true
            configuration.captureResolution = preset.captureResolution
            // A selected input device supersedes system capture; capturing both
            // would send two copies of the same sound.
            configuration.capturesAudio = !audioDriverAvailable
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 2

            streamResolutionText = TBDisplaySenderL10n.streamSummary(
                preset: preset,
                source: captureSource,
                language: language,
                codecName: codecName
            )

            let delegate = CaptureDelegate()
            delegate.onFrame = { sampleBuffer in
                pipeline.queue.async { pipeline.encode(sampleBuffer) }
            }
            delegate.onAudio = { [weak self] sampleBuffer in
                self?.processAudio(sampleBuffer)
            }
            delegate.onError = { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.setStatus(.captureError(self.formattedCaptureErrorMessage(for: error)))
                    self.stop(resetStatusTo: nil)
                }
            }
            captureDelegate = delegate

            let filter = SCContentFilter(display: display, excludingWindows: [])
            captureDisplayText = TBDisplaySenderL10n.captureDisplaySCDisplay(language, id: display.displayID)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
            try stream.addStreamOutput(
                delegate,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "fd.tbmonitor.sender.capture", qos: .userInteractive)
            )
            try stream.addStreamOutput(
                delegate,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "fd.tbmonitor.sender.audio", qos: .userInteractive)
            )
            try await stream.startCapture()
            scStream = stream
            isStreaming = true
            // NOT gated on largeCursor. showsCursor is false now, so the
            // capture contains no pointer at all — if this does not start, the
            // receiver has nothing to draw and the screen has no cursor.
            // largeCursor selects sprite SIZE, it does not enable the feature.
            startCursorUpdates(displayID: display.displayID)
            streamingActivity = ProcessInfo.processInfo.beginActivity(
                options: activityOptions(),
                reason: "TargetBridge streaming active"
            )
            startFPSTimer()
            startCaptureWatchdog()
            return true
        } catch {
            if error.localizedDescription.hasPrefix("no virtual SCDisplay available") {
                setStatus(.noShareableDisplay(error.localizedDescription))
            } else {
                setStatus(.captureDesktopError(formattedCaptureErrorMessage(for: error)))
            }
            return false
        }
    }

    private func startDirectDisplayStream(displayID: CGDirectDisplayID, preset: TBDisplayCapturePreset) -> Bool {
        guard let pipeline else { return false }
        let codecName = activeCodecName ?? codecName(for: activeCodecType ?? preset.codecType)
        streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: preset,
            source: captureSource,
            language: language,
            codecName: codecName
        )

        // Deliver frames straight onto the pipeline's own queue — the handler
        // runs there, so encode happens off the main thread with no extra hop.
        let directCapture = TBDirectDisplayStreamCapture(pipeline: pipeline, queue: pipeline.queue)
        guard directCapture.start(displayID: displayID, preset: preset, showCursor: !largeCursor) else {
            return false
        }

        directDisplayStream = directCapture
        captureDisplayText = TBDisplaySenderL10n.captureDisplayCGDisplayStream(language, id: displayID)
        isStreaming = true
        // Not gated on largeCursor — see the SCStream path above.
        startCursorUpdates(displayID: displayID)
        streamingActivity = ProcessInfo.processInfo.beginActivity(
            options: activityOptions(),
            reason: "TargetBridge streaming active"
        )
        startFPSTimer()
        startCaptureWatchdog()
        return true
    }

    private func activityOptions() -> ProcessInfo.ActivityOptions {
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if preventDisplaySleep {
            options.insert(.idleDisplaySleepDisabled)
        }
        return options
    }

    private func waitForCaptureDisplay() async throws -> SCDisplay {
        let targetDisplayID = (captureSource == .desktopMirror) ? CGMainDisplayID() : session.displayID
        return try await waitForVirtualDisplay(
            matching: targetDisplayID,
            baselineDisplayIDs: baselineDisplayIDs
        )
    }

    private func waitForVirtualDisplay(
        matching targetDisplayID: CGDirectDisplayID,
        baselineDisplayIDs: Set<CGDirectDisplayID>
    ) async throws -> SCDisplay {
        enum DisplayLookupError: LocalizedError {
            case notFound(details: String)

            var errorDescription: String? {
                switch self {
                case .notFound(let details):
                    return details
                }
            }
        }

        var lastContent: SCShareableContent?
        for _ in 0..<80 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            lastContent = content
            if let display = content.displays.first(where: { $0.displayID == targetDisplayID }) {
                return display
            }
            if let display = content.displays.first(where: { !baselineDisplayIDs.contains($0.displayID) }) {
                return display
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let content: SCShareableContent
        if let lastContent {
            content = lastContent
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        let availableIDs = content.displays.map { String($0.displayID) }.sorted().joined(separator: ", ")
        let baselineIDs = baselineDisplayIDs.map(String.init).sorted().joined(separator: ", ")
        let onlineIDs = onlineDisplayIDs().map(String.init).sorted().joined(separator: ", ")
        throw DisplayLookupError.notFound(
            details: "no virtual SCDisplay available (target=\(targetDisplayID), baseline=[\(baselineIDs)], available=[\(availableIDs)], online=[\(onlineIDs)])"
        )
    }

    private func fetchShareableDisplayIDs() async -> Set<CGDirectDisplayID> {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return Set(content.displays.map(\.displayID))
        } catch {
            return []
        }
    }

    /// A freshly created virtual display can be reported by CoreGraphics before
    /// it is usable in a display configuration. Waiting briefly avoids racing
    /// `CGConfigureDisplayMirrorOfDisplay` on first connect.
    private func waitForOnlineDisplay(_ displayID: CGDirectDisplayID) async -> Bool {
        for _ in 0..<20 {
            if onlineDisplayIDs().contains(displayID) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return onlineDisplayIDs().contains(displayID)
    }

    /// RAW remains an explicit diagnostic-only transport until a selectable
    /// profile and sustained hardware tests prove it safe for normal sessions.
    /// A Receiver must explicitly advertise support before the environment
    /// override can enable it, so older builds never receive unknown frames.
    private func rawNV12Enabled(for profile: TBMonitorDisplayProfile) -> Bool {
        guard profile.supportsRawNV12 == true else { return false }
        guard let value = ProcessInfo.processInfo.environment["RAW"]?.lowercased() else { return false }
        return value == "1" || value == "true"
    }

    private func configureDesktopMirror(for virtualDisplayID: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            var displayConfig: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&displayConfig) == .success, let cfg = displayConfig else {
                return false
            }

            var completed = false
            defer {
                if !completed {
                    CGCancelDisplayConfiguration(cfg)
                }
            }

            let result = CGConfigureDisplayMirrorOfDisplay(cfg, virtualDisplayID, CGMainDisplayID())
            if result == .success {
                let complete = CGCompleteDisplayConfiguration(cfg, .forSession)
                if complete == .success {
                    completed = true
                    return true
                }
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        return false
    }

    private func scheduleExtendedDesktopRecovery(for virtualDisplayID: CGDirectDisplayID) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            var hasAppliedArrangement = false

            for attempt in 1...12 {
                try? await Task.sleep(nanoseconds: 500_000_000)

                guard self.captureSource == .extendedDesktop,
                      self.session.displayID == virtualDisplayID,
                      self.activeProfile != nil
                else { return }

                // A newly recreated virtual display can already be outside a mirror set
                // while still sitting at macOS's default placement on the right.
                // Force at least one explicit extended-desktop configuration pass so
                // we can reapply the saved arrangement for this receiver.
                if CGDisplayIsInMirrorSet(virtualDisplayID) == 0 && hasAppliedArrangement {
                    self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                    return
                }

                let configured = self.configureExtendedDesktop(for: virtualDisplayID)
                if configured {
                    hasAppliedArrangement = true
                }
                self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                NSLog(
                    "TargetBridge: extended desktop recovery attempt %d for %u configured=%d state=%@",
                    attempt,
                    virtualDisplayID,
                    configured,
                    self.displayStateText
                )

                if configured || (CGDisplayIsInMirrorSet(virtualDisplayID) == 0 && hasAppliedArrangement) {
                    return
                }
            }
        }
    }

    private func scheduleDesktopMirrorRecovery(for virtualDisplayID: CGDirectDisplayID) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 1...12 {
                try? await Task.sleep(nanoseconds: 500_000_000)

                guard self.captureSource == .desktopMirror,
                      self.session.displayID == virtualDisplayID,
                      self.activeProfile != nil
                else { return }

                if CGDisplayIsInMirrorSet(virtualDisplayID) != 0 {
                    self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                    return
                }

                let configured = self.configureDesktopMirror(for: virtualDisplayID)
                self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                NSLog(
                    "TargetBridge: desktop mirror recovery attempt %d for %u configured=%d state=%@",
                    attempt,
                    virtualDisplayID,
                    configured,
                    self.displayStateText
                )

                if configured || CGDisplayIsInMirrorSet(virtualDisplayID) != 0 {
                    return
                }
            }
        }
    }

    private func configureExtendedDesktop(for virtualDisplayID: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            var displayConfig: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&displayConfig) == .success, let cfg = displayConfig else {
                return false
            }

            var completed = false
            defer {
                if !completed {
                    CGCancelDisplayConfiguration(cfg)
                }
            }

            let mainDisplayID = CGMainDisplayID()
            let mainBounds = CGDisplayBounds(mainDisplayID)
            let mainMirrorResult = CGConfigureDisplayMirrorOfDisplay(cfg, mainDisplayID, kCGNullDirectDisplay)
            let virtualMirrorResult = CGConfigureDisplayMirrorOfDisplay(cfg, virtualDisplayID, kCGNullDirectDisplay)
            if mainMirrorResult != .success || virtualMirrorResult != .success {
                NSLog(
                    "TargetBridge: failed to detach mirror set for extended desktop (main=%d virtual=%d)",
                    mainMirrorResult.rawValue,
                    virtualMirrorResult.rawValue
                )
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                continue
            }

            let mainOriginResult = CGConfigureDisplayOrigin(cfg, mainDisplayID, 0, 0)
            let savedArrangement = activeProfile.flatMap { loadSavedExtendedDisplayArrangement(for: $0) }
            let defaultTargetX = Int32((mainBounds.maxX - mainBounds.origin.x).rounded())
            let targetX: Int32
            let targetY: Int32
            if let savedArrangement {
                if savedArrangement.isRelativeToMainDisplay {
                    targetX = Int32(mainBounds.origin.x.rounded()) + savedArrangement.x
                    targetY = Int32(mainBounds.origin.y.rounded()) + savedArrangement.y
                } else {
                    targetX = savedArrangement.x
                    targetY = savedArrangement.y
                }
            } else {
                targetX = defaultTargetX
                targetY = 0
            }
            let originResult = CGConfigureDisplayOrigin(cfg, virtualDisplayID, targetX, targetY)
            if mainOriginResult != .success || originResult != .success {
                NSLog(
                    "TargetBridge: failed to position displays for extended desktop (main=%d virtual=%u targetX=%d targetY=%d result=%d)",
                    mainOriginResult.rawValue,
                    virtualDisplayID,
                    targetX,
                    targetY,
                    originResult.rawValue
                )
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                continue
            }

            let complete = CGCompleteDisplayConfiguration(cfg, .forSession)
            if complete == .success {
                completed = true
                return true
            }
            NSLog(
                "TargetBridge: CGCompleteDisplayConfiguration failed while forcing extended desktop for %u (result=%d)",
                virtualDisplayID,
                complete.rawValue
            )

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        return CGDisplayIsInMirrorSet(virtualDisplayID) == 0
    }

    private func describeDisplayState(for virtualDisplayID: CGDirectDisplayID) -> String {
        let mainDisplayID = CGMainDisplayID()
        let virtualMirror = CGDisplayIsInMirrorSet(virtualDisplayID) != 0
        let mainMirror = CGDisplayIsInMirrorSet(mainDisplayID) != 0
        let virtualMirrors = CGDisplayMirrorsDisplay(virtualDisplayID)
        let mainMirrors = CGDisplayMirrorsDisplay(mainDisplayID)
        let identity = session.identityDescription.isEmpty ? "identity=n/a" : session.identityDescription
        return TBDisplaySenderL10n.displayStateSummary(
            language: language,
            identity: identity,
            virtual: virtualDisplayID,
            virtualMirror: virtualMirror,
            virtualMirrors: virtualMirrors,
            main: mainDisplayID,
            mainMirror: mainMirror,
            mainMirrors: mainMirrors
        )
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
    private func startCursorUpdates(displayID: CGDirectDisplayID) {
        cursorTimer?.invalidate()
        cursorDisplayID = displayID
        lastCursorPacket = nil

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                sendCursorUpdateIfNeeded()
            }
        }
        cursorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        sendCursorUpdateIfNeeded(force: true)
    }

    private func sendHiddenCursorPacketIfNeeded() {
        guard isConnected else { return }

        let cursor = TBMonitorCursor(
            x: 0,
            y: 0,
            width: capturePreset.width,
            height: capturePreset.height,
            visible: false,
            type: 0
        )
        lastCursorPacket = cursor
        if let packet = TBMonitorProtocol.makeJSONPacket(type: .cursor, value: cursor) {
            send(packet)
        }
    }

    private func applyCursorOverlayMode() {
        if inputRelayActive {
            cursorTimer?.invalidate()
            cursorTimer = nil
            sendHiddenCursorPacketIfNeeded()
            return
        }

        // No longer gated on largeCursor. That flag used to be the only thing
        // that turned the separate cursor path on, so for everyone else the
        // pointer was pixels in the video. It now selects sprite SIZE only.
        guard isStreaming, cursorDisplayID != kCGNullDirectDisplay else { return }
        startCursorUpdates(displayID: cursorDisplayID)
    }

    /// Ships the actual cursor bitmap, but only when it changes.
    ///
    /// The alternative was drawing each cursor from geometry on the receiver.
    /// That already exists for eight types in the SDL path — ~300 lines that
    /// would need a second copy in the Metal path and would then have to be kept
    /// in step with it. Sending the image is less code, always correct, and
    /// covers cursors we could never enumerate, application-custom ones included.
    ///
    /// Keyed on the NSCursor image identity rather than a pixel hash: AppKit
    /// returns the same object for the same cursor, so the common case is a
    /// pointer comparison and no work. This runs at 120 Hz; anything more
    /// expensive would be felt.
    private func sendCursorImageIfChanged() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image

        // Resend when the SIZE changes, not only when the image object changes.
        //
        // macOS scales the pointer for the accessibility "cursor size" setting and
        // for shake-to-find, and it can hand back the SAME NSImage at a new size.
        // Identity alone therefore misses every resize, which is why the pointer
        // on the receiver never grew.
        let scale = Self.systemCursorScale()
        let scaled = CGSize(width: image.size.width * scale,
                            height: image.size.height * scale)
        if let last = lastSentCursorImage, last === image,
           lastSentCursorSize == scaled { return }
        lastSentCursorSize = scaled

        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              cg.width > 0, cg.height > 0, cg.width <= 512, cg.height <= 512
        else { return }

        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // The hot spot is in the image's POINT size while the bitmap may be 2x,
        // so it has to be scaled or the pointer sits half a cursor off on Retina.
        let sx = image.size.width  > 0 ? Double(w) / Double(image.size.width)  : 1
        let sy = image.size.height > 0 ? Double(h) / Double(image.size.height) : 1
        let hotX = Int16(clamping: Int(cursor.hotSpot.x * sx))
        let hotY = Int16(clamping: Int(cursor.hotSpot.y * sy))

        var payload = Data(capacity: 8 + pixels.count)
        withUnsafeBytes(of: UInt16(w).littleEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(h).littleEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: hotX.littleEndian)      { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: hotY.littleEndian)      { payload.append(contentsOf: $0) }
        payload.append(contentsOf: pixels)

        send(TBMonitorProtocol.makePacket(type: .cursorImage, payload: payload))
        lastSentCursorImage = image
        TBLog.connection.info("cursor image sent: \(w)x\(h) hot \(hotX),\(hotY)")
    }

    private func getCurrentCursorType() -> Int {
        guard let current = NSCursor.currentSystem else { return 0 }
        if let last = lastCheckedCursor, last == current {
            return lastCheckedCursorType
        }

        lastCheckedCursor = current

        if let currentPng = Self.normalizedPng(for: current.image),
           let matchedType = Self.standardCursorPngs[currentPng] {
            lastCheckedCursorType = matchedType
            return matchedType
        }

        let size = current.image.size
        let hotSpot = current.hotSpot
        let type: Int
        if size.width > 0 && size.height > 0 {
            if hotSpot.x > 0 && hotSpot.x < 10 && hotSpot.y == 0 {
                type = 2 // Pointing Hand
            } else if size.width < size.height && abs(hotSpot.x - size.width / 2) < 2 && abs(hotSpot.y - size.height / 2) < 2 {
                type = 1 // I-Beam
            } else if abs(hotSpot.x - size.width / 2) < 2 && abs(hotSpot.y - size.height / 2) < 2 {
                if size.width > size.height {
                    type = 3 // Resize Horizontal
                } else if size.height > size.width {
                    type = 4 // Resize Vertical
                } else {
                    type = 3 // Default fallback for square symmetric cursors: Resize Horizontal
                }
            } else {
                type = 0 // Arrow
            }
        } else {
            type = 0 // Arrow
        }

        lastCheckedCursorType = type
        return type
    }

    private func sendCursorUpdateIfNeeded(force: Bool = false) {
        guard !inputRelayActive else { return }
        guard isConnected, isStreaming, cursorDisplayID != kCGNullDirectDisplay else { return }
        guard let point = CGEvent(source: nil)?.location else { return }

        let bounds = CGDisplayBounds(cursorDisplayID)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let localX = point.x - bounds.origin.x
        let localY = point.y - bounds.origin.y
        let visible = localX >= 0 && localY >= 0 && localX <= bounds.width && localY <= bounds.height

        let scaledX = Int((max(0, min(bounds.width, localX)) / bounds.width) * Double(capturePreset.width))
        let scaledY = Int((max(0, min(bounds.height, localY)) / bounds.height) * Double(capturePreset.height))
        let cursor = TBMonitorCursor(
            x: scaledX,
            y: scaledY,
            width: capturePreset.width,
            height: capturePreset.height,
            visible: visible,
            type: getCurrentCursorType()
        )

        if !force, let previous = lastCursorPacket {
            let movement = abs(previous.x - cursor.x) + abs(previous.y - cursor.y)
            if movement < 2,
               previous.visible == cursor.visible,
               previous.width == cursor.width,
               previous.height == cursor.height,
               previous.type == cursor.type {
                return
            }
        }

        // Shape before position: a position arriving first would place the
        // previous bitmap for one frame.
        sendCursorImageIfChanged()

        lastCursorPacket = cursor
        if let packet = TBMonitorProtocol.makeJSONPacket(type: .cursor, value: cursor) {
            send(packet)
        }
    }

    private func registerWakeObservers() {
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWake()
            }
        }

        wakeObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: nil,
                using: handler
            )
        )
        wakeObservers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: nil,
                using: handler
            )
        )
        wakeObservers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screensaver.didstop"),
                object: nil,
                queue: nil,
                using: handler
            )
        )
    }

    private func registerDisplayReconfigurationCallback() {
        guard !displayReconfigurationCallbackRegistered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, context)
        displayReconfigurationCallbackRegistered = (result == .success)
        if verboseDisplayLogging {
            startVerboseLoggingTimer()
        }
    }

    private func handleDisplayReconfiguration(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        let isOurs = session.displayID != kCGNullDirectDisplay && displayID == session.displayID
        guard verboseDisplayLogging || isOurs else { return }
        var parts: [String] = []
        if flags.contains(.addFlag) { parts.append("add") }
        if flags.contains(.removeFlag) { parts.append("remove") }
        if flags.contains(.enabledFlag) { parts.append("enabled") }
        if flags.contains(.disabledFlag) { parts.append("disabled") }
        if flags.contains(.mirrorFlag) { parts.append("mirror") }
        if flags.contains(.unMirrorFlag) { parts.append("unMirror") }
        if flags.contains(.movedFlag) { parts.append("moved") }
        if flags.contains(.setMainFlag) { parts.append("setMain") }
        if flags.contains(.setModeFlag) { parts.append("setMode") }
        if flags.contains(.beginConfigurationFlag) { parts.append("beginConfiguration") }
        if flags.contains(.desktopShapeChangedFlag) { parts.append("desktopShapeChanged") }
        let flagText = parts.isEmpty ? "none" : parts.joined(separator: "|")
        NSLog(
            "TargetBridge: display reconfiguration displayID=%u ours=%@ flags=%@ online=[%@]",
            displayID,
            isOurs ? "yes" : "no",
            flagText,
            onlineDisplayIDs().map(String.init).joined(separator: ",")
        )
        if isOurs, session.displayID != kCGNullDirectDisplay {
            displayStateText = describeDisplayState(for: session.displayID)
        }
    }

    private func startVerboseLoggingTimer() {
        stopVerboseLoggingTimer()
        guard verboseDisplayLogging else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logStreamSnapshot()
            }
        }
        verboseLoggingTimer = timer
        logStreamSnapshot()
    }

    private func stopVerboseLoggingTimer() {
        verboseLoggingTimer?.invalidate()
        verboseLoggingTimer = nil
    }

    private func startCaptureWatchdog() {
        captureHealthWatchdog?.invalidate()
        captureHealthWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkCaptureHealth()
            }
        }
    }

    private func stopCaptureWatchdog() {
        captureHealthWatchdog?.invalidate()
        captureHealthWatchdog = nil
    }

    private func checkCaptureHealth() {
        guard isStreaming, activeProfile != nil, !isRestartingCaptureAfterWake, let pipeline else { return }
        let elapsed = Date().timeIntervalSince(pipeline.lastCaptureFrameAtSnapshot)
        guard elapsed >= 8.0 else { return }
        NSLog("TargetBridge: capture watchdog tripped — %.1fs since last frame, soft restart", elapsed)
        scheduleCaptureRestart(reason: "watchdog (\(Int(elapsed))s without frames)", delaySeconds: 0.5)
    }

    private func logStreamSnapshot() {
        guard verboseDisplayLogging else { return }
        let online = onlineDisplayIDs()
        let virtualOnline = online.contains(session.displayID)
        let diag = pipeline?.diagnosticsSnapshot() ?? (pending: 0, inFlight: 0, ptsSeq: 0)
        NSLog(
            "TargetBridge: stream snapshot streaming=%@ fps=%d virtualID=%u online=%@ pendingPackets=%d inFlightEncode=%d ptsSeq=%lld",
            isStreaming ? "yes" : "no",
            liveMetrics.senderFPS,
            session.displayID,
            virtualOnline ? "yes" : "no",
            diag.pending,
            diag.inFlight,
            diag.ptsSeq
        )
    }

    private func handleSystemWake() {
        guard autoRestartOnWake else { return }
        scheduleCaptureRestart(reason: "system wake", delaySeconds: 1.0)
    }

    func restartCaptureNow() {
        scheduleCaptureRestart(reason: "manual restart", delaySeconds: 0.0)
    }

    var canRestartCapture: Bool {
        isStreaming && activeProfile != nil && !isRestartingCaptureAfterWake
    }

    private func scheduleCaptureRestart(reason: String, delaySeconds: Double) {
        guard isStreaming, !isRestartingCaptureAfterWake, let profile = activeProfile else { return }
        isRestartingCaptureAfterWake = true
        NSLog("TargetBridge: \(reason) — soft restart of capture pipeline")
        Task { @MainActor [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            guard let self else { return }
            guard self.isStreaming, self.activeProfile?.receiverName == profile.receiverName else {
                self.isRestartingCaptureAfterWake = false
                return
            }
            await self.softRestartCapture(for: profile)
            self.isRestartingCaptureAfterWake = false
        }
    }

    private func softRestartCapture(for profile: TBMonitorDisplayProfile) async {
        // Tear down only the capture pipeline — keep the network connection and virtual display.
        cursorTimer?.invalidate()
        cursorTimer = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        stopCaptureWatchdog()
        if let directDisplayStream {
            directDisplayStream.stop()
            self.directDisplayStream = nil
        }
        if let stream = scStream {
            if let delegate = captureDelegate {
                try? stream.removeStreamOutput(delegate, type: .screen)
                try? stream.removeStreamOutput(delegate, type: .audio)
            }
            stream.stopCapture(completionHandler: nil)
            scStream = nil
        }
        captureDelegate = nil
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
        stopAudioDeviceCapture()
        keepWarm.stop()
        pipeline?.stop()
        pipeline = nil
        isStreaming = false
        liveMetrics.senderFPS = 0
        senderFPS = 0
        videoPathIsRaw = false
        videoPathIsBGRA = false
        videoPathIsTenBit = false
        videoPathIsLossless = false
        videoPathRatio = 0
        sentSnapshot = 0
        cursorDisplayID = kCGNullDirectDisplay
        lastCursorPacket = nil

        let started = await startCapture(for: profile)
        if !started {
            NSLog("TargetBridge: soft restart after wake failed — falling back to full stop")
            stop(resetStatusTo: .captureError("capture restart after wake failed"))
        }
    }

    private func handleFirstEncodedFrame() {
        guard !sessionAckSent else { return }
        sessionAckSent = true
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        // Mirror the pipeline's actual path so the UI can't misreport it.
        videoPathIsRaw = pipeline?.rawPassthroughActive ?? false
        TBLog.connection.info("capture: first frame received path=\(self.videoPathIsRaw ? "raw-nv12" : "hevc", privacy: .public)")
        setStatus(.captureActive(capturePreset.description, activeCodecName ?? capturePreset.codecName, captureSource))
    }

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        sentSnapshot = pipeline?.sentFramesSnapshot ?? 0
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let total = pipeline?.sentFramesSnapshot ?? 0
                let fps = total - sentSnapshot
                liveMetrics.senderFPS = fps
                senderFPS = fps
                sentSnapshot = total
                // Refresh the observed path each tick: the second link can only
                // be seen once an odd frame has actually gone out.
                videoPathIsBGRA = pipeline?.rawFormatIsBGRA ?? false
                videoPathIsTenBit = pipeline?.rawFormatIsTenBit ?? false
                let ratio = pipeline?.dpcmRatio ?? 0
                videoPathIsLossless = ratio > 1
                videoPathRatio = ratio
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendHeartbeat()
            }
        }
    }

    private func startFirstFrameWatchdog() {
        // If the first encoded frame already arrived (handleFirstEncodedFrame ran
        // while startCapture was still suspended), there is nothing to watch for —
        // arming would only leave a no-op timer dangling for 4s.
        guard !sessionAckSent else { return }
        firstFrameTimer?.invalidate()
        firstFrameTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard isStreaming, !sessionAckSent else { return }
                let sentFrames = self.pipeline?.sentFramesSnapshot ?? 0
                TBLog.connection.error("capture: first-frame timeout preset=\(self.capturePreset.rawValue, privacy: .public) source=\(String(describing: self.captureSource), privacy: .public) connected=\(self.isConnected, privacy: .public) sentFrames=\(sentFrames, privacy: .public)")
                if self.capturePreset == .native5k || self.capturePreset == .native5k60Experimental {
                    setStatus(.hevcNoFrames)
                } else {
                    setStatus(.noFirstFrame)
                }
                stop(resetStatusTo: nil)
            }
        }
    }

    private func startConnectWatchdog() {
        connectTimeoutWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isConnected else { return }

                let timeoutMessage: String
                switch self.language {
                case .italian: timeoutMessage = "Connessione scaduta"
                case .english: timeoutMessage = "Connection timed out"
                case .german: timeoutMessage = "Verbindungs-Zeitüberschreitung"
                case .french: timeoutMessage = "Délai de connexion dépassé"
                case .chinese: timeoutMessage = "连接超时"
                }

                // Attach where we dialed, from which interface, and the last
                // state the network stack reported — previously all of this
                // was discarded and the user saw only the bare timeout.
                let detail = TBConnectionDiagnostics.failureDetail(
                    receiverHost: self.receiverIP,
                    port: TBMonitorProtocol.port,
                    localIP: self.localInterfaceIP,
                    interfaceName: self.connectInterfaceName,
                    transport: self.transportKind.rawValue,
                    lastNetworkState: self.lastConnectionStateDetail
                )
                TBLog.connection.error("connect: timed out — \(detail, privacy: .public)")
                self.setStatus(.connectionFailed("\(timeoutMessage) — \(detail)"))
                self.stop(resetStatusTo: nil)
            }
        }
        
        connectTimeoutWorkItem = workItem
        // 5.0 was too tight, and measurably so. A bundled app's first local
        // network connection sits in .waiting while macOS resolves its
        // local-network policy, and that is NOT a failure — Network.framework
        // retries and succeeds. Measured with a minimal signed app dialling this
        // same receiver: ready at 201ms with no source pin, and ready at 5203ms
        // with one. Against a 5000ms deadline the second case loses by 200ms
        // every time, which presents as "Connection timed out — last network
        // state: waiting(Network is down)" and looks exactly like a dead link.
        //
        // The deadline exists to stop a genuinely unreachable receiver hanging
        // the UI forever, so it only has to be shorter than a person's patience,
        // not shorter than the stack's own recovery. 20s is far past every
        // measured success and still bounded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: workItem)
    }


    // MARK: - Routed audio device

    /// With the Audio Driver addon on, our virtual device *is* the audio path —
    /// there is nothing to choose. It pushes PCM to us over loopback UDP: no
    /// capture session, no microphone permission, and already the exact wire
    /// format, so it bypasses the converter entirely.
    /// PCM handed over by the app-level driver listener.
    ///
    /// The socket is NOT owned here any more — see TBDisplaySenderService's
    /// audio driver listener for why it has to outlive any one session.
    func acceptDriverAudio(_ pcm: Data) {
        guard audioEnabled, isStreaming else { return }
        let payload = receiverSupportsFloat32Audio ? pcm : Self.int16(fromFloat32: pcm)
        send(TBMonitorProtocol.makePacket(type: .audioFrame, payload: payload))
    }

    private func startAudioDeviceCaptureIfNeeded() {
        guard audioEnabled, audioDriverAvailable else { return }
        // The listener itself now starts with the app. Only the volume mirror is
        // per-session, because it follows the receiver's hardware volume.
        startAudioVolumeMirror(uid: TBAudioDriverReceiver.deviceUID)
    }

    /// Mirror a device's OS volume onto the receiver's hardware volume, so the
    /// Sound slider and the F11/F12 keys (which act on the default output
    /// device) control the iMac. With our own driver this is the *only* thing
    /// its volume control does — it reports the level without touching samples,
    /// which is what stops the level being applied twice.
    private func startAudioVolumeMirror(uid: String) {
        let observer = TBAudioDeviceVolumeObserver { level in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Guard against feedback: our own send would otherwise bounce
                // back through the observer.
                if abs(self.volume - level) > 0.005 { self.volume = level }
            }
        }
        // Keep it whatever start() reports: our own driver publishes its device
        // about a second after we open the socket, so the usual outcome here is
        // "not yet" and the observer attaches itself when the device appears.
        observer.start(deviceUID: uid)
        audioVolumeObserver = observer
    }

    /// Float32 -> Int16 for receivers that cannot take float. Clamped, because
    /// a mix of several apps can exceed full scale and wrapping would be far
    /// more audible than the ceiling.
    private static func int16(fromFloat32 data: Data) -> Data {
        let count = data.count / MemoryLayout<Float32>.size
        var out = Data(count: count * MemoryLayout<Int16>.size)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let f = src.bindMemory(to: Float32.self)
                let i = dst.bindMemory(to: Int16.self)
                for n in 0..<count {
                    let v = max(-1.0, min(1.0, f[n]))
                    i[n] = Int16(v * TBAudioWireFormat.Int16Scale.fromFloat)
                }
            }
        }
        return out
    }

    private func stopAudioDeviceCapture() {
        // Stop first: the driver notices the silence and retires the device,
        // which is the backstop for the cases the restore below cannot cover
        // (crash, force quit).
        // If the user is listening through our virtual device, hand the system
        // back to its previous output — otherwise the device stays selected
        // with nothing behind it and sound just stops with no explanation.
        if audioDriverAvailable {
            TBDefaultOutputGuard.shared.restoreIfSelected()
        }
        micForwarder?.stop()
        micForwarder = nil
        // The driver listener is deliberately NOT stopped here. It belongs to the
        // app, not the session: the driver withdraws its audio device the moment
        // nothing answers on the sink port, so closing it at teardown made the
        // output device vanish from macOS every time a stream ended.
        audioVolumeObserver?.stop()
        audioVolumeObserver = nil
    }

    private func processAudio(_ sampleBuffer: CMSampleBuffer) {
        guard audioEnabled else { return }
        guard let data = audioConverter.convert(sampleBuffer: sampleBuffer) else { return }
        let packet = TBMonitorProtocol.makePacket(type: .audioFrame, payload: data)
        send(packet)
    }

    private func send(_ packet: Data) {
        // Report send failures instead of discarding them.
        //
        // This swallowed every error: `.contentProcessed({ _ in })` means a
        // packet that never left the socket looked identical to one that did.
        // The receiver's log showed it plainly -- it accepts the connection,
        // sends its display profile, and then never sees `hello from sender`,
        // so the sender tears the session down ~100ms in. Whatever stopped
        // that first packet, the sender had no way to say so.
        //
        // Nil connection is its own case: send() called after teardown is a
        // caller-ordering bug, not a network failure, and the two must not
        // look the same.
        guard let conn = connection else {
            TBTelemetryReporter.emit("send: DROPPED — no connection (\(packet.count) bytes)")
            TBLog.connection.error("send: dropped \(packet.count) bytes — connection is nil")
            return
        }
        conn.send(content: packet, completion: .contentProcessed({ [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                TBTelemetryReporter.emit("send: FAILED — \(error)")
                TBLog.connection.error(
                    "send: failed after \(packet.count, privacy: .public) bytes — \(error.localizedDescription, privacy: .public)")
                self.lastConnectionStateDetail = "send failed: \(error.localizedDescription)"
            }
        }))
    }

    func sendInputEvent(_ event: TBMonitorInputEvent) {
        guard isConnected else { return }
        send(TBMonitorProtocol.makeInputEventPacket(event))
    }

    func updateInputControlMode() {
        guard isConnected else { return }
        sendInputControlModeUpdate()
    }

}

private final class SBAudioConverter: Sendable {
    private let converterState: LockedConverterState = LockedConverterState()

    private final class LockedConverterState: @unchecked Sendable {
        private let lock = NSLock()
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var outputFormat: AVAudioFormat

        static func format(float: Bool) -> AVAudioFormat {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Double(TBAudioWireFormat.sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
                            | kAudioFormatFlagIsPacked,
                mBytesPerPacket: float ? 8 : 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: float ? 8 : 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: float ? 32 : 16,
                mReserved: 0
            )
            return AVAudioFormat(streamDescription: &asbd)!
        }

        init() {
            // Int16 until the receiver says it can take float, matching the
            // conservative default on the driver path.
            self.outputFormat = Self.format(float: false)
        }

        func setFloatOutput(_ float: Bool) {
            lock.lock()
            defer { lock.unlock() }
            let wanted = Self.format(float: float)
            guard !wanted.settings.isEmpty, outputFormat != wanted else { return }
            outputFormat = wanted
            converter = nil   // rebuilt on the next buffer with the new format
        }

        func convert(sampleBuffer: CMSampleBuffer) -> Data? {
            lock.lock()
            defer { lock.unlock() }

            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
            guard let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
            let inputASBD = asbdPointer.pointee

            // Recreate converter if input format changes
            if inputFormat == nil ||
               inputFormat!.streamDescription.pointee.mFormatFlags != inputASBD.mFormatFlags ||
               inputFormat!.streamDescription.pointee.mSampleRate != inputASBD.mSampleRate ||
               inputFormat!.streamDescription.pointee.mChannelsPerFrame != inputASBD.mChannelsPerFrame {
                var mutableASBD = inputASBD
                guard let inFormat = AVAudioFormat(streamDescription: &mutableASBD) else { return nil }
                self.inputFormat = inFormat
                self.converter = AVAudioConverter(from: inFormat, to: outputFormat)
            }

            guard let converter = self.converter, let inFormat = self.inputFormat else { return nil }

            let frameCount = sampleBuffer.numSamples
            guard frameCount > 0 else { return nil }
            let audioFrameCount = AVAudioFrameCount(frameCount)

            // Create input buffer
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: audioFrameCount) else { return nil }
            inputBuffer.frameLength = audioFrameCount

            // Extract audio data from sampleBuffer into inputBuffer
            let channelCount = Int(inFormat.channelCount)
            let bufferListSize = MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
            let bufferListRaw = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufferListRaw.deallocate() }

            let ablPointer = bufferListRaw.assumingMemoryBound(to: AudioBufferList.self)
            var blockBuffer: CMBlockBuffer?

            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: ablPointer,
                bufferListSize: bufferListSize,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )

            guard status == noErr else { return nil }

            let firstBufferPtr = withUnsafeMutablePointer(to: &ablPointer.pointee.mBuffers) { $0 }
            let buffers = UnsafeBufferPointer(start: firstBufferPtr, count: channelCount)

            if inFormat.isInterleaved {
                assertionFailure("SBAudioConverter: unexpected interleaved input format from ScreenCaptureKit")
                return nil
            } else {
                for i in 0..<channelCount {
                    if let dest = inputBuffer.floatChannelData?[i], let src = buffers[i].mData {
                        memcpy(dest, src, Int(buffers[i].mDataByteSize))
                    }
                }
            }

            // Perform conversion to outputFormat
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: audioFrameCount) else { return nil }

            var error: NSError?
            var inputConsumed = false
            let convertStatus = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if convertStatus == .error || error != nil {
                return nil
            }

            guard let channels = outputBuffer.int16ChannelData else { return nil }
            let dataSize = Int(outputBuffer.frameLength) * 4 // 2 channels * 2 bytes = 4 bytes per frame
            let rawPointer = UnsafeRawPointer(channels.pointee)
            return Data(bytes: rawPointer, count: dataSize)
        }
    }

    func convert(sampleBuffer: CMSampleBuffer) -> Data? {
        return converterState.convert(sampleBuffer: sampleBuffer)
    }

    func setFloatOutput(_ float: Bool) {
        converterState.setFloatOutput(float)
    }
}
