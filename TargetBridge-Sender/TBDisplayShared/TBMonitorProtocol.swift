import Foundation

enum TBMonitorPacketType: UInt8 {
    case helloReceiver = 0x10
    case displayProfile = 0x11
    case createSessionAck = 0x12
    case uiLanguage = 0x13
    case paramSets = 0x20
    case frame = 0x21
    case rawFrame = 0x22   // Uncompressed NV12 planes (raw passthrough mode)
    case audioFrame = 0x23
    /// A whole frame, losslessly compressed with tile-DPCM (see tb_dpcm.h).
    ///
    /// Covers what damage rectangles cannot: fullscreen video and fast
    /// scrolling, where most of the screen really is new every frame. Measured
    /// 2.96x on near-worst-case photographic content and 4.5-14x on desktop
    /// content, which is enough that the receiver stops needing damage
    /// rectangles at all — a compressed full frame fits inside a 60 Hz period
    /// on its own, so this path sends whole frames and keeps no base image.
    ///
    /// Only sent to a receiver that advertised `supportsDPCM`, which it does
    /// only if its GPU decoder actually built.
    case rawDPCM = 0x25
    /// One horizontal band of a TBD2 frame: a 28-byte header then the blob.
    ///
    /// Lets the stages overlap instead of running end to end — band k decodes on
    /// the receiver while band k+1 is still crossing the wire. The wire is the
    /// slowest stage, so everything else hides behind it and frame latency
    /// roughly halves. Free in bytes: tiles were already independent, so a band
    /// encodes to exactly what the same rows cost inside a whole frame.
    case rawDPCMSlice = 0x26
    case heartbeat = 0x30
    case teardown = 0x31
    case cursor = 0x32
    case inputEvent = 0x33
    case inputControlMode = 0x34
    case brightness = 0x35
    case clipboard = 0x36
    case volume = 0x37
    /// Night Shift / True Tone on the receiver's panel.
    case displayTweaks = 0x38
    /// Receiver's microphone, receiver -> sender: raw 48 kHz stereo Int16.
    case micFrame = 0x39
    case testData = 0x40
    /// The receiver's stderr, raw UTF-8, no framing beyond the packet itself.
    ///
    /// The receiver runs on the other Mac, so every measurement used to mean
    /// asking whoever sits there to copy a log out of a terminal. That is slow
    /// enough to discourage measuring, and this project has repeatedly lost
    /// hours to theories a single log would have killed in a minute. The sender
    /// appends these to a file so both sides can be read from one machine.
    case receiverLog = 0x41

    /// The receiver's mean `nextDrawable` wait, receiver -> sender, once a second.
    /// Big endian: `UInt32` microseconds, `UInt32` sample count.
    ///
    /// We choose the instant each frame is sent, but only the receiver can see
    /// where that instant lands inside its own refresh cycle. A wait near zero
    /// means a drawable was free; a wait near a full refresh means the pool was
    /// exhausted and we are arriving at the worst possible moment. Since both
    /// clocks are now stable to about a millisecond, that state persists for
    /// minutes instead of averaging away — so this is the error signal the sender
    /// needs to walk its schedule out of it. See the phase controller in
    /// `TBDisplaySenderService`.
    case phaseReport = 0x43

    /// The real cursor bitmap, sent only when the cursor CHANGES shape.
    ///
    /// The alternative was to draw each cursor from geometry on the receiver,
    /// which already exists for eight types in the SDL path and is ~300 lines
    /// that must be kept in step with a second copy in the Metal path. Sending
    /// the actual image is less code, always correct, and covers cursors we
    /// could never enumerate — application-custom ones included.
    ///
    /// Cost is nil in the steady state: a cursor bitmap is a few KB and changes
    /// only when you move between a text field and a button, while positions
    /// keep flowing on `cursor` (0x32) at 120 Hz.
    ///
    /// Payload is little-endian, header then premultiplied RGBA8 rows:
    ///   uint16 width, uint16 height, int16 hotspotX, int16 hotspotY, pixels…
    case cursorImage = 0x42
}

