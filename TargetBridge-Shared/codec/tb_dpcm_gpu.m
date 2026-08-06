/* tb_dpcm_gpu.m — TBD2 encoder on the GPU. See tb_dpcm_gpu.h for the shape of
 * the pipeline and why it is split the way it is.
 *
 * Everything the shaders and the host both need to agree on — the tile walk, the
 * residual transform, the group alignment rule — is duplicated here from
 * tb_dpcm.c because MSL cannot include C. That duplication is the main hazard in
 * this file, so it is verified rather than trusted: the encoder's output is
 * compared byte-for-byte against tb_dpcm_encode's, which is the only reason to
 * believe any of it.
 */

#import <Metal/Metal.h>

#include "tb_dpcm_gpu.h"
#include "tb_dpcm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Mirrors EncParams in the shader. */
struct enc_params {
    uint32_t width, height;
    uint32_t tilesX, tilesY;
    uint32_t tileCount;
    uint32_t srcStridePx;
    uint32_t bits;
    uint32_t mask;
    /* Named `mid`, not `half`: `half` is a reserved type in Metal Shading
     * Language (half-precision float) and a member of that name will not parse. */
    uint32_t mid;
};

struct tb_dpcm_gpu {
    id<MTLDevice>               dev;
    id<MTLCommandQueue>         queue;
    id<MTLComputePipelineState> analyze;
    id<MTLComputePipelineState> pack;

    /* Reused across frames; grown, never shrunk. */
    id<MTLBuffer> blob;        /* the whole encoded frame, shared */
    size_t        blob_cap;
    id<MTLBuffer> meta;        /* 2 uints per tile: packed widths, bit cost */
    size_t        meta_cap;
    id<MTLBuffer> offs;        /* 1 uint per tile: payload bit offset */
    size_t        offs_cap;
    id<MTLBuffer> staged;      /* only used when src cannot be read in place */
    size_t        staged_cap;

    int  last_zero_copy;
    char name[128];
};

/* ------------------------------------------------------------------- shaders */

