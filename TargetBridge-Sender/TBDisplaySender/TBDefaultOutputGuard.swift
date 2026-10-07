import CoreAudio
import Foundation

/// Stops the Mac being left pointed at a silent device.
///
/// Once the user selects TargetBridge as their output it stays selected after
/// the session ends — the device is still there, so macOS has no reason to
/// switch away and sound simply disappears until someone works out why. This
/// watches which device is default, remembers the last one that wasn't ours,
/// and puts it back when streaming stops.
///
/// A lock-guarded singleton rather than statics: the CoreAudio listener fires
/// on an arbitrary thread, so the remembered device is genuinely shared state.
final class TBDefaultOutputGuard: @unchecked Sendable {

    static let shared = TBDefaultOutputGuard()

    private let lock = NSLock()
    private var previousDeviceID: AudioDeviceID?
    private var listening = false
    /// Fired when the system's default output becomes ours, or stops being ours.
    ///
    /// Choosing our device in Sound settings IS the user asking for audio to go
    /// to the receiver. Without this the app could not tell, so the device could
    /// sit selected while a per-session toggle silently dropped every sample —
    /// the exact "selected and silent" state the driver's liveness probe exists
    /// to prevent. Called on CoreAudio's thread; hop before touching UI state.
    private var onSelectionChanged: ((Bool) -> Void)?
    private var wasOurs = false

    private init() {}

    /// Fresh each time: the CoreAudio calls take it `inout`, so a shared
    /// instance would be mutable state for no benefit.
    private func defaultOutputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func currentDefaultOutput() -> AudioDeviceID? {
        var addr = defaultOutputAddress()
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private func uid(of device: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &cf) == noErr else { return nil }
        return cf as String?
    }

    private func isOurs(_ device: AudioDeviceID) -> Bool {
        uid(of: device) == TBAudioDriverReceiver.deviceUID
    }

    private func noteCurrentDefault() {
        guard let device = currentDefaultOutput() else { return }
        let ours = isOurs(device)

        lock.lock()
        if !ours { previousDeviceID = device }
        let changed = (ours != wasOurs)
        wasOurs = ours
        let notify = onSelectionChanged
        lock.unlock()

        if changed { notify?(ours) }
    }

    /// Observe whether our device is the system output. Replaces any previous
    /// observer; fires immediately with the current state so a caller does not
    /// have to poll to find out where it is starting from.
    func observeSelection(_ handler: @escaping (Bool) -> Void) {
        lock.lock()
        onSelectionChanged = handler
        lock.unlock()
        let ours = currentDefaultOutput().map { isOurs($0) } ?? false
        lock.lock(); wasOurs = ours; lock.unlock()
        handler(ours)
    }

    /// Begin tracking. Safe to call repeatedly.
    func begin() {
        noteCurrentDefault()

        lock.lock()
        let alreadyListening = listening
        listening = true
        lock.unlock()
        guard !alreadyListening else { return }

        var addr = defaultOutputAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.noteCurrentDefault()
        }
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, nil, block)
    }

    /// Any output device that isn't ours, preferring the built-in speakers.
    ///
    /// Needed because the common case has no history to fall back on: if
    /// TargetBridge was already the default when the app launched — which it
    /// will be for anyone using this daily — we never observed a different
    /// device, so there is nothing "previous" to restore. Without this the
    /// guard silently did nothing precisely when it was most needed.
    private func fallbackDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return nil }

        var firstUsable: AudioDeviceID?
        for id in ids where !isOurs(id) {
            // Must actually have output channels — input-only devices and other
            // virtual endpoints would be a pointless place to send audio.
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            if let uid = uid(of: id), uid.contains("BuiltInSpeakerDevice") {
                return id   // the sensible default
            }
            if firstUsable == nil { firstUsable = id }
        }
        return firstUsable
    }

    /// If the Mac is currently pointed at our device, point it back at whatever
    /// it was using before. No-op when the user is on some other device, so a
    /// deliberate choice is never overridden.
    func restoreIfSelected() {
        guard let current = currentDefaultOutput(), isOurs(current) else { return }

        lock.lock()
        let remembered = previousDeviceID
        lock.unlock()

        guard var target = remembered ?? fallbackDevice(), target != current else {
            TBLog.connection.info("audio: TargetBridge selected but no other output device to fall back to")
            return
        }

        var addr = defaultOutputAddress()
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, size, &target)
        if status == noErr {
            TBLog.connection.info("audio: output restored to device \(target, privacy: .public) so sound is not left silent")
        } else {
            TBLog.connection.error("audio: failed to restore output device (\(status, privacy: .public))")
        }
    }

    /// Make our device the system output, remembering what was there before so
    /// `restoreIfSelected()` can put it back when the stream ends.
    ///
    /// The mirror of `restoreIfSelected`, for "switch automatically when
    /// casting starts". No-op when our device is already selected, and when
    /// it is not published at all -- the driver only publishes while a
    /// stream is live, so calling this before the listener is up would find
    /// nothing to select.
    @discardableResult
    func selectOursIfAvailable() -> Bool {
        guard let current = currentDefaultOutput() else { return false }
        if isOurs(current) {
            // Already selected -- by macOS restoring its remembered choice,
            // or by the user. Nothing to do: `restoreIfSelected()` already
            // falls back to `fallbackDevice()` when there is no remembered
            // `previousDeviceID`, and `noteCurrentDefault()` (driven by the
            // property listener `begin()` installs at launch) already
            // records the last non-ours device whenever one was selected, so
            // there is nothing this branch needs to capture.
            return true
        }

        guard var target = ourDevice() else { return false }

        // Remember the real device explicitly rather than relying on the
        // observer having seen it: this runs at session start, and the
        // change notification for the switch below may not have landed yet.
        lock.lock(); previousDeviceID = current; lock.unlock()

        var addr = defaultOutputAddress()
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, size, &target)
        if status == noErr {
            TBTelemetryReporter.emit("audio: output switched to TargetBridge for this stream")
            return true
        }
        TBLog.connection.error("audio: auto-switch failed (\(status, privacy: .public))")
        return false
    }

    /// Wait for the driver to publish the device, then select it.
    ///
    /// A fixed delay does not work: the driver republishes on its first
    /// answered probe, but it probes at 1 Hz and CoreAudio then has to add
    /// the device and notify listeners. Measured with a 1.5 s delay, the log
    /// said "device is not published yet" on most reconnects and succeeded
    /// only when the timing happened to line up (see commit 144a721). So
    /// poll for the device instead of guessing.
    func selectOursWhenPublished(timeout: TimeInterval = 8.0) {
        let deadline = Date().addingTimeInterval(timeout)

        func attempt() {
            if selectOursIfAvailable() { return }
            guard Date() < deadline else {
                TBTelemetryReporter.emit(
                    "audio: auto-switch gave up — device never appeared within \(Int(timeout))s")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { attempt() }
        }
        attempt()
    }

    /// Our published device, or nil when the driver has withdrawn it.
    private func ourDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first(where: { isOurs($0) })
    }
}
