/* tb_mic_capture.m — capture this Mac's microphone for the sender.
 *
 * The sender feeds it into the TargetBridge virtual audio device's input
 * stream, so the receiver Mac's mic can be picked on the sender like a local
 * one. Output is 48 kHz stereo Int16 — the same format everything else on the
 * wire uses, so no conversion happens anywhere along the path. A mono mic is
 * duplicated to both channels here rather than sending mono and widening later.
 */

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include "tb_mic_capture.h"

@interface TBMicDelegate : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, assign) tb_mic_cb callback;
@property (nonatomic, assign) void *userData;
@end

@implementation TBMicDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if (!self.callback) return;

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!block) return;

    size_t length = 0;
    char *data = NULL;
    if (CMBlockBufferGetDataPointer(block, 0, NULL, &length, &data) != kCMBlockBufferNoErr) return;
    if (!data || length == 0) return;

    const CMAudioFormatDescriptionRef fmt =
        (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd =
        fmt ? CMAudioFormatDescriptionGetStreamBasicDescription(fmt) : NULL;
    if (!asbd) return;

    /* The session is configured for Int16; if the channel count is 1, widen to
     * stereo so the wire format is uniform. */
    if (asbd->mChannelsPerFrame == 2) {
        self.callback((const uint8_t *)data, length, self.userData);
        return;
    }
    if (asbd->mChannelsPerFrame != 1) return;

    const size_t frames = length / sizeof(int16_t);
    int16_t *stereo = (int16_t *)malloc(frames * 2 * sizeof(int16_t));
    if (!stereo) return;
    const int16_t *mono = (const int16_t *)data;
    for (size_t i = 0; i < frames; ++i) {
        stereo[i * 2] = mono[i];
        stereo[i * 2 + 1] = mono[i];
    }
    self.callback((const uint8_t *)stereo, frames * 2 * sizeof(int16_t), self.userData);
    free(stereo);
}

@end

static AVCaptureSession *g_session = nil;
static TBMicDelegate *g_delegate = nil;

int tb_mic_capture_start(tb_mic_cb cb, void *user_data) {
    if (g_session) return 0;

    /* Requesting access is asynchronous the first time; if it has not been
     * granted yet, bail and let the caller retry once the user has answered. */
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            (void)granted;
        }];
        return -1;
    }

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (!device) return -1;

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) return -1;

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    if (![session canAddInput:input]) return -1;
    [session addInput:input];

    AVCaptureAudioDataOutput *out = [[AVCaptureAudioDataOutput alloc] init];
    out.audioSettings = @{
        AVFormatIDKey:              @(kAudioFormatLinearPCM),
        AVSampleRateKey:            @48000,
        AVNumberOfChannelsKey:      @2,
        AVLinearPCMBitDepthKey:     @16,
        AVLinearPCMIsFloatKey:      @NO,
        AVLinearPCMIsBigEndianKey:  @NO,
        AVLinearPCMIsNonInterleaved:@NO,
    };

    TBMicDelegate *delegate = [[TBMicDelegate alloc] init];
    delegate.callback = cb;
    delegate.userData = user_data;
    dispatch_queue_t queue = dispatch_queue_create("com.targetbridge.mic", DISPATCH_QUEUE_SERIAL);
    [out setSampleBufferDelegate:delegate queue:queue];

    if (![session canAddOutput:out]) return -1;
    [session addOutput:out];

    [session startRunning];
    if (!session.isRunning) return -1;

    g_session = session;
    g_delegate = delegate;
    return 0;
}

void tb_mic_capture_stop(void) {
    if (!g_session) return;
    [g_session stopRunning];
    g_session = nil;
    g_delegate = nil;
}

int tb_mic_capture_available(void) {
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio] != nil ? 1 : 0;
}
