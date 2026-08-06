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

    init(pixelBuffer: CVPixelBuffer,
         captureNanos: UInt64,
         frameID: UInt32,
         sliceCount: Int,
         rowsPerBand: Int,
         width: Int,
         height: Int,
         send: @escaping (Data) -> Void,
         finished: @escaping (Int, Bool) -> Void) {
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
