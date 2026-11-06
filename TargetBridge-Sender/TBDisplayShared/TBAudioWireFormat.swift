import Foundation

/// How audio is represented on the loopback hop between the virtual output
/// device and the sender.
///
/// The driver hands over CoreAudio's canonical format: 48 kHz, stereo, 32-bit
/// float, interleaved, native endian. The receiver still plays the existing
/// 16-bit frames (`TB_PKT_AUDIO_FRAME`), so the sender narrows before the
/// packet is built. Nothing on the wire between the two Macs changes.
///
/// The port and the sample layout must match `TargetBridge-AudioDriver/Driver.cpp`.
enum TBAudioWireFormat {

    static let sampleRate = 48000
    static let channelCount = 2
    static let bytesPerSample = MemoryLayout<Float32>.size

    static let bytesPerFrame = channelCount * bytesPerSample

    /// Loopback port inside IANA's dynamic/private range (49152–65535).
    /// Traffic never leaves the loopback interface.
    enum Port {
        /// Output audio, driver → sender. The driver probes this port to
        /// decide whether the device should be published.
        static let output: UInt16 = 51710
    }

    static let loopbackAddress = "127.0.0.1"

    /// Largest datagram written to the loopback socket. Comfortably inside the
    /// loopback MTU so the kernel never fragments one, and a whole number of
    /// frames so a datagram boundary is never a frame boundary — a split frame
    /// would swap left and right for everything after it.
    static let maxDatagram = 1024

    /// Read buffer for a single datagram, with slack.
    static let receiveBufferBytes = maxDatagram * 4

    /// Two's-complement Int16 runs −32768…+32767. Narrowing multiplies by
    /// 32767 and clamps, so +1.0 cannot wrap to the negative rail.
    enum Int16Scale {
        static let fromFloat: Float32 = 32767.0
    }

    /// Float32 → Int16 for the receiver's existing audio frames. Clamped,
    /// because a mix of several apps can exceed full scale and wrapping would
    /// be far more audible than the ceiling.
    static func int16Data(fromFloat32 data: Data) -> Data {
        let count = data.count / MemoryLayout<Float32>.size
        var out = Data(count: count * MemoryLayout<Int16>.size)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let samples = src.bindMemory(to: Float32.self)
                let narrowed = dst.bindMemory(to: Int16.self)
                for n in 0..<count {
                    let v = max(-1.0, min(1.0, samples[n]))
                    narrowed[n] = Int16(v * Int16Scale.fromFloat)
                }
            }
        }
        return out
    }
}
