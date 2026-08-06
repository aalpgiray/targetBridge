import CoreMedia
import CoreVideo
import Foundation
import Network

/// Everything a frame needs once the GPU has finished with it.
///
/// The encoder returns before the GPU has read a single pixel, so this holds the
/// things that must outlive the call: the pixel buffer (locked, and referenced,
/// or ScreenCaptureKit recycles it under the GPU), and the packet header fields
/// that were true at capture time rather than at completion time.
final class TBDPCMFrameContext {
    /// Retained for its LIFETIME, not for its contents.
    ///
    /// Holding the CVPixelBuffer alone keeps the memory valid, which is why
    /// nothing crashed -- but in ScreenCaptureKit the SAMPLE buffer is what owns
    /// the surface's place in the pool. Without this, SCK considers the surface
    /// available and writes the next frame into it while the GPU is still
    /// reading it for this one.
    ///
    /// The result was complete, in-order frames containing the wrong pixels: a
    /// stale image alternating with live ones, seen as a flicker. Every delivery
    /// counter stayed clean -- 0 incomplete, 0 bands lost, 0 drops -- because
    /// delivery was never the problem. The bytes were simply the wrong bytes.
    let sampleBuffer: CMSampleBuffer
    let pixelBuffer: CVPixelBuffer
    let captureNanos: UInt64
    let frameID: UInt32
    let sliceCount: Int
    let rowsPerBand: Int
    let width: Int
    let height: Int
    let send: (Data) -> Void
    /// Called with the total encoded size, on the encoder's queue. Lets the
    /// pipeline do its once-per-session ratio log without this type knowing
    /// anything about logging.
    let finished: (Int, Bool) -> Void

    init(sampleBuffer: CMSampleBuffer,
         pixelBuffer: CVPixelBuffer,
         captureNanos: UInt64,
         frameID: UInt32,
         sliceCount: Int,
         rowsPerBand: Int,
         width: Int,
         height: Int,
         send: @escaping (Data) -> Void,
         finished: @escaping (Int, Bool) -> Void) {
        self.sampleBuffer = sampleBuffer
        self.pixelBuffer = pixelBuffer
        self.captureNanos = captureNanos
        self.frameID = frameID
        self.sliceCount = sliceCount
        self.rowsPerBand = rowsPerBand
        self.width = width
        self.height = height
        self.send = send
        self.finished = finished
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    }

    deinit {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }

    // KEEP THIS LOCK. Removing it is correct on paper and measurably worse.
    //
    // The reasoning for dropping it was sound: a CVPixelBuffer lock governs CPU
    // access, the GPU reads the IOSurface directly, and retaining the sample
    // buffer already keeps the surface alive. It removed the 3.6-11 ms `lock`
    // stage and the sender's own numbers stayed perfect at 100%/100%.
    //
    // The RECEIVER went from presenting 1:240 (100%) to 1:190 (80%) with 8% of
    // frames bunched into pairs, consistently, across every window.
    //
    // Because the lock was accidental backpressure. Held across the encode, the
    // capture thread blocks on the NEXT frame's lock until an earlier encode
    // finishes, which spaces submissions -- and so completions, and so packets.
    // Without it the thread submits freely, encodes finish in bursts, and
    // packets leave bunched. `send(wall)` cannot see this: it is sampled at
    // submission, while the packets are actually emitted later from the
    // completion callback.
    //
    // Losing 3.6 ms on a thread with 13 ms of headroom to gain even packet
    // emission is a good trade. If this is revisited, replace it with DELIBERATE
    // pacing rather than simply deleting it.
}

/// C callback for `tb_dpcm_gpu_encode_bands_async`.
///
/// Runs on the encoder's own serial queue, NOT the capture queue — which is the
/// entire point: the capture callback returned as soon as the work was
/// submitted. Packets are built and handed to the socket from here.
///
/// `bands` is valid only for the duration of this call; the encoder recycles the
/// slot the moment it returns. `framedSlicePacket` copies into a Data, so that
/// is respected by construction.
let tbDPCMAsyncDone: tb_dpcm_gpu_done = { ctx, ok, bands, count in
    guard let ctx else { return }
    // Balanced against the passRetained at submission. Taking it here is what
    // releases the pixel buffer and unlocks it.
    let frame = Unmanaged<TBDPCMFrameContext>.fromOpaque(ctx).takeRetainedValue()

    guard ok != 0, let bands else {
        frame.finished(0, false)
        return
    }

    var total = 0
    for band in 0..<Int(count) {
        let entry = bands[band]
        guard let blob = entry.blob else { continue }
        total += entry.len

        let packet: Data
        if frame.sliceCount > 1 {
            packet = TBMonitorProtocol.framedSlicePacket(
                base: blob, totalCount: entry.len,
                captureTimeNanos: frame.captureNanos,
                frameID: frame.frameID,
                frameW: UInt32(frame.width), frameH: UInt32(frame.height),
                y0: UInt32(band * frame.rowsPerBand),
                index: UInt16(band), count: UInt16(frame.sliceCount))
        } else {
            packet = TBMonitorProtocol.framedPacket(
                type: .rawDPCM, base: blob, totalCount: entry.len)
        }
        frame.send(packet)
    }
    frame.finished(total, true)
}
