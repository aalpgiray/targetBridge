// TargetBridge audio driver — a virtual output device that forwards whatever
// macOS routes to it, so the receiver Mac's speakers can be chosen from the
// system's own Sound UI (and per app) rather than from a toggle in our app.
//
// Two deliberate differences from an off-the-shelf loopback device such as
// BlackHole:
//
//  1. The volume control reports its level but does NOT scale the samples.
//     A loopback device attenuates digitally before we ever capture the audio,
//     which throws away dynamic range *and* leaves the receiver's amplifier at
//     whatever it was — turning its slider down made the sound quieter twice
//     over. Here the level is published for the sender to read and apply as the
//     receiver's hardware volume, while the audio itself passes at unity.
//
//  2. Audio is pushed straight to the sender over loopback UDP instead of being
//     exposed as an input device. That means no input stream, and therefore no
//     microphone permission — capturing a loopback device otherwise counts as
//     mic access, which is a confusing prompt for something that never touches
//     a microphone.
//
// Built on libASPL (MIT, vendored under vendor/libASPL).

#include <aspl/Driver.hpp>

// VolumeCurve lives in libASPL's src/, not its public headers, but
// VolumeControl holds a unique_ptr to it — so subclassing VolumeControl needs
// the complete type for the implicit destructor. Hence src/ on the include path.
#include "VolumeCurve.hpp"

#include <CoreAudio/AudioServerPlugIn.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>

namespace {

// Fixed loopback endpoint. The sender binds this port; if nothing is listening
// the datagrams are simply dropped, so audio routed here while TargetBridge is
// closed is harmless rather than an error.
constexpr const char* kSinkAddr = "127.0.0.1";
constexpr short kSinkPort = 51710;
constexpr UInt32 kMaxDatagram = 1024;

constexpr UInt32 kSampleRate = 48000;   // matches the wire format the receiver expects
constexpr UInt32 kChannelCount = 2;

constexpr const char* kDeviceName = "TargetBridge";
constexpr const char* kDeviceUID = "TargetBridgeAudioDevice_UID";
constexpr const char* kManufacturer = "TargetBridge";

// Volume control that publishes a level without touching the audio. See (1) above.
class ReportingOnlyVolumeControl : public aspl::VolumeControl
{
public:
    using aspl::VolumeControl::VolumeControl;

    // Deliberately empty: the level is metadata for the sender, not gain to
    // apply here. Overriding this is the entire reason for a custom control.
    void ApplyProcessing(Float32*, UInt32, UInt32) const override
    {
    }
};

class TargetBridgeHandler : public aspl::ControlRequestHandler,
                            public aspl::IORequestHandler
{
public:
    // Control thread, before the first I/O request.
    OSStatus OnStartIO() override
    {
        const int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (fd == -1) {
            return kAudioHardwareUnspecifiedError;
        }

        sockaddr_in addr = {};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kSinkPort);
        inet_pton(AF_INET, kSinkAddr, &addr.sin_addr);

        // connect() on a datagram socket just fixes the peer, so the realtime
        // path can send() without carrying an address around.
        if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == -1) {
            close(fd);
            return kAudioHardwareUnspecifiedError;
        }

        socket_.store(fd);
        return kAudioHardwareNoError;
    }

    // Control thread, after the last I/O request.
    void OnStopIO() override
    {
        const int fd = socket_.exchange(-1);
        if (fd != -1) {
            close(fd);
        }
    }

    // Realtime I/O thread. Must not block, allocate, or lock — hence
    // MSG_DONTWAIT and no error handling beyond ignoring the result: a full or
    // absent receiver must never stall the audio thread.
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* buff,
        UInt32 buffBytesSize) override
    {
        const int fd = socket_.load();
        if (fd == -1) {
            return;
        }

        auto* bytes = reinterpret_cast<const UInt8*>(buff);
        while (buffBytesSize != 0) {
            const UInt32 chunk = std::min(buffBytesSize, kMaxDatagram);
            (void)send(fd, bytes, chunk, MSG_DONTWAIT);
            bytes += chunk;
            buffBytesSize -= chunk;
        }
    }

private:
    std::atomic<int> socket_ { -1 };
};

std::shared_ptr<aspl::Driver> CreateTargetBridgeDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = kDeviceName;
    deviceParams.DeviceUID = kDeviceUID;
    deviceParams.Manufacturer = kManufacturer;
    deviceParams.SampleRate = kSampleRate;
    deviceParams.ChannelCount = kChannelCount;
    // Mix all clients together: this is a normal output device, so several apps
    // may be playing to it at once.
    deviceParams.EnableMixing = true;

    auto device = std::make_shared<aspl::Device>(context, deviceParams);

    // Output only — no input stream, so no microphone permission. See (2) above.
    // AddStreamAsync (rather than AddStreamWithControlsAsync) so no default
    // volume control is created; we attach our own reporting-only one instead.
    auto stream = device->AddStreamAsync(aspl::Direction::Output);

    aspl::VolumeControlParameters volumeParams;
    volumeParams.Scope = kAudioObjectPropertyScopeOutput;
    auto volume = std::make_shared<ReportingOnlyVolumeControl>(context, volumeParams);
    stream->AttachVolumeControl(volume);

    auto handler = std::make_shared<TargetBridgeHandler>();
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* TargetBridgeAudioDriverFactory(CFAllocatorRef, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    // Held for the lifetime of the process: coreaudiod keeps the driver loaded.
    static std::shared_ptr<aspl::Driver> driver = CreateTargetBridgeDriver();

    return driver->GetReference();
}
