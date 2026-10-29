/* tb_mic_capture.h — capture this Mac's microphone and hand it to the sender.
 * Delivers 48 kHz stereo interleaved Int16, matching the rest of the wire
 * format so nothing converts along the way. */

#ifndef TB_MIC_CAPTURE_H
#define TB_MIC_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Called on a private queue, not the main thread. */
typedef void (*tb_mic_cb)(const uint8_t *pcm, size_t bytes, void *user_data);

/* 1 if this Mac has an audio input device at all. */
int  tb_mic_capture_available(void);

/* 0 once the open has been requested. startRunning runs on a private queue
 * and does not block the caller. A later call while that open is in flight,
 * or while capture is already running, keeps the one session. -1 only if
 * the queue itself could not be created. Permission failures are logged
 * from the queue; the next start retries. */
int  tb_mic_capture_start(tb_mic_cb cb, void *user_data);
void tb_mic_capture_stop(void);

#ifdef __cplusplus
}
#endif

#endif
