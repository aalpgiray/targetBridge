import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import AVFoundation
import IOSurface
import Network
@preconcurrency import ScreenCaptureKit
import VideoToolbox

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
            return "5K RAW"
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
            return "5120 × 2880 @ 60 (RAW)"
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
            return "RAW NV12"
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

    var queueDepth: Int {
        if let envVal = ProcessInfo.processInfo.environment["QD"], let parsed = Int(envVal) {
            return parsed
        }
        return 2
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

    // Dual-cable: an optional second connection (cable 2). When present, raw
    // frames are interleaved across the two links (even → primary, odd →
    // secondary) to roughly double throughput. Control packets always go on the
    // primary. Attached after the primary is streaming; confined to `queue`.
    private var secondaryConnection: NWConnection?
    private var pendingVideoPacketsSecondary = 0
    private var rawFrameCounter = 0
    /// Damage streaming: send whole frames only when we must (first frame,
    /// format/size change, too much changed, or a periodic resync) and send
    /// just the changed rectangles otherwise.
    /// Send only changed rectangles instead of whole frames. Set from the
    /// session's user-facing toggle before start().
    var damageEnabled = true
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
    /// Bands per frame. 18 or 20 measured best on this hardware: encode grows
    /// ~0.26 ms per slice (two GPU round trips each), so past ~20 it overtakes the
    /// wire and becomes the slowest stage, and the makespan turns back up.
    /// Must divide the frame into whole 8-row tiles.
    /// `defaults write com.targetbridge.sender TBSliceCount -int 18` to try it,
    /// 1 to go back. A runtime knob rather than a constant because the gain is a
    /// model prediction until it is measured on the link, and because a bad value
    /// should be one command to undo rather than a reinstall.
    var dpcmSliceCount = max(1, UserDefaults.standard.integer(forKey: "TBSliceCount"))
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
    private var framesSinceKeyframe = 0
    /// Set whenever a frame is skipped (backpressure) or anything else could
    /// have left the receiver's base image stale. Forces one full frame.
    private var needsKeyframe = true
    /// Dirty rects from frames we had to skip, folded into the next send.
    private var carriedDirty: [TBDirtyRect] = []
    private var lastDamageFormat: UInt8 = 0
    private var lastDamageW = 0
    private var lastDamageH = 0

    // Confined to `queue`.
    private var vtEncoder: VTCompressionSession?
    private var vtEncoderRef: Unmanaged<TBVideoPipeline>?
    private var pendingVideoPackets = 0
    private var inFlightEncodeFrames = 0
    private var displayStreamFrameSequence: CMTimeValue = 0
    private var lastEncodedDisplayPTS: CMTime?
    private var ackSent: Bool
    private var running = false

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
        queue.sync { (pending: pendingVideoPackets, inFlight: inFlightEncodeFrames, ptsSeq: displayStreamFrameSequence) }
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
    private var _rawFormatIsBGRA = false
    private var _rawFormatIsTenBit = false
    private var _sentFramesSecondary = 0
    var rawFormatIsBGRA: Bool { lock.lock(); defer { lock.unlock() }; return _rawFormatIsBGRA }
    var rawFormatIsTenBit: Bool { lock.lock(); defer { lock.unlock() }; return _rawFormatIsTenBit }
    var secondaryLinkCarriedFrames: Bool {
        lock.lock(); defer { lock.unlock() }; return _sentFramesSecondary > 0
    }

    /// SCStream capture path. Must be dispatched onto `queue` by the caller.
    func encode(_ sampleBuffer: CMSampleBuffer) {
        markCaptureFrame()
        if rawEnabled {
            sendRawFrame(sampleBuffer)
            return
        }
        guard running, let encoder = vtEncoder,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        if preset.dropsBeforeEncodeWhenBacklogged,
           (pendingVideoPackets >= preset.maxPendingVideoPackets ||
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
           (pendingVideoPackets >= preset.maxPendingVideoPackets ||
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

        if !isKeyframe, pendingVideoPackets >= preset.maxPendingVideoPackets {
            return
        }

        if isKeyframe,
           let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let packet = buildParamSetsPacket(from: format, codecType: codecType) {
            connection.send(content: packet, completion: .contentProcessed({ _ in }))
        }

        if let packet = buildFramePacket(from: sampleBuffer) {
            pendingVideoPackets += 1
            connection.send(content: packet, completion: .contentProcessed({ [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.pendingVideoPackets = max(0, self.pendingVideoPackets - 1)
                }
            }))
            lock.lock(); _sentFrames += 1; lock.unlock()
        }
    }

    /// Dual-cable: attach the second cable's connection once it's `ready`.
    /// From the next frame on, raw frames interleave across both links.
    /// A new link starts with no base image on the far side.
    func requestKeyframe() { needsKeyframe = true }

    func attachSecondaryConnection(_ conn: NWConnection) {
        queue.async { [weak self] in self?.secondaryConnection = conn }
    }

    func detachSecondaryConnection() {
        queue.async { [weak self] in
            self?.secondaryConnection = nil
            self?.pendingVideoPacketsSecondary = 0
        }
    }

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
            capCadenceBin[cadenceBin(pts - lastCapturePTS)] += 1
            capCadenceCount += 1
        }
        lastCapturePTS = pts

        guard capCadenceCount >= 240 else { return }
        func fmt(_ bins: [Int]) -> String {
            let total = max(1, bins.reduce(0, +))
            return bins.enumerated()
                .filter { $0.element > 0 }
                .map { "\($0.offset):\($0.element) (\(Int(100.0 * Double($0.element) / Double(total)))%)" }
                .joined(separator: "  ")
        }
        TBLog.connection.info("cadence capture(pts) \(fmt(self.capCadenceBin), privacy: .public)")
        TBLog.connection.info("cadence send(wall)   \(fmt(self.sendCadenceBin), privacy: .public)  drops \(self.cadenceDrops, privacy: .public)")
        if latSamples > 0 {
            let n = Double(latSamples)
            TBLog.connection.info("latency delivery \(String(format: "%.1f", self.latDeliverySum / n), privacy: .public) ms avg / \(String(format: "%.1f", self.latDeliveryMax), privacy: .public) max | process \(String(format: "%.1f", self.latProcessSum / n), privacy: .public) ms avg / \(String(format: "%.1f", self.latProcessMax), privacy: .public) max")
        }
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
        let frameEnteredAt = Self.hostNow()
        let planar = CVPixelBufferGetPlaneCount(pixelBuffer) >= 2

        // Dual-cable: alternate whole frames across the two links (even →
        // primary, odd → secondary). Backpressure is per-link so a stall on one
        // cable drops only its frames. Control packets always use the primary.
        let useSecondary = (secondaryConnection != nil) && (rawFrameCounter & 1 == 1)
        rawFrameCounter &+= 1
        let targetConnection = useSecondary ? (secondaryConnection ?? connection) : connection
        let backedUp = useSecondary
            ? pendingVideoPacketsSecondary >= preset.maxPendingVideoPackets
            : pendingVideoPackets >= preset.maxPendingVideoPackets
        if backedUp {
            // A skipped frame's damage would otherwise be lost for good, since
            // the receiver cannot know it missed an update. Carry the rects
            // forward and fold them into the next packet we do send — the
            // pixels come from the newer frame, which is what we want anyway.
            // (Forcing a full frame here instead caused a feedback loop: 59 MB
            // takes longer than a frame period, producing more backpressure,
            // more drops and more full frames — it pinned the stream at 26 fps.)
            if lastDamageW > 0,
               let r = Self.dirtyRects(from: sampleBuffer, width: lastDamageW, height: lastDamageH) {
                carriedDirty.append(contentsOf: r)
                if carriedDirty.count > 64 { needsKeyframe = true; carriedDirty.removeAll() }
            } else {
                needsKeyframe = true
            }
            cadenceDrops += 1
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
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

            // Damage path for NV12. Chroma is half resolution in both axes, so
            // every rect is snapped outward to even coordinates — an odd edge
            // would put the chroma rect off by half a sample and fringe the
            // boundary of each updated region.
            if damageEnabled,
               !needsKeyframe,
               secondaryConnection == nil,
               lastDamageFormat == 1, width == lastDamageW, height == lastDamageH,
               framesSinceKeyframe < 60,
               let fresh = Self.dirtyRects(from: sampleBuffer, width: width, height: height),
               case let rects = (carriedDirty + fresh).map({ r -> TBDirtyRect in
                   let x0 = r.x & ~1, y0 = r.y & ~1
                   let x1 = min(width,  (r.x + r.w + 1) & ~1)
                   let y1 = min(height, (r.y + r.h + 1) & ~1)
                   return TBDirtyRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
               }).filter({ $0.w > 0 && $0.h > 0 }),
               !rects.isEmpty, rects.count <= 64,
               rects.reduce(0, { $0 + $1.w * $1.h }) * 2 < width * height {

                var d = Data(capacity: 11 + rects.reduce(0) { $0 + 16 + $1.w * $1.h * 3 / 2 })
                d.append(1)
                TBMonitorProtocol.appendBE32(&d, UInt32(width))
                TBMonitorProtocol.appendBE32(&d, UInt32(height))
                d.append(UInt8((rects.count >> 8) & 0xFF))
                d.append(UInt8(rects.count & 0xFF))
                let ySrc  = yBase.assumingMemoryBound(to: UInt8.self)
                let uvSrc = uvBase.assumingMemoryBound(to: UInt8.self)
                for r in rects {
                    TBMonitorProtocol.appendBE32(&d, UInt32(r.x))
                    TBMonitorProtocol.appendBE32(&d, UInt32(r.y))
                    TBMonitorProtocol.appendBE32(&d, UInt32(r.w))
                    TBMonitorProtocol.appendBE32(&d, UInt32(r.h))
                    for row in 0..<r.h {
                        d.append(UnsafeBufferPointer(start: ySrc + (r.y + row) * yStride + r.x,
                                                     count: r.w))
                    }
                    // One UV row per two luma rows; r.w bytes covers r.w/2
                    // chroma pairs, so the byte offset is r.x either way.
                    for row in 0..<(r.h / 2) {
                        d.append(UnsafeBufferPointer(start: uvSrc + (r.y / 2 + row) * uvStride + r.x,
                                                     count: r.w))
                    }
                }
                carriedDirty.removeAll(keepingCapacity: true)
                framesSinceKeyframe += 1
                let dmg = TBMonitorProtocol.makePacket(type: .rawDamage, payload: d)
                if useSecondary { pendingVideoPacketsSecondary += 1 } else { pendingVideoPackets += 1 }
                targetConnection.send(content: dmg, completion: .contentProcessed({ [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        if useSecondary {
                            self.pendingVideoPacketsSecondary = max(0, self.pendingVideoPacketsSecondary - 1)
                        } else {
                            self.pendingVideoPackets = max(0, self.pendingVideoPackets - 1)
                        }
                    }
                }))
                lock.lock()
                _sentFrames += 1
                _rawFormatIsBGRA = false
                _rawFormatIsTenBit = false
                if useSecondary { _sentFramesSecondary += 1 }
                lock.unlock()
                return
            }

            lastDamageFormat = 1
            lastDamageW = width
            lastDamageH = height
            framesSinceKeyframe = 0
            needsKeyframe = false
            carriedDirty.removeAll(keepingCapacity: true)

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
            if isTenBit {
                probeTenBitDepth(base, width: width, height: height, stride: stride)
            } else {
                probeAlphaConstant(base, width: width, height: height, stride: stride)
            }
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
            if dpcmEnabled, secondaryConnection == nil {
                if !dpcmGPUTried {
                    dpcmGPUTried = true
                    dpcmGPU = tb_dpcm_gpu_create()
                    if let e = dpcmGPU {
                        TBLog.connection.info("dpcm: gpu encoder on \(String(cString: tb_dpcm_gpu_device_name(e)), privacy: .public)")
                    } else {
                        TBLog.connection.error("dpcm: gpu encoder unavailable; sending uncompressed")
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
                let wantSlices = dpcmSlicesEnabled ? max(1, dpcmSliceCount) : 1
                let bandRows = height / wantSlices
                let sliceCount = (wantSlices > 1 && bandRows % Int(TB_DPCM_TILE) == 0
                                  && bandRows * wantSlices == height) ? wantSlices : 1
                let rowsPerBand = height / sliceCount
                let reserve = TBMonitorProtocol.headerSize
                    + (sliceCount > 1 ? TBMonitorProtocol.sliceHeaderSize : 0)

                dpcmFrameID &+= 1
                let captureNanos = UInt64(max(0, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds) * 1_000_000_000)

                var encodedAny = false
                var totalWritten = 0
                for band in 0..<sliceCount {
                    let y0 = band * rowsPerBand
                    var blob: UnsafePointer<UInt8>? = nil
                    let written = dpcmGPU.map {
                        tb_dpcm_gpu_encode($0,
                                           base.assumingMemoryBound(to: UInt8.self)
                                               .advanced(by: y0 * stride),
                                           Int32(stride), Int32(width), Int32(rowsPerBand),
                                           isTenBit ? 1 : 0, reserve, &blob)
                    } ?? 0
                    guard written > 0, let blob else { break }
                    encodedAny = true
                    totalWritten += written

                    let pkt: Data
                    if sliceCount > 1 {
                        pkt = TBMonitorProtocol.framedSlicePacket(
                            base: blob, totalCount: written,
                            captureTimeNanos: captureNanos,
                            frameID: dpcmFrameID,
                            frameW: UInt32(width), frameH: UInt32(height),
                            y0: UInt32(y0),
                            index: UInt16(band), count: UInt16(sliceCount))
                    } else {
                        pkt = TBMonitorProtocol.framedPacket(
                            type: .rawDPCM, base: blob, totalCount: written)
                    }

                    pendingVideoPackets += 1
                    targetConnection.send(content: pkt, completion: .contentProcessed({ [weak self] _ in
                        guard let self else { return }
                        self.queue.async {
                            self.pendingVideoPackets = max(0, self.pendingVideoPackets - 1)
                        }
                    }))
                }

                if encodedAny {
                    let written = totalWritten
                    if !dpcmLogged {
                        dpcmLogged = true
                        let raw = stride * height
                        TBLog.connection.info("dpcm: \(width, privacy: .public)x\(height, privacy: .public) \(isTenBit ? 10 : 8, privacy: .public)-bit \(raw / 1_000_000, privacy: .public) MB -> \(written / 1_000_000, privacy: .public) MB (\(String(format: "%.2fx", Double(raw) / Double(written)), privacy: .public)) \(sliceCount, privacy: .public) slice(s) \(tb_dpcm_gpu_last_was_zero_copy(self.dpcmGPU!) != 0 ? "zero-copy" : "staged", privacy: .public)")
                    }
                    let process = (Self.hostNow() - frameEnteredAt) * 1000.0
                    if process >= 0, process < 500 {
                        latProcessSum += process
                        latProcessMax = max(latProcessMax, process)
                        latSamples += 1
                    }
                    noteSend()

                    // Nothing incremental is in flight, so a later fall back to
                    // the uncompressed path must start from a full frame.
                    needsKeyframe = true
                    lastDamageW = 0
                    lastDamageH = 0
                    carriedDirty.removeAll(keepingCapacity: true)

                    lock.lock()
                    _sentFrames += 1
                    _rawFormatIsBGRA = true
                    _rawFormatIsTenBit = isTenBit
                    lock.unlock()
                    return
                }
                // Encoder refused (only possible on a bad size or capacity):
                // fall through and send the frame uncompressed.
            }

            // Damage path: resend only what the WindowServer says changed.
            // A full frame is still required on the first frame, on any format
            // or size change, periodically as a resync, and when the damaged
            // area is big enough that per-rect overhead outweighs the saving.
            if damageEnabled,
               !needsKeyframe,
               // Damage is incremental, so it must arrive in order. Dual-cable
               // interleaves whole frames across two links with no sequencing,
               // which would apply updates out of order. (Dual-cable also
               // measured slower than a single link, so this costs nothing.)
               secondaryConnection == nil,
               fmt == lastDamageFormat, width == lastDamageW, height == lastDamageH,
               // ~1s resync. A 59 MB full frame takes longer than a frame
               // period to transmit, so sending them too often is itself a
               // source of backpressure — 0.5s measurably hurt.
               framesSinceKeyframe < 60,
               let fresh = Self.dirtyRects(from: sampleBuffer, width: width, height: height),
               case let rects = (carriedDirty + fresh),
               !rects.isEmpty, rects.count <= 64,
               rects.reduce(0, { $0 + $1.w * $1.h }) * 2 < width * height {

                var d = Data(capacity: 11 + rects.reduce(0) { $0 + 16 + $1.w * $1.h * 4 })
                d.append(fmt)
                TBMonitorProtocol.appendBE32(&d, UInt32(width))
                TBMonitorProtocol.appendBE32(&d, UInt32(height))
                d.append(UInt8((rects.count >> 8) & 0xFF))
                d.append(UInt8(rects.count & 0xFF))
                let src = base.assumingMemoryBound(to: UInt8.self)
                for r in rects {
                    TBMonitorProtocol.appendBE32(&d, UInt32(r.x))
                    TBMonitorProtocol.appendBE32(&d, UInt32(r.y))
                    TBMonitorProtocol.appendBE32(&d, UInt32(r.w))
                    TBMonitorProtocol.appendBE32(&d, UInt32(r.h))
                    // Rows packed tight — the source stride's padding is not sent.
                    for row in 0..<r.h {
                        d.append(UnsafeBufferPointer(start: src + (r.y + row) * stride + r.x * 4,
                                                     count: r.w * 4))
                    }
                }
                carriedDirty.removeAll(keepingCapacity: true)
                framesSinceKeyframe += 1
                let dmg = TBMonitorProtocol.makePacket(type: .rawDamage, payload: d)
                if useSecondary { pendingVideoPacketsSecondary += 1 } else { pendingVideoPackets += 1 }
                targetConnection.send(content: dmg, completion: .contentProcessed({ [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        if useSecondary {
                            self.pendingVideoPacketsSecondary = max(0, self.pendingVideoPacketsSecondary - 1)
                        } else {
                            self.pendingVideoPackets = max(0, self.pendingVideoPackets - 1)
                        }
                    }
                }))
                lock.lock()
                _sentFrames += 1
                _rawFormatIsBGRA = true
                _rawFormatIsTenBit = isTenBit
                if useSecondary { _sentFramesSecondary += 1 }
                lock.unlock()
                return
            }

            lastDamageFormat = fmt
            lastDamageW = width
            lastDamageH = height
            framesSinceKeyframe = 0
            needsKeyframe = false
            carriedDirty.removeAll(keepingCapacity: true)

            var p = Data(capacity: 13 + size)
            p.append(fmt) // format: ARGB2101010 / BGRA8888, both 4:4:4
            TBMonitorProtocol.appendBE32(&p, UInt32(width))
            TBMonitorProtocol.appendBE32(&p, UInt32(height))
            TBMonitorProtocol.appendBE32(&p, UInt32(stride))
            p.append(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: size))
            payload = p
        }

        let packet = TBMonitorProtocol.makePacket(type: .rawFrame, payload: payload)
        if useSecondary { pendingVideoPacketsSecondary += 1 } else { pendingVideoPackets += 1 }
        targetConnection.send(content: packet, completion: .contentProcessed({ [weak self] _ in
            guard let self else { return }
            self.queue.async {
                if useSecondary {
                    self.pendingVideoPacketsSecondary = max(0, self.pendingVideoPacketsSecondary - 1)
                } else {
                    self.pendingVideoPackets = max(0, self.pendingVideoPackets - 1)
                }
            }
        }))
        lock.lock()
        _sentFrames += 1
        _rawFormatIsBGRA = !planar
        _rawFormatIsTenBit = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_ARGB2101010LEPacked
        if useSecondary { _sentFramesSecondary += 1 }
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
        alphaProbeCountdown = 300

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
    private var alphaProbeCountdown = 0
    private func probeTenBitDepth(_ base: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int) {
        if tenBitProbeCountdown > 0 { tenBitProbeCountdown -= 1; return }
        tenBitProbeCountdown = 180   // roughly every 3s at 60fps

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
            if ((r | g | b) & 3) != 0 { deep += 1 }
            sampled += 1
            index += 997      // prime: spreads samples across rows and columns
        }
        // Distinct values, taking the richest row found rather than one fixed
        // row: whatever is being measured rarely fills the screen, and a row of
        // flat desktop reports a handful of levels and tells us nothing. An
        // 8-bit source cannot exceed 256 however it is converted afterwards; a
        // 10-bit one can reach 1024. Counting non-zero low bits cannot separate
        // real depth from bits a conversion invents.
        var best = 0
        var bestRow = 0
        let rowStep = Swift.max(1, height / 48)
        var row = 0
        while row < height {
            var seen = Set<UInt32>()
            for x in 0..<Swift.min(width, 2560) {
                let word = base.load(fromByteOffset: (row * rowWords + x) * 4, as: UInt32.self)
                seen.insert((word >> 10) & 0x3FF)
            }
            if seen.count > best { best = seen.count; bestRow = row }
            row += rowStep
        }
        TBLog.connection.notice(
            "10-bit depth: richest row (y=\(bestRow, privacy: .public)) has \(best, privacy: .public) distinct green levels — >256 means the source is deeper than 8-bit"
        )

        guard sampled > 0 else { return }
        let pct = Double(deep) * 100.0 / Double(sampled)
        TBLog.connection.notice(
            "10-bit probe: \(deep, privacy: .public)/\(sampled, privacy: .public) samples carry sub-8-bit detail (\(String(format: "%.2f", pct), privacy: .public)%) — 0% means the source is 8-bit padded into l10r"
        )
    }


    struct TBDirtyRect { let x: Int; let y: Int; let w: Int; let h: Int }

    /// Pull the WindowServer's dirty rectangles off the sample buffer. This is
    /// why damage detection costs nothing: the compositor already computed the
    /// changed regions to draw the frame, and ScreenCaptureKit attaches them.
    /// Returns nil when unavailable, which forces a full frame.
    private static func dirtyRects(from sb: CMSampleBuffer, width: Int, height: Int) -> [TBDirtyRect]? {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = arr.first,
              let raw = info[.dirtyRects] as? [[String: Any]]
        else { return nil }

        var out: [TBDirtyRect] = []
        out.reserveCapacity(raw.count)
        for entry in raw {
            guard let r = CGRect(dictionaryRepresentation: entry as CFDictionary) else { return nil }
            // Clamp into the frame and round outward, so a fractional rect can
            // never leave a stale sliver behind.
            let x0 = max(0, Int(r.minX.rounded(.down)))
            let y0 = max(0, Int(r.minY.rounded(.down)))
            let x1 = min(width,  Int(r.maxX.rounded(.up)))
            let y1 = min(height, Int(r.maxY.rounded(.up)))
            if x1 <= x0 || y1 <= y0 { continue }
            out.append(TBDirtyRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0))
        }
        // A great many small rects costs more in overhead than it saves.
        return out.count <= 64 ? out : nil
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
    private static let dualCableEnabledDefaultsKey = "fd.tbdisplaysender.dualCableEnabled"
    private static let secondaryLocalIPDefaultsKey = "fd.tbdisplaysender.secondaryLocalIP"
    private static let secondaryReceiverIPDefaultsKey = "fd.tbdisplaysender.secondaryReceiverIP"
    private static let fullColor444DefaultsKey = "fd.tbdisplaysender.fullColor444"
    private static let tenBitDefaultsKey = "fd.tbdisplaysender.tenBit"
    private static let damageRectsDefaultsKey = "fd.tbdisplaysender.damageRects"
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
    // Dual-cable: the second cable's local + receiver IPs. When enabled and both
    // are set, a second connection carries half the frames (interleaved) to
    // roughly double throughput. Locked while streaming, like the other stream
    // settings.
    // Persisted like receiverIP: a relaunch that silently dropped back to a
    // single cable looks identical to a bandwidth problem, so these survive.
    @Published var dualCableEnabled = UserDefaults.standard.bool(forKey: dualCableEnabledDefaultsKey) {
        didSet { UserDefaults.standard.set(dualCableEnabled, forKey: Self.dualCableEnabledDefaultsKey) }
    }
    @Published var secondaryLocalInterfaceIP = UserDefaults.standard.string(forKey: secondaryLocalIPDefaultsKey) ?? "" {
        didSet { UserDefaults.standard.set(secondaryLocalInterfaceIP, forKey: Self.secondaryLocalIPDefaultsKey) }
    }
    @Published var secondaryReceiverIP = UserDefaults.standard.string(forKey: secondaryReceiverIPDefaultsKey) ?? "" {
        didSet { UserDefaults.standard.set(secondaryReceiverIP, forKey: Self.secondaryReceiverIPDefaultsKey) }
    }
    // Full-color 4:4:4: capture 8-bit BGRA instead of 4:2:0 NV12 — no chroma
    // subsampling, so colored edges/text are crisp. ~28 Gb/s at 5K@60, so it
    // realistically needs dual-cable. Raw presets only.
    @Published var fullColor444 = UserDefaults.standard.bool(forKey: fullColor444DefaultsKey) {
        didSet { UserDefaults.standard.set(fullColor444, forKey: Self.fullColor444DefaultsKey) }
    }
    /// 10-bit packed 2-10-10-10. Same 4 bytes/pixel as 8-bit BGRA, so it costs
    /// no extra bandwidth — it only removes gradient banding. Needs `fullColor444`.
    @Published var tenBit = UserDefaults.standard.bool(forKey: tenBitDefaultsKey) {
        didSet { UserDefaults.standard.set(tenBit, forKey: Self.tenBitDefaultsKey) }
    }
    /// Send only the rectangles that changed. Big win for static/desktop work;
    /// no help when the whole screen changes every frame (video, scrolling),
    /// where it adds per-rect overhead on top of a full frame. Default on.
    @Published var damageRects: Bool = UserDefaults.standard.object(forKey: damageRectsDefaultsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(damageRects, forKey: Self.damageRectsDefaultsKey) }
    }
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

    private var audioDriverReceiver: TBAudioDriverReceiver?
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
    @Published var videoPathDualCable = false
    // Live FPS readout. Kept on a dedicated observable so its once-per-second
    // update only re-renders the small FPS subview — not the whole session card
    // or (via the manager's objectWillChange bubble-up) the entire window.
    let liveMetrics = TBSessionLiveMetrics()
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
    // Dual-cable: the second Thunderbolt link's frame pipe (cable 2). Opened
    // after the primary is streaming; carries half the frames (interleaved).
    private var secondaryConnection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "fd.tbmonitor.sender.connection", qos: .userInteractive)
    private var recvBuffer = Data()

    private var session = ReceiverBackedVirtualDisplaySession()
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
                return true
            case .idle, .blank, .suspended, .stopped:
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

    /// Dual-cable: open the second Thunderbolt link as a send-only frame pipe and
    /// hand it to the running pipeline. Bound to `secondaryLocalInterfaceIP`,
    /// dials `secondaryReceiverIP`. If it never comes up, the pipeline just keeps
    /// all frames on the primary (graceful single-cable fallback).
    /// Builds (but does not start) a connection bound to the second cable's
    /// local interface. Shared by the streaming path and the cable test so both
    /// dial cable 2 identically.
    private func makeSecondaryConnection() -> NWConnection {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo
        if let localPort = NWEndpoint.Port(rawValue: 0) {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(secondaryLocalInterfaceIP), port: localPort)
        }
        let interfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
        let scopedHost = TBConnectionDiagnostics.scopedReceiverHost(
            receiverIP: secondaryReceiverIP,
            localIP: secondaryLocalInterfaceIP,
            interfaces: interfaces
        )
        let dialHost: NWEndpoint.Host
        if scopedHost != secondaryReceiverIP, let scopedAddress = IPv4Address(scopedHost) {
            dialHost = .ipv4(scopedAddress)
        } else {
            dialHost = NWEndpoint.Host(secondaryReceiverIP)
        }
        TBLog.connection.info("connect(secondary): dialing \(scopedHost, privacy: .public) from \(self.secondaryLocalInterfaceIP, privacy: .public)")
        return NWConnection(host: dialHost, port: NWEndpoint.Port(integerLiteral: TBMonitorProtocol.port), using: params)
    }

    private func openSecondaryConnection(for pipeline: TBVideoPipeline) {
        guard secondaryConnection == nil else { return }
        let conn = makeSecondaryConnection()
        secondaryConnection = conn
        conn.stateUpdateHandler = { [weak self, weak conn, weak pipeline] state in
            Task { @MainActor [weak self, weak conn, weak pipeline] in
                guard let self, let conn, self.secondaryConnection === conn else { return }
                switch state {
                case .ready:
                    TBLog.connection.info("connect(secondary): ready — cable 2 attached")
                    pipeline?.attachSecondaryConnection(conn)
                case .failed(let error), .waiting(let error):
                    TBLog.connection.warning("connect(secondary): \(error.localizedDescription, privacy: .public)")
                default:
                    break
                }
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .userInteractive))
    }

    func connect() {
        guard connection == nil, !receiverIP.isEmpty, !localInterfaceIP.isEmpty else { return }
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
        if let localPort = NWEndpoint.Port(rawValue: 0) {
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

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor [weak self, weak conn] in
                guard let self, let conn, self.connection === conn else { return }
                switch state {
                case .ready:
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
                    self.lastConnectionStateDetail = "waiting(\(error.localizedDescription))"
                    TBLog.connection.warning("connect: waiting — \(error.localizedDescription, privacy: .public)")
                case .failed(let error):
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
                    self.isConnected = false
                default:
                    break
                }
            }
        }

        startConnectWatchdog()
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

        let wantsDual = dualCableEnabled
            && !secondaryLocalInterfaceIP.isEmpty
            && !secondaryReceiverIP.isEmpty

        guard wantsDual else {
            let rate = try await pushCableTestBytes(on: primary, totalBytes: 20 * 1000 * 1000 * 1000)
            cableTestDetail = nil
            return rate
        }

        // Half the payload per link, so a dual run takes the same wall-clock
        // time as a single one.
        let perLink: Int64 = 10 * 1000 * 1000 * 1000

        let secondary = makeSecondaryConnection()
        defer {
            secondary.stateUpdateHandler = nil
            secondary.cancel()
        }
        do {
            let once = TBOnceFlag()
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                secondary.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() { c.resume() }
                    case .failed(let e), .waiting(let e):
                        if once.claim() { c.resume(throwing: e) }
                    default: break
                    }
                }
                secondary.start(queue: DispatchQueue.global(qos: .userInitiated))
            }
        } catch {
            // Cable 2 unreachable — report cable 1 alone rather than failing.
            TBLog.connection.warning("cable test: cable 2 unavailable (\(error.localizedDescription, privacy: .public)); testing cable 1 only")
            let rate = try await pushCableTestBytes(on: primary, totalBytes: 20 * 1000 * 1000 * 1000)
            cableTestDetail = "cable 2 unavailable"
            return rate
        }

        let started = DispatchTime.now()
        async let a = pushCableTestBytes(on: primary, totalBytes: perLink)
        async let b = pushCableTestBytes(on: secondary, totalBytes: perLink)
        let (rateA, rateB) = try await (a, b)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9

        // Aggregate over wall-clock: the links overlap, so summing their
        // individual rates would overstate what the pair actually sustained.
        let aggregate = Double(perLink * 2) * 8.0 / 1e9 / elapsed
        cableTestDetail = String(format: "cable 1: %.1f · cable 2: %.1f Gb/s", rateA, rateB)
        TBLog.connection.info("cable test: cable1=\(rateA, privacy: .public) cable2=\(rateB, privacy: .public) aggregate=\(aggregate, privacy: .public) Gb/s")
        return aggregate
    }

    /// Push `totalBytes` down one link as fast as it will accept them and
    /// return the achieved rate in Gb/s. Used once per cable so a dual-cable
    /// run measures each link and their aggregate.
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
        pipeline?.stop()
        pipeline = nil
        releaseInjectedModifiersIfNeeded()
        remoteHeldModifierKeyCodes.removeAll()
        injectedLeftClickTracker.reset()
        suppressedTriggerKeyCode = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        secondaryConnection?.stateUpdateHandler = nil
        secondaryConnection?.cancel()
        secondaryConnection = nil
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
        ) else { return }
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
                guard let self, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.recvBuffer.append(data)
                    self.drainPackets()
                }
                if error != nil || isDone {
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
        TBLog.connection.info("receiver caps: dpcm=\(self.receiverSupportsDPCM, privacy: .public) float32Audio=\(self.receiverSupportsFloat32Audio, privacy: .public)")
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
            let codecName = usesRawNV12 ? "NV12 RAW" : codecName(for: codecType)
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
            pipeline.damageEnabled = damageRects
            pipeline.dpcmEnabled = receiverSupportsDPCM
            pipeline.dpcmSlicesEnabled = receiverSupportsDPCMSlices
            guard pipeline.start() else { return false }
            startAudioDeviceCaptureIfNeeded()
            self.pipeline = pipeline
            TBLog.connection.info("capture: pipeline started preset=\(preset.rawValue, privacy: .public) source=\(String(describing: self.captureSource), privacy: .public) codec=\(codecName, privacy: .public) rawNV12=\(usesRawNV12, privacy: .public)")

            if self.dualCableEnabled,
               !self.secondaryLocalInterfaceIP.isEmpty,
               !self.secondaryReceiverIP.isEmpty {
                self.openSecondaryConnection(for: pipeline)
            }

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
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(preset.expectedFrameRate))
            configuration.queueDepth = preset.queueDepth
            // Full-color 4:4:4 raw = capture packed BGRA; otherwise 4:2:0 NV12.
            // 10-bit uses packed 2-10-10-10, which is also 4 bytes/pixel — same
            // bandwidth and same per-frame cost as 8-bit BGRA, just finer
            // gradients. Requires 4:4:4 (there is no subsampled 10-bit here).
            if fullColor444 && tenBit && preset.isRawPassthrough {
                configuration.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
                // Requesting a colour space makes SCK convert, and a conversion
                // computed at 10-bit precision fabricates low-order bits out of
                // 8-bit input — which makes the "is this really 10-bit?" probe
                // below meaningless. TB_RAW_NO_COLORSPACE=1 skips it so the
                // captured values are whatever the framebuffer actually holds.
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
            } else if fullColor444 && preset.isRawPassthrough {
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
            } else {
                configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }
            configuration.showsCursor = !largeCursor
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
            if largeCursor { startCursorUpdates(displayID: display.displayID) }
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
        if largeCursor { startCursorUpdates(displayID: displayID) }
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

        guard largeCursor, isStreaming, cursorDisplayID != kCGNullDirectDisplay else { return }
        startCursorUpdates(displayID: cursorDisplayID)
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
        pipeline?.stop()
        pipeline = nil
        isStreaming = false
        liveMetrics.senderFPS = 0
        senderFPS = 0
        videoPathIsRaw = false
        videoPathIsBGRA = false
        videoPathIsTenBit = false
        videoPathDualCable = false
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
                videoPathDualCable = pipeline?.secondaryLinkCarriedFrames ?? false
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }


    // MARK: - Routed audio device

    /// With the Audio Driver addon on, our virtual device *is* the audio path —
    /// there is nothing to choose. It pushes PCM to us over loopback UDP: no
    /// capture session, no microphone permission, and already the exact wire
    /// format, so it bypasses the converter entirely.
    private func startAudioDeviceCaptureIfNeeded() {
        guard audioEnabled, audioDriverAvailable else { return }

        let rx = TBAudioDriverReceiver { [weak self] pcm in
            Task { @MainActor [weak self] in
                guard let self, self.audioEnabled else { return }
                let payload = self.receiverSupportsFloat32Audio ? pcm : Self.int16(fromFloat32: pcm)
                self.send(TBMonitorProtocol.makePacket(type: .audioFrame, payload: payload))
            }
        }
        if rx.start() {
            audioDriverReceiver = rx
            startAudioVolumeMirror(uid: TBAudioDriverReceiver.deviceUID)
        }
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
        audioDriverReceiver?.stop()
        audioDriverReceiver = nil
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
        connection?.send(content: packet, completion: .contentProcessed({ _ in }))
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