struct TBMonitorHelloReceiver: Codable {
    var senderName: String
    var uiLanguage: String?
    var capturePreset: String?
    var captureSource: String?
    var captureWidth: Int?
    var captureHeight: Int?
    var codec: String?
    /// "f32" or "s16". Lets a newer receiver tell what an older sender is
    /// sending: absent means Int16, which is what senders sent before this.
    var audioFormat: String?
}

struct TBMonitorDisplayProfile: Codable {
    var receiverName: String
    var panelWidth: Int
    var panelHeight: Int
    var modeWidth: Int
    var modeHeight: Int
    var refreshRate: Double
    var hiDPI: Bool
    var captureWidth: Int
    var captureHeight: Int
    var supportsHEVCDecode: Bool?
    var supportsRawNV12: Bool?
    /// Absent on receivers older than the Float32 audio change, which is the
    /// point: audio stays Int16 for them rather than arriving as noise.
    var supportsFloat32Audio: Bool?
    /// Whether the receiver can decode tile-DPCM frames on its GPU. Absent means
    /// no, which is also what an older receiver says by saying nothing. The
    /// receiver only claims this if the compute pipeline actually built, since
    /// decoding on a CPU is far too slow at 5K to stand in.
    var supportsDPCM: Bool?
    /// Whether the receiver can place a band at a row offset and present only on
    /// the last one. Absent means whole frames only.
    var supportsDPCMSlices: Bool?
    /// Whether the receiver can place a region by column as well as row, i.e.
    /// accept damage rects. Absent means no, which is also what an older
    /// receiver says by saying nothing.
    var supportsDPCMRects: Bool?
    var inputMonitoringTrusted: Bool?
    var accessibilityTrusted: Bool?
    /// Optional so older receivers still decode; absent means "cannot".
    var supportsNightShift: Bool?
    var supportsTrueTone: Bool?
}

struct TBMonitorCreateSessionAck: Codable {
    var accepted: Bool
    var displayName: String
    var displayID: UInt32
}

struct TBMonitorUILanguageUpdate: Codable {
    var uiLanguage: String
}

struct TBMonitorHeartbeat: Codable {
    var sequence: UInt64
}

struct TBMonitorTeardown: Codable {
    var reason: String
}

struct TBMonitorCursor: Codable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var visible: Bool
    var type: Int
}

struct TBMonitorInputEvent: Codable {
    var kind: String
    var dx: Int?
    var dy: Int?
    var scrollX: Int?
    var scrollY: Int?
    var keyCode: UInt16?
}

struct TBMonitorInputControlMode: Codable {
    var mode: String
}

struct TBMonitorBrightness: Codable {
    var level: Double
}

struct TBMonitorVolume: Codable {
    var level: Double
}

struct TBMonitorDisplayTweaks: Codable {
    var nightShift: Bool
    var trueTone: Bool
    /// Whether the receiver waits for its display's refresh boundary before
    /// presenting. Off trades tearing for up to a refresh period of latency
    /// (~8 ms at 60 Hz), which measured as the largest addressable term left in
    /// the end-to-end budget.
    ///
    /// Optional so an older receiver — which ignores the key — and an older
    /// sender — which omits it, leaving the receiver's default of on — both keep
    /// working.
    var vsync: Bool?
}

struct TBMonitorClipboard: Codable {
    var text: String
}

/// Framing-level corruption that cannot be recovered by waiting for more
/// bytes. The connection carrying the stream should be torn down.
enum TBMonitorProtocolError: Error, Equatable, CustomStringConvertible {
    case invalidPacketLength(UInt32)

    var description: String {
        switch self {
        case .invalidPacketLength(let length):
            return "invalid packet length \(length)"
        }
    }
}

enum TBMonitorProtocol {
    static let port: UInt16 = 54321

    /// Upper bound for a single packet's declared length. Mirrors the
    /// receiver's parser sanity check (net.c) so both ends agree on what a
    /// corrupt length prefix is. Without this cap, a corrupted 4-byte length
    /// (e.g. 0xFFFFFFFF) would make the drain loop buffer inbound data
    /// forever, waiting for a packet that can never complete.
    static let maxPacketLength: UInt32 = 64 * 1024 * 1024

    /// Bytes of framing every packet carries: a big-endian length, then the type.
    static let headerSize = 5