static NSString *tb_enc_shader_source(void) {
    return
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct EncParams {\n"
    "  uint width, height, tilesX, tilesY, tileCount;\n"
    "  uint srcStridePx;\n"
    "  uint bits, mask, mid;\n"
    "};\n"
    "\n"
    "static inline uint tb_sample(uint px, uint c, constant EncParams &P) {\n"
    "  return (px >> (c * P.bits)) & P.mask;\n"
    "}\n"
    /* The modular difference, re-centred and zigzagged. Must match
     * resid_encode() in tb_dpcm.c exactly. */
    "static inline uint tb_resid(uint cur, uint pred, constant EncParams &P) {\n"
    "  int d = int((cur - pred + P.mid) & P.mask) - int(P.mid);\n"
    "  return uint((d << 1) ^ (d >> 31));\n"
    "}\n"
    "\n"
    /* ---- step 1: bit widths, seeds and costs ----
     * One threadgroup per tile, one thread per pixel. Prediction reads original
     * samples, so every thread is independent — the serial dependency that
     * shapes the DECODER does not exist on this side. */
    "kernel void tb_enc_analyze(device const uint *src   [[buffer(0)]],\n"
    "                           device       uint *meta  [[buffer(1)]],\n"
    "                           device       uint *seeds [[buffer(2)]],\n"
    "                           constant EncParams &P    [[buffer(3)]],\n"
    "                           uint tile [[threadgroup_position_in_grid]],\n"
    "                           uint lane [[thread_position_in_threadgroup]]) {\n"
    "  const uint x = lane & 7u, y = lane >> 3;\n"
    "  const uint txi = tile % P.tilesX, tyi = tile / P.tilesX;\n"
    "  const uint tx = txi * 8u, ty = tyi * 8u;\n"
    "  const uint tw = min(8u, P.width  - tx);\n"
    "  const uint th = min(8u, P.height - ty);\n"
    "  const bool live = (x < tw && y < th) && !(x == 0u && y == 0u);\n"
    "\n"
    "  uint3 z = uint3(0u);\n"
    "  if (live) {\n"
    "    const uint pxi = (x > 0u) ? (x - 1u) : 0u;\n"
    "    const uint pyi = (x > 0u) ? y : (y - 1u);\n"
    "    const uint cur  = src[(ty + y)   * P.srcStridePx + (tx + x)];\n"
    "    const uint pred = src[(ty + pyi) * P.srcStridePx + (tx + pxi)];\n"
    "    z.x = tb_resid(tb_sample(cur, 0u, P), tb_sample(pred, 0u, P), P);\n"
    "    z.y = tb_resid(tb_sample(cur, 1u, P), tb_sample(pred, 1u, P), P);\n"
    "    z.z = tb_resid(tb_sample(cur, 2u, P), tb_sample(pred, 2u, P), P);\n"
    "  }\n"
    "\n"
    "  threadgroup uint3 red[64];\n"
    "  red[lane] = z;\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  for (uint off = 32u; off > 0u; off >>= 1) {\n"
    "    if (lane < off) red[lane] = max(red[lane], red[lane + off]);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  }\n"
    "  if (lane != 0u) return;\n"
    "\n"
    "  const uint3 m = red[0];\n"
    "  const uint n0 = (m.x == 0u) ? 0u : (32u - clz(m.x));\n"
    "  const uint n1 = (m.y == 0u) ? 0u : (32u - clz(m.y));\n"
    "  const uint n2 = (m.z == 0u) ? 0u : (32u - clz(m.z));\n"
    "  meta[tile * 2u + 0u] = n0 | (n1 << 8) | (n2 << 16);\n"
    "  meta[tile * 2u + 1u] = (n0 + n1 + n2) * (tw * th - 1u);\n"
    /* The seed is the tile's top-left pixel with alpha stripped; the decoder
     * puts opaque alpha back. */
    "  const uint alphaMask = (P.bits == 10u) ? (3u << 30) : (0xFFu << 24);\n"
    "  seeds[tile] = src[ty * P.srcStridePx + tx] & ~alphaMask;\n"
    "}\n"
    "\n"
    /* ---- step 3: pack ----
     * One thread per (tile, channel). Each owns a contiguous run of bits, so it
     * batches into whole words and touches memory atomically only where its run
     * shares a word with a neighbour's — the first and the last.
     *
     * `payload` and `payloadAtomic` are the same buffer bound twice: interior
     * words belong to exactly one thread and can be stored plainly, which is the
     * whole point of the batching. */
    "kernel void tb_enc_pack(device const uint *src           [[buffer(0)]],\n"
    "                        device const uint *meta          [[buffer(1)]],\n"
    "                        device const uint *offs          [[buffer(2)]],\n"
    "                        device       uint *payload       [[buffer(3)]],\n"
    "                        device atomic_uint *payloadAtomic[[buffer(4)]],\n"
    "                        constant EncParams &P            [[buffer(5)]],\n"
    "                        uint gid [[thread_position_in_grid]]) {\n"
    "  const uint tile = gid / 3u, c = gid % 3u;\n"
    "  if (tile >= P.tileCount) return;\n"
    "\n"
    "  const uint packed = meta[tile * 2u + 0u];\n"
    "  const uint n = (packed >> (8u * c)) & 0xFFu;\n"
    "  if (n == 0u) return;\n"
    "\n"
    "  const uint txi = tile % P.tilesX, tyi = tile / P.tilesX;\n"
    "  const uint tx = txi * 8u, ty = tyi * 8u;\n"
    "  const uint tw = min(8u, P.width  - tx);\n"
    "  const uint th = min(8u, P.height - ty);\n"
    "  const uint coded = tw * th - 1u;\n"
    "\n"
    /* Channels are laid out one after another within a tile. */
    "  uint base = offs[tile];\n"
    "  for (uint k = 0u; k < c; ++k) base += ((packed >> (8u * k)) & 0xFFu) * coded;\n"
    "\n"
    "  uint word = base >> 5;\n"
    "  uint fill = base & 31u;      /* bits of this word already spoken for */\n"
    "  uint acc  = 0u;\n"
    "  bool first = true;\n"
    "\n"
    "  for (uint i = 0u; i < coded; ++i) {\n"
    /* Same traversal as TB_TILE_WALK: raster order, skipping the seed. */
    "    const uint idx = i + 1u;\n"
    "    const uint x = idx % tw, y = idx / tw;\n"
    "    const uint pxi = (x > 0u) ? (x - 1u) : 0u;\n"
    "    const uint pyi = (x > 0u) ? y : (y - 1u);\n"
    "    const uint cur  = src[(ty + y)   * P.srcStridePx + (tx + x)];\n"
    "    const uint pred = src[(ty + pyi) * P.srcStridePx + (tx + pxi)];\n"
    "    const uint v = tb_resid(tb_sample(cur, c, P), tb_sample(pred, c, P), P);\n"
    "\n"
    "    const uint room = 32u - fill;\n"
    "    const uint lo   = min(n, room);\n"
    "    acc |= (v & ((1u << lo) - 1u)) << fill;\n"
    "    if (n > lo) {\n"
    "      if (first) { atomic_fetch_or_explicit(&payloadAtomic[word], acc, memory_order_relaxed); first = false; }\n"
    "      else       { payload[word] = acc; }\n"
    "      word += 1u;\n"
    "      acc   = v >> lo;\n"
    "      fill  = n - lo;\n"
    "    } else {\n"
    "      fill += lo;\n"
    "      if (fill == 32u) {\n"
    "        if (first) { atomic_fetch_or_explicit(&payloadAtomic[word], acc, memory_order_relaxed); first = false; }\n"
    "        else       { payload[word] = acc; }\n"
    "        word += 1u;\n"
    "        acc   = 0u;\n"
    "        fill  = 0u;\n"
    "      }\n"
    "    }\n"
    "  }\n"
    /* The tail always merges: the next thread's run starts inside this word. */
    "  if (fill != 0u || first) {\n"
    "    atomic_fetch_or_explicit(&payloadAtomic[word], acc, memory_order_relaxed);\n"
    "  }\n"
    "}\n";
}

/* ---------------------------------------------------------------------- setup */

tb_dpcm_gpu *tb_dpcm_gpu_create(void) {
    tb_dpcm_gpu *e = calloc(1, sizeof(*e));
    if (!e) return NULL;

    @autoreleasepool {
        e->dev = MTLCreateSystemDefaultDevice();
        if (!e->dev) { free(e); return NULL; }

        NSError *err = nil;
        id<MTLLibrary> lib = [e->dev newLibraryWithSource:tb_enc_shader_source()
                                                 options:nil error:&err];
        if (!lib) {
            fprintf(stderr, "[dpcm-gpu] shader failed: %s\n",
                    err.localizedDescription.UTF8String ?: "?");
            free(e);
            return NULL;
        }
        e->analyze = [e->dev newComputePipelineStateWithFunction:
                          [lib newFunctionWithName:@"tb_enc_analyze"] error:&err];
        e->pack    = [e->dev newComputePipelineStateWithFunction:
                          [lib newFunctionWithName:@"tb_enc_pack"] error:&err];
        if (!e->analyze || !e->pack) {
            fprintf(stderr, "[dpcm-gpu] pipeline failed: %s\n",
                    err.localizedDescription.UTF8String ?: "?");
            free(e);
            return NULL;
        }
        e->queue = [e->dev newCommandQueue];
        snprintf(e->name, sizeof(e->name), "%s", [[e->dev name] UTF8String]);
    }
    return e;
}

void tb_dpcm_gpu_destroy(tb_dpcm_gpu *e) {
    if (!e) return;
    e->blob = nil; e->meta = nil; e->offs = nil; e->staged = nil;
    e->analyze = nil; e->pack = nil; e->queue = nil; e->dev = nil;
    free(e);
}

const char *tb_dpcm_gpu_device_name(const tb_dpcm_gpu *e) {
    return (e && e->name[0]) ? e->name : "?";
}

int tb_dpcm_gpu_last_was_zero_copy(const tb_dpcm_gpu *e) {
    return e ? e->last_zero_copy : 0;
}

/* --------------------------------------------------------------------- helpers */

/* `__strong` is required: an out-parameter of object type defaults to
 * __autoreleasing under ARC, which cannot bind to a strong struct field. */
static int ensure_buffer(tb_dpcm_gpu *e, id<MTLBuffer> __strong *buf,
                         size_t *cap, size_t need) {
    if (*cap >= need && *buf) return 0;
    *buf = [e->dev newBufferWithLength:need options:MTLResourceStorageModeShared];
    *cap = *buf ? need : 0;
    return *buf ? 0 : -1;
}

static inline size_t round4(size_t n) { return (n + 3u) & ~(size_t)3u; }
static inline void put_u32(uint8_t *p, uint32_t v) {
    p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); p[2]=(uint8_t)(v>>16); p[3]=(uint8_t)(v>>24);
}

