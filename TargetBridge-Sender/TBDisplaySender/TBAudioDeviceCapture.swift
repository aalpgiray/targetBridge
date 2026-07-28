import AVFoundation
import Foundation

/// Captures a chosen CoreAudio input device and hands out `CMSampleBuffer`s.
///
/// This exists so the receiver's speakers can be driven by a *routed* device
/// rather than by whole-system capture. Point the Mac's output at a loopback
/// device (BlackHole, or eventually our own) and capture its input side here:
/// selection then happens in macOS's own Sound UI, per app, instead of being an
/// all-or-nothing toggle inside TargetBridge.
///
/// `AVCaptureSession` is used rather than `AVAudioEngine` specifically because
/// it yields `CMSampleBuffer`, which the existing audio path already consumes —
/// so nothing downstream changes.
final class TBAudioDeviceCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    /// Audio input devices, loopback or otherwise, in the order macOS reports them.
    static func availableDevices() -> [(name: String, uid: String)] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        ).devices.map { ($0.localizedName, $0.uniqueID) }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.targetbridge.audiodevice", qos: .userInitiated)
    private let onSample: (CMSampleBuffer) -> Void
    private(set) var isRunning = false

    init(onSample: @escaping (CMSampleBuffer) -> Void) {
        self.onSample = onSample
        super.init()
    }

    /// Starts capture from `uid`. Returns false (and logs) rather than throwing,
    /// so a missing or busy device degrades to "no audio" instead of failing the
    /// whole streaming session.
    func start(deviceUID: String) -> Bool {
        guard !isRunning else { return true }
        guard let device = AVCaptureDevice(uniqueID: deviceUID) else {
            TBLog.connection.error("audio device: \(deviceUID, privacy: .public) not found")
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            TBLog.connection.error("audio device: cannot open \(device.localizedName, privacy: .public)")
            return false
        }

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            TBLog.connection.error("audio device: session rejected \(device.localizedName, privacy: .public)")
            return false
        }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()

        session.startRunning()
        isRunning = session.isRunning
        if isRunning {
            TBLog.connection.info("audio device: capturing \(device.localizedName, privacy: .public)")
        } else {
            TBLog.connection.error("audio device: failed to start \(device.localizedName, privacy: .public)")
        }
        return isRunning
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        isRunning = false
        TBLog.connection.info("audio device: stopped")
    }

    /// Ask for microphone access. Capturing a loopback device still counts as
    /// microphone access, so this is required even though no real mic is involved.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        onSample(sampleBuffer)
    }
}