    /// Frame a payload whose producer already left `headerSize` bytes in front of
    /// it, writing the header in place. `base` points at the reserved run and
    /// `totalCount` spans header and payload together.
    ///
    /// Exists to avoid a second copy of a very large payload: `makePacket` has to
    /// concatenate, which at ~30 MB a frame was measurable both in latency and in
    /// memcpy bandwidth on the sender's CPU.
    static func framedPacket(type: TBMonitorPacketType,
                             base: UnsafePointer<UInt8>,
                             totalCount: Int) -> Data {
        let mutable = UnsafeMutablePointer(mutating: base)
        let payloadCount = totalCount - headerSize
        let framed = UInt32(1 + payloadCount)
        mutable[0] = UInt8((framed >> 24) & 0xFF)
        mutable[1] = UInt8((framed >> 16) & 0xFF)
        mutable[2] = UInt8((framed >>  8) & 0xFF)
        mutable[3] = UInt8( framed        & 0xFF)
        mutable[4] = type.rawValue
        // MEASURED: this copy is the candidate for the sender's unexplained CPU.
        //
        // Encode is already on the GPU and the instrumented stages total ~2ms a
        // frame, yet the process burns ~64% CPU with three quarters of it in user
        // time -- so the cost is outside the timed stages. At 5K lossless this
        // copies the whole encoded frame (~15-30MB) per frame, ~4 slices, 60fps:
        // on the order of 1-2 GB/s of memcpy plus an allocation per slice.
        //
        // The copy is not gratuitous: the GPU encoder recycles the band slot the
        // moment the callback returns, so the bytes must be taken before then.
        // Removing it needs a refcounted buffer pool, which is only worth the risk
        // if this is actually expensive. Hence the timer rather than a rewrite.
        let t0 = DispatchTime.now().uptimeNanoseconds
        let out = Data(bytes: base, count: totalCount)
        TBPacketCopyStats.note(nanos: DispatchTime.now().uptimeNanoseconds - t0,
                               bytes: totalCount)
        return out
    }

    /// Running cost of the packet copy, reported once a second alongside the
    /// other stage timings so it can be compared against them directly.
    enum TBPacketCopyStats {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var nanos: UInt64 = 0
        nonisolated(unsafe) private static var bytes: Int = 0
        nonisolated(unsafe) private static var calls: Int = 0
        nonisolated(unsafe) private static var lastReport: UInt64 = 0

        static func note(nanos n: UInt64, bytes b: Int) {
            lock.lock()
            nanos += n; bytes += b; calls += 1
            let now = DispatchTime.now().uptimeNanoseconds
            if lastReport == 0 { lastReport = now }
            let elapsed = now - lastReport
            guard elapsed >= 1_000_000_000 else { lock.unlock(); return }
            let ms = Double(nanos) / 1_000_000.0
            let mb = Double(bytes) / 1_048_576.0
            let pct = Double(nanos) / Double(elapsed) * 100.0
            let n = calls
            nanos = 0; bytes = 0; calls = 0; lastReport = now
            lock.unlock()
            TBLog.connection.info("packet copy: \(String(format: "%.1f", ms), privacy: .public) ms/s (\(String(format: "%.1f", pct), privacy: .public)% of one core) | \(String(format: "%.0f", mb), privacy: .public) MB/s | \(n, privacy: .public) copies")
            TBReceiverLogSink.shared.note("packet copy: \(String(format: "%.1f", ms)) ms/s (\(String(format: "%.1f", pct))% of one core) | \(String(format: "%.0f", mb)) MB/s | \(n) copies")
        }
    }

    /// Bytes of the TBD2 slice header, between the packet header and the blob.
    static let sliceHeaderSize = 28

