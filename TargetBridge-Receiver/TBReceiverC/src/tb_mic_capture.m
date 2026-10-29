/* tb_mic_capture.m — capture this Mac's microphone for the sender.
 *
 * The sender feeds it into the TargetBridge virtual audio device's input
 * stream, so the receiver Mac's mic can be picked on the sender like a local
 * one. Output is 48 kHz stereo Float32 — the same format everything else on the
 * wire uses, so no conversion happens anywhere along the path. A mono mic is
 * duplicated to both channels here rather than sending mono and widening later.
 */

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include "tb_mic_capture.h"
#include "proto.h"   /* AUDIO_* — the wire format this must match */

#include <stdatomic.h>
#include <stdio.h>

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

    /* The session is configured for Float32; if the channel count is 1, widen to
     * stereo so the wire format is uniform. */
    if (asbd->mChannelsPerFrame == 2) {
        self.callback((const uint8_t *)data, length, self.userData);
        return;
    }
    if (asbd->mChannelsPerFrame != 1) return;

    const size_t frames = length / sizeof(float);
    float *stereo = (float *)malloc(frames * 2 * sizeof(float));
    if (!stereo) return;
    const float *mono = (const float *)data;
    for (size_t i = 0; i < frames; ++i) {
        stereo[i * 2] = mono[i];
        stereo[i * 2 + 1] = mono[i];
    }
    self.callback((const uint8_t *)stereo, frames * 2 * sizeof(float), self.userData);
    free(stereo);
}

@end

static AVCaptureSession *g_session = nil;
static TBMicDelegate *g_delegate = nil;
static dispatch_queue_t g_mic_q = nil;
static _Atomic int g_mic_wanted = 0;
static tb_mic_cb g_mic_cb = NULL;
static void *g_mic_user = NULL;

/* startRunning and stopRunning run only on g_mic_q. AVCaptureSession
 * startRunning is synchronous and blocks in CoreAudio. Measured 2026-10-29
 * on the iMac, twice, while a system-sleep request had been made and had not
 * completed: each accept stalled the main thread for 7.2s between
 * "input capture disabled" and "[mic] capturing", and the second dial paid
 * that cost again because the first session was stopped and opened over.
 * The main thread only sets g_mic_wanted and enqueues the work. */

static void tb_mic_ensure_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_mic_q = dispatch_queue_create("com.targetbridge.mic.open", DISPATCH_QUEUE_SERIAL);
    });
}

static void tb_mic_worker_apply(void) {
    if (!atomic_load(&g_mic_wanted)) {
        if (!g_session) return;
        [g_session stopRunning];
        g_session = nil;
        g_delegate = nil;
        fprintf(stderr, "[mic] capture stopped\n");
        return;
    }
    if (g_session) {
        fprintf(stderr, "[mic] capture already running; keeping it\n");
        return;
    }

    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            (void)granted;
        }];
        fprintf(stderr, "[mic] not started (microphone permission pending)\n");
        return;
    }

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (!device) {
        fprintf(stderr, "[mic] no input device\n");
        return;
    }

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) {
        fprintf(stderr, "[mic] input device failed: %s\n",
                error.localizedDescription.UTF8String ?: "unknown");
        return;
    }

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    if (![session canAddInput:input]) return;
    [session addInput:input];

    AVCaptureAudioDataOutput *out = [[AVCaptureAudioDataOutput alloc] init];
    out.audioSettings = @{
        AVFormatIDKey:              @(kAudioFormatLinearPCM),
        AVSampleRateKey:            @(AUDIO_SAMPLE_RATE),
        AVNumberOfChannelsKey:      @(AUDIO_CHANNELS),
        AVLinearPCMBitDepthKey:     @(AUDIO_BYTES_PER_SAMPLE * 8),
        AVLinearPCMIsFloatKey:      @YES,
        AVLinearPCMIsBigEndianKey:  @NO,
        AVLinearPCMIsNonInterleaved:@NO,
    };

    TBMicDelegate *delegate = [[TBMicDelegate alloc] init];
    delegate.callback = g_mic_cb;
    delegate.userData = g_mic_user;
    dispatch_queue_t samples = dispatch_queue_create("com.targetbridge.mic", DISPATCH_QUEUE_SERIAL);
    [out setSampleBufferDelegate:delegate queue:samples];

    if (![session canAddOutput:out]) return;
    [session addOutput:out];

    /* Blocks this queue, not the main thread. */
    [session startRunning];
    if (!atomic_load(&g_mic_wanted) || !session.isRunning) {
        if (session.isRunning) [session stopRunning];
        if (!session.isRunning)
            fprintf(stderr, "[mic] capture did not start\n");
        return;
    }
    g_session = session;
    g_delegate = delegate;
    fprintf(stderr, "[mic] capturing and streaming to sender\n");
}

int tb_mic_capture_start(tb_mic_cb cb, void *user_data) {
    tb_mic_ensure_queue();
    if (!g_mic_q) return -1;
    g_mic_cb = cb;
    g_mic_user = user_data;
    atomic_store(&g_mic_wanted, 1);
    dispatch_async(g_mic_q, ^{
        @autoreleasepool {
            tb_mic_worker_apply();
        }
    });
    return 0;
}

void tb_mic_capture_stop(void) {
    atomic_store(&g_mic_wanted, 0);
    if (!g_mic_q) return;
    dispatch_async(g_mic_q, ^{
        @autoreleasepool {
            tb_mic_worker_apply();
        }
    });
}

int tb_mic_capture_available(void) {
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio] != nil ? 1 : 0;
}