/* --------------------------------------------------------------------- encode */

size_t tb_dpcm_gpu_encode_bands(tb_dpcm_gpu *e,
                                const uint8_t *src, int stride, int w, int band_h,
                                int band_count, int ten_bit, size_t header_reserve,
                                tb_dpcm_gpu_band *out) {
    if (!e || !src || !out || w <= 0 || band_h <= 0 || stride < w * 4) return 0;
    if (band_count < 1 || band_count > TB_DPCM_GPU_MAX_BANDS) return 0;
    /* Same pixel cap as the C codec, for the same reason: every bit offset the
     * kernels compute is a uint. tb_dpcm_max_size() enforces it too (returning
     * 0 makes ensure_buffer fail), but checking here keeps the failure mode a
     * clean refusal instead of a zero-sized allocation. Both the band and the
     * whole frame have to fit — the band because its offsets are what the
     * kernels compute, the frame because it is what gets wrapped. */
    if ((uint64_t)w * (uint64_t)band_h > ((uint64_t)1 << 27)) return 0;
    if ((uint64_t)w * (uint64_t)band_h * (uint64_t)band_count > ((uint64_t)1 << 27)) return 0;
    /* The shaders index the source as 32-bit words, so a row must be a whole
     * number of them. Every CVPixelBuffer stride is, but an arbitrary caller's
     * might not be. */
    if (stride % 4 != 0) return 0;

    /* Every band has the same width and the same height, so one geometry serves
     * all of them and each band's region of each buffer is a fixed stride away
     * from the last. That is the whole reason this can be one dispatch loop. */
    const int tiles_x = (w + TB_DPCM_TILE - 1) / TB_DPCM_TILE;
    const int tiles_y = (band_h + TB_DPCM_TILE - 1) / TB_DPCM_TILE;
    const uint32_t tile_count  = (uint32_t)tiles_x * (uint32_t)tiles_y;
    const uint32_t group_count = (tile_count + TB_DPCM_GROUP - 1) / TB_DPCM_GROUP;

    const size_t width_plane_bytes = round4(((size_t)tile_count * 3 + 1) / 2);
    const size_t seed_plane_bytes  = (size_t)tile_count * 4;
    const size_t group_table_off   = TB_DPCM_HEADER;
    const size_t width_plane_off   = group_table_off + (size_t)group_count * 4;
    const size_t seed_plane_off    = width_plane_off + width_plane_bytes;
    const size_t payload_off       = seed_plane_off + seed_plane_bytes;

    /* Metal requires 4-byte-aligned buffer offsets, and every plane below is
     * bound at an offset into this buffer — so the blob starts at a padded
     * boundary and the caller's header sits at the END of the reserved run,
     * immediately before it. That keeps the header contiguous with the payload
     * without misaligning anything the GPU touches. Bands are spaced by a
     * rounded span for the same reason. */
    const size_t blob_off = round4(header_reserve);
    const size_t band_max = tb_dpcm_max_size(w, band_h);
    if (band_max == 0) return 0;
    const size_t band_span = round4(blob_off + band_max);
    const size_t meta_span = (size_t)tile_count * 8;
    const size_t offs_span = (size_t)tile_count * 4;

    if (ensure_buffer(e, &e->blob, &e->blob_cap, band_span * (size_t)band_count) != 0) return 0;
    if (ensure_buffer(e, &e->meta, &e->meta_cap, meta_span * (size_t)band_count) != 0) return 0;
    if (ensure_buffer(e, &e->offs, &e->offs_cap, offs_span * (size_t)band_count) != 0) return 0;

    size_t payload_bytes[TB_DPCM_GPU_MAX_BANDS];
    size_t total_all = 0;

    @autoreleasepool {
        /* Wrap the caller's pixels without copying when the allocation is page
         * aligned, which IOSurface-backed capture buffers are. The whole frame
         * is wrapped once and each band reads from its own offset — wrapping a
         * band's advanced pointer instead only avoided the copy when that band's
         * byte offset happened to land on a page boundary. The fallback exists
         * so an odd caller degrades instead of failing. */
        const size_t page = (size_t)getpagesize();
        const size_t band_bytes = (size_t)stride * (size_t)band_h;
        const size_t src_bytes  = band_bytes * (size_t)band_count;
        id<MTLBuffer> srcBuf = nil;
        if (((uintptr_t)src % page) == 0) {
            srcBuf = [e->dev newBufferWithBytesNoCopy:(void *)src
                                               length:(src_bytes + page - 1) / page * page
                                              options:MTLResourceStorageModeShared
                                          deallocator:nil];
        }
        if (srcBuf) {
            e->last_zero_copy = 1;
        } else {
            e->last_zero_copy = 0;
            if (ensure_buffer(e, &e->staged, &e->staged_cap, src_bytes) != 0) return 0;
            memcpy(e->staged.contents, src, src_bytes);
            srcBuf = e->staged;
        }

        struct enc_params P = {
            (uint32_t)w, (uint32_t)band_h,
            (uint32_t)tiles_x, (uint32_t)tiles_y,
            tile_count,
            (uint32_t)(stride / 4),
            ten_bit ? 10u : 8u,
            ten_bit ? 0x3FFu : 0xFFu,
            ten_bit ? 0x200u : 0x80u
        };

        /* ---- step 1: analyze, every band in one submission ----
         * The default (serial) dispatch type is kept deliberately. A single
         * band already fills the device — 57600 threadgroups at 5K/4 — so
         * letting bands overlap would buy almost nothing, and the win here is
         * the round trip, not intra-GPU concurrency. */
        id<MTLCommandBuffer> cb = [e->queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:e->analyze];
        [ce setBytes:&P length:sizeof(P) atIndex:3];
        for (int b = 0; b < band_count; ++b) {
            [ce setBuffer:srcBuf  offset:band_bytes * (size_t)b atIndex:0];
            [ce setBuffer:e->meta offset:meta_span  * (size_t)b atIndex:1];
            [ce setBuffer:e->blob offset:band_span  * (size_t)b + blob_off + seed_plane_off atIndex:2];
            [ce dispatchThreadgroups:MTLSizeMake(tile_count, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        }
        [ce endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) {
            fprintf(stderr, "[dpcm-gpu] analyze: %s\n", cb.error.localizedDescription.UTF8String);
            return 0;
        }

        /* ---- step 2: plan, on the host ----
         * O(tiles), so 1/64th of the per-pixel work, and the host has to write
         * the header and learn the final length regardless. Group starts are
         * rounded up to a byte, which is what lets step 3 write groups
         * concurrently.
         *
         * This is the remaining sync point: it sits between two GPU passes, so
         * the encoder has to stop here. Moving it onto the device would make the
         * frame a single submission. */
        for (int b = 0; b < band_count; ++b) {
            uint8_t *blob = (uint8_t *)e->blob.contents + band_span * (size_t)b + blob_off;
            const uint32_t *meta = (const uint32_t *)((uint8_t *)e->meta.contents + meta_span * (size_t)b);
            uint32_t *offs = (uint32_t *)((uint8_t *)e->offs.contents + offs_span * (size_t)b);

            /* Up to the SEED plane only. The analyze kernel has already written
             * the seeds into the blob, and clearing as far as payload_off would
             * erase them — which it did, and showed up as every byte from
             * seed_plane_off onwards differing from the reference. The width
             * plane does need clearing because nibbles are OR-ed into it; the
             * header and group table are written whole. */
            memset(blob, 0, seed_plane_off);

            size_t bitpos = 0;
            uint8_t *wp = blob + width_plane_off;
            for (uint32_t t = 0; t < tile_count; ++t) {
                if (t % TB_DPCM_GROUP == 0) {
                    bitpos = (bitpos + 7u) & ~(size_t)7u;
                    put_u32(blob + group_table_off + (size_t)(t / TB_DPCM_GROUP) * 4,
                            (uint32_t)bitpos);
                }
                offs[t] = (uint32_t)bitpos;

                const uint32_t packed = meta[t * 2 + 0];
                for (int c = 0; c < 3; ++c) {
                    const uint32_t idx = t * 3u + (uint32_t)c;
                    const int n = (int)((packed >> (8 * c)) & 0xFFu);
                    if (idx & 1u) wp[idx >> 1] |= (uint8_t)((n & 0xF) << 4);
                    else          wp[idx >> 1] |= (uint8_t)( n & 0xF);
                }
                bitpos += meta[t * 2 + 1];
            }
            payload_bytes[b] = (bitpos + 7) / 8;
            const size_t total = payload_off + payload_bytes[b];

            put_u32(blob +  0, TB_DPCM_MAGIC);
            put_u32(blob +  4, (uint32_t)w);
            put_u32(blob +  8, (uint32_t)band_h);
            blob[12] = 3;
            blob[13] = TB_DPCM_CHANNELS;
            blob[14] = (uint8_t)(TB_DPCM_FLAG_ALPHA_OMITTED |
                                 (ten_bit ? TB_DPCM_FLAG_TEN_BIT : 0u));
            blob[15] = 0;
            put_u32(blob + 16, group_count);
            put_u32(blob + 20, (uint32_t)width_plane_bytes);
            put_u32(blob + 24, (uint32_t)seed_plane_bytes);
            put_u32(blob + 28, (uint32_t)payload_bytes[b]);

            /* The reserved run ends where the blob begins, so the caller's
             * header and the payload are one contiguous buffer. */
            out[b].blob = blob - header_reserve;
            out[b].len  = header_reserve + total;
            total_all  += header_reserve + total;
        }

        /* ---- step 3: pack, every band in one submission ----
         * The payload is zeroed on the GPU because the packer merges into it, and
         * a 32 MB memset on the host would cost more than the whole encode. All
         * the fills go in one blit encoder ahead of the packs: separate encoders
         * in a command buffer run in order, which is the dependency we need. */
        cb = [e->queue commandBuffer];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        for (int b = 0; b < band_count; ++b) {
            [be fillBuffer:e->blob
                     range:NSMakeRange(band_span * (size_t)b + blob_off + payload_off,
                                       round4(payload_bytes[b]) + 4)
                     value:0];
        }
        [be endEncoding];

        ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:e->pack];
        [ce setBytes:&P length:sizeof(P) atIndex:5];
        const NSUInteger threads = (NSUInteger)tile_count * 3;
        const NSUInteger tg = 256;
        for (int b = 0; b < band_count; ++b) {
            const size_t pay = band_span * (size_t)b + blob_off + payload_off;
            [ce setBuffer:srcBuf  offset:band_bytes * (size_t)b atIndex:0];
            [ce setBuffer:e->meta offset:meta_span  * (size_t)b atIndex:1];
            [ce setBuffer:e->offs offset:offs_span  * (size_t)b atIndex:2];
            [ce setBuffer:e->blob offset:pay atIndex:3];
            [ce setBuffer:e->blob offset:pay atIndex:4];
            [ce dispatchThreadgroups:MTLSizeMake((threads + tg - 1) / tg, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
        }
        [ce endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) {
            fprintf(stderr, "[dpcm-gpu] pack: %s\n", cb.error.localizedDescription.UTF8String);
            return 0;
        }
    }
    return total_all;
}

size_t tb_dpcm_gpu_encode(tb_dpcm_gpu *e,
                          const uint8_t *src, int stride, int w, int h,
                          int ten_bit, size_t header_reserve,
                          const uint8_t **out_blob) {
    if (!out_blob) return 0;
    tb_dpcm_gpu_band band = { NULL, 0 };
    const size_t n = tb_dpcm_gpu_encode_bands(e, src, stride, w, h, 1,
                                              ten_bit, header_reserve, &band);
    if (n == 0 || !band.blob) return 0;
    *out_blob = band.blob;
    return band.len;
}
