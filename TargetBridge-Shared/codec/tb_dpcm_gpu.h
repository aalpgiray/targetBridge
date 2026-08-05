/* tb_dpcm_gpu.h — TBD2 encoder on the GPU.
 *
 * WHY THIS IS NOT ON THE CPU
 *
 * The reference encoder in tb_dpcm.c costs ~95 ms/frame single-threaded at 5K.
 * Spread over the sender's performance cores it would reach roughly 12 ms, which
 * fits 60 Hz on paper — and is the wrong answer anyway. The sender is the
 * machine somebody is actually using, and spending most of eight cores on video
 * compression to drive a second display is exactly the cost this whole feature
 * exists to avoid. The GPU is idle by comparison.
 *
 * WHY IT IS THREE STEPS
 *
 * No tile's payload position is known until every earlier tile's bit widths are,
 * so the work splits at that dependency:
 *
 *   1. analyze  (GPU)  one threadgroup per tile, one thread per pixel: compute
 *                      every residual, reduce to a bit width per channel, and
 *                      record the tile's seed and its total bit cost.
 *   2. plan     (CPU)  prefix-sum the per-tile costs into the group table and
 *                      each tile's bit offset, and pack the width nibbles. This
 *                      is O(tiles), 1/64th of the per-pixel work, and the host
 *                      has to write the header and read the final length anyway.
 *   3. pack     (GPU)  one thread per (tile, channel), each packing a contiguous
 *                      run of residuals into the payload.
 *
 * Encoding is embarrassingly parallel in a way decoding is not: the encoder
 * predicts from ORIGINAL samples, never reconstructed ones, so no pixel waits on
 * its neighbour. The decoder's prefix-sum trick is unnecessary here.
 *
 * Step 3 needs care about one thing only. Residuals are bit-packed with no
 * padding inside a group, so neighbouring threads share the words at the ends of
 * their runs. Each thread therefore accumulates into a register and writes whole
 * 32-bit words it owns outright, using an atomic OR for just the first and last
 * word of its run — two atomics per thread instead of two per residual, which is
 * 1.4 million rather than 66 million at 5K. Group byte-alignment (see tb_dpcm.h)
 * is what keeps that boundary sharing local to a group.
 */

#ifndef TB_DPCM_GPU_H
#define TB_DPCM_GPU_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tb_dpcm_gpu tb_dpcm_gpu;

/* Build an encoder: device, pipelines, and buffers that are reused across
 * frames. Returns NULL if there is no Metal device or a shader fails to compile,
 * in which case the caller must not offer DPCM at all. */
tb_dpcm_gpu *tb_dpcm_gpu_create(void);
void         tb_dpcm_gpu_destroy(tb_dpcm_gpu *e);

/* Human-readable device name, for logs. Never NULL. */
const char  *tb_dpcm_gpu_device_name(const tb_dpcm_gpu *e);

/* Encode one packed 32-bit frame. `ten_bit` selects ARGB2101010LE over
 * BGRA8888.
 *
 * `header_reserve` bytes are left free immediately BEFORE the blob, so a caller
 * that has to prepend a packet header can write it in place and send one
 * contiguous buffer. Measured worth doing: two copies of a ~30 MB frame is ~3 ms
 * of the 10.1 ms this stage costs per frame, and the memcpy bandwidth was a
 * visible share of the sender's CPU. `*out_blob` points at the start of the
 * reserved region and the return value includes it.
 *
 * Returns the encoded length and, via `out_blob`, a pointer to it. The blob is
 * owned by the encoder and stays valid until the next call — callers are
 * expected to hand it straight to the socket, which is why it is not copied.
 * Returns 0 on failure, leaving `out_blob` untouched.
 *
 * `src` is read without being copied when it is page-aligned, which is the case
 * for the IOSurface-backed pixel buffers ScreenCaptureKit provides, so the frame
 * never crosses the bus twice and the CPU never reads a pixel. Unaligned input
 * is staged through a copy rather than refused. */
size_t tb_dpcm_gpu_encode(tb_dpcm_gpu *e,
                          const uint8_t *src, int stride, int w, int h,
                          int ten_bit, size_t header_reserve,
                          const uint8_t **out_blob);

/* Whether the last encode could read `src` in place. Reported so the sender can
 * say so once rather than guessing about it. */
int tb_dpcm_gpu_last_was_zero_copy(const tb_dpcm_gpu *e);

#ifdef __cplusplus
}
#endif

#endif