    /// Write the slice header into space the encoder reserved ahead of the blob,
    /// then frame the whole thing. `base` points at the packet header, so the
    /// slice header follows it and the blob follows that — one contiguous buffer,
    /// one copy.
    static func framedSlicePacket(base: UnsafePointer<UInt8>,
                                  totalCount: Int,
                                  captureTimeNanos: UInt64,
                                  frameID: UInt32,
                                  frameW: UInt32, frameH: UInt32,
                                  y0: UInt32,
                                  index: UInt16, count: UInt16) -> Data {
        let p = UnsafeMutablePointer(mutating: base) + headerSize
        var o = 0
        func put32(_ v: UInt32) {
            p[o] = UInt8((v >> 24) & 0xFF); p[o+1] = UInt8((v >> 16) & 0xFF)
            p[o+2] = UInt8((v >> 8) & 0xFF); p[o+3] = UInt8(v & 0xFF); o += 4
        }
        func put16(_ v: UInt16) {
            p[o] = UInt8((v >> 8) & 0xFF); p[o+1] = UInt8(v & 0xFF); o += 2
        }
        put32(UInt32(truncatingIfNeeded: captureTimeNanos >> 32))
        put32(UInt32(truncatingIfNeeded: captureTimeNanos))
        put32(frameID)
        put32(frameW)
        put32(frameH)
        put32(y0)
        put16(index)
        put16(count)
        return framedPacket(type: .rawDPCMSlice, base: base, totalCount: totalCount)
    }
    static func makePacket(type: TBMonitorPacketType, payload: Data) -> Data {
        var packet = Data()
        appendBE32(&packet, UInt32(1 + payload.count))
        packet.append(type.rawValue)
        packet.append(payload)
        return packet
    }

    static func makeJSONPacket<T: Encodable>(type: TBMonitorPacketType, value: T) -> Data? {
        let encoder = JSONEncoder()
        guard let payload = try? encoder.encode(value) else { return nil }
        return makePacket(type: type, payload: payload)
    }

    /// Hand-rolled encoder for the input-event hot path. Mouse move/drag events
    /// fire at display refresh rate (or faster with high-poll-rate mice), and a
    /// fresh `JSONEncoder` per event is the busiest allocator in that path. This
    /// emits the same JSON shape `JSONDecoder` reconstructs into a
    /// `TBMonitorInputEvent` (omitted fields decode as nil), mirroring the
    /// receiver's `snprintf`-based emitter. `kind` is always a fixed literal from
    /// the event converter, so no string escaping is required.
    static func makeInputEventPacket(_ event: TBMonitorInputEvent) -> Data {
        var json = "{\"kind\":\"\(event.kind)\""
        if let dx = event.dx { json += ",\"dx\":\(dx)" }
        if let dy = event.dy { json += ",\"dy\":\(dy)" }
        if let scrollX = event.scrollX { json += ",\"scrollX\":\(scrollX)" }
        if let scrollY = event.scrollY { json += ",\"scrollY\":\(scrollY)" }
        if let keyCode = event.keyCode { json += ",\"keyCode\":\(keyCode)" }
        json += "}"
        return makePacket(type: .inputEvent, payload: Data(json.utf8))
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from payload: Data) -> T? {
        let decoder = JSONDecoder()
        return try? decoder.decode(type, from: payload)
    }

    /// Drains the next complete packet from `buffer`.
    ///
    /// - Returns: the packet, or `nil` when the buffer does not yet hold a
    ///   complete packet (more bytes are needed).
    /// - Throws: `TBMonitorProtocolError.invalidPacketLength` when the length
    ///   prefix is corrupt (zero or above `maxPacketLength`); the stream is
    ///   unrecoverable and the caller should close the connection.
    ///
    /// Packets with an unrecognized type byte (e.g. from a newer peer) are
    /// skipped and draining continues with the next packet, so one unknown
    /// packet cannot stall the packets queued behind it.
    static func drainPacket(from buffer: inout Data) throws -> (TBMonitorPacketType, Data)? {
        while buffer.count >= 5 {
            let packetLength = readBE32(buffer, offset: 0)
            guard packetLength >= 1, packetLength <= maxPacketLength else {
                throw TBMonitorProtocolError.invalidPacketLength(packetLength)
            }
            let packetEnd = 4 + Int(packetLength)
            guard buffer.count >= packetEnd else { return nil }
            let typeByte = buffer[4]
            let payload = buffer.subdata(in: 5..<packetEnd)
            buffer.removeSubrange(0..<packetEnd)
            if let packetType = TBMonitorPacketType(rawValue: typeByte) {
                return (packetType, payload)
            }
        }
        return nil
    }

    static func appendBE32(_ data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    static func readBE32(_ data: Data, offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
    }
}
