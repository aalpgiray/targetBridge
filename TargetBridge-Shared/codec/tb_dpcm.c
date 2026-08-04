/* tb_dpcm.c — reference encoder/decoder for TBD1. See tb_dpcm.h for the format
 * and the reasoning behind its shape.
 *
 * The decoder here is the correctness oracle for the Metal shader, not the
 * production path: at 5K it performs ~44 million bit extractions per frame,
 * which the receiver's i5 cannot afford on top of a TCP stack that already
 * saturates a core. The encoder is a straightforward two-pass implementation —
 * it computes bit widths, then re-derives the residuals to emit them — which
 * costs double the prediction work in exchange for not holding a 44 MB residual
 * buffer. Worth revisiting if the sender ends up encoding on the CPU.
 */

#include "tb_dpcm.h"

#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------- little-endian */

/* Written out by hand rather than memcpy'd from a struct: the header must have
 * exactly this layout on every compiler, with no padding surprises. */
static inline void put_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v      );
    p[1] = (uint8_t)(v >>  8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static inline uint32_t get_u32(const uint8_t *p) {
    return (uint32_t)p[0]
         | ((uint32_t)p[1] <<  8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

/* ------------------------------------------------------------------ bit twiddling */

/* Write the low `n` bits of `v` at bit position `p`. The buffer must be zeroed:
 * this ORs rather than masking, which keeps it to two byte writes. n <= 8 and
 * the bit offset within a byte is <= 7, so at most two bytes are ever touched. */
static inline void bw_put(uint8_t *buf, size_t p, uint32_t v, int n) {
    if (n == 0) return;
    size_t   byte = p >> 3;
    int      sh   = (int)(p & 7);
    uint32_t x    = (v & ((1u << n) - 1u)) << sh;
    buf[byte] |= (uint8_t)(x & 0xFF);
    if (sh + n > 8) buf[byte + 1] |= (uint8_t)((x >> 8) & 0xFF);
}

static inline uint32_t br_get(const uint8_t *buf, size_t p, int n) {
    if (n == 0) return 0;
    size_t   byte = p >> 3;
    int      sh   = (int)(p & 7);
    uint32_t x    = (uint32_t)buf[byte];
    if (sh + n > 8) x |= (uint32_t)buf[byte + 1] << 8;
    return (x >> sh) & ((1u << n) - 1u);
}

static inline int bits_for(uint32_t v) {
    int n = 0;
    while (v) { ++n; v >>= 1; }
    return n;
}

/* Residual as stored: the mod-256 difference re-centred to [-128,127] and
 * zigzagged so small magnitudes of either sign need few bits. Reconstruction
 * wraps, so no clamping is needed anywhere and the round trip is exact. */
static inline uint32_t resid_encode(int cur, int pred) {
    int d = ((cur - pred + 128) & 0xFF) - 128;
    return (uint32_t)((d << 1) ^ (d >> 31));
}

static inline int resid_decode(uint32_t z, int pred) {
    int d = (int)((z >> 1) ^ (~(z & 1u) + 1u));   /* un-zigzag, no UB on shift */
    return (pred + d) & 0xFF;
}

/* Nibble-packed bit widths: (tile, channel) -> 4 bits, tile-major. */
static inline void width_put(uint8_t *plane, uint32_t idx, int n) {
    if (idx & 1u) plane[idx >> 1] |= (uint8_t)((n & 0xF) << 4);
    else          plane[idx >> 1] |= (uint8_t)( n & 0xF);
}

static inline int width_get(const uint8_t *plane, uint32_t idx) {
    uint8_t b = plane[idx >> 1];
    return (idx & 1u) ? (b >> 4) : (b & 0xF);
}

/* ------------------------------------------------------------------- geometry */

struct geom {
    int      tiles_x, tiles_y;
    uint32_t tile_count, group_count;
    size_t   width_plane_bytes, seed_plane_bytes;
    size_t   group_table_off, width_plane_off, seed_plane_off, payload_off;
};

static void geom_of(int w, int h, struct geom *g) {
    g->tiles_x = (w + TB_DPCM_TILE - 1) / TB_DPCM_TILE;
    g->tiles_y = (h + TB_DPCM_TILE - 1) / TB_DPCM_TILE;
    g->tile_count  = (uint32_t)g->tiles_x * (uint32_t)g->tiles_y;
    g->group_count = (g->tile_count + TB_DPCM_GROUP - 1) / TB_DPCM_GROUP;

    uint32_t nibbles = g->tile_count * TB_DPCM_CHANNELS;
    g->width_plane_bytes = (nibbles + 1) / 2;
    g->seed_plane_bytes  = (size_t)g->tile_count * TB_DPCM_CHANNELS;

    g->group_table_off = TB_DPCM_HEADER;
    g->width_plane_off = g->group_table_off + (size_t)g->group_count * 4;
    g->seed_plane_off  = g->width_plane_off + g->width_plane_bytes;
    g->payload_off     = g->seed_plane_off  + g->seed_plane_bytes;
}

size_t tb_dpcm_max_size(int w, int h) {
    if (w <= 0 || h <= 0) return 0;
    struct geom g;
    geom_of(w, h, &g);
    /* Worst case per tile-channel is 8 bits per coded pixel, i.e. the tile's raw
     * size. Bounding by the padded tile grid rather than by w*h covers the
     * partial tiles at the right and bottom edges. */
    size_t coded = (size_t)g.tile_count *
                   (TB_DPCM_TILE * TB_DPCM_TILE - 1) * TB_DPCM_CHANNELS;
    return g.payload_off + coded + 8;
}

/* ------------------------------------------------------------------- encoding */

/* Walk one tile-channel, calling back with (current, predicted) for every coded
 * pixel in order. Both passes of the encoder and the decoder must agree exactly
 * on this traversal, so it lives in one place.
 *
 * Prediction: the left neighbour, except the first column, which predicts from
 * above. Pixel (0,0) is the seed and is not coded. Reconstructed values equal
 * the originals because the coding is lossless, so the encoder may read either. */
#define TB_TILE_WALK(tw, th, BODY)                                              \
    do {                                                                        \
        for (int _y = 0; _y < (th); ++_y) {                                     \
            for (int _x = 0; _x < (tw); ++_x) {                                 \
                if (_x == 0 && _y == 0) continue;                               \
                const int _px = (_x > 0) ? (_x - 1) : 0;                        \
                const int _py = (_x > 0) ? _y       : (_y - 1);                 \
                BODY                                                            \
            }                                                                   \
        }                                                                       \
    } while (0)

size_t tb_dpcm_encode(const uint8_t *src, int stride, int w, int h,
                      uint8_t *dst, size_t dst_cap) {
    if (!src || !dst || w <= 0 || h <= 0 || stride < w * 4) return 0;

    struct geom g;
    geom_of(w, h, &g);
    if (dst_cap < tb_dpcm_max_size(w, h)) return 0;

    uint8_t *widths = calloc(g.tile_count, TB_DPCM_CHANNELS);
    if (!widths) return 0;

    /* Pass 1: the widest residual in each tile-channel decides its bit width. */
    for (int tyi = 0; tyi < g.tiles_y; ++tyi) {
        for (int txi = 0; txi < g.tiles_x; ++txi) {
            const int tx = txi * TB_DPCM_TILE, ty = tyi * TB_DPCM_TILE;
            const int tw = (tx + TB_DPCM_TILE <= w) ? TB_DPCM_TILE : (w - tx);
            const int th = (ty + TB_DPCM_TILE <= h) ? TB_DPCM_TILE : (h - ty);
            const uint32_t t = (uint32_t)tyi * g.tiles_x + txi;
            const uint8_t *tile = src + (size_t)ty * stride + (size_t)tx * 4;

            for (int c = 0; c < TB_DPCM_CHANNELS; ++c) {
                uint32_t widest = 0;
                TB_TILE_WALK(tw, th, {
                    int cur  = tile[(size_t)_y  * stride + (size_t)_x  * 4 + c];
                    int pred = tile[(size_t)_py * stride + (size_t)_px * 4 + c];
                    uint32_t z = resid_encode(cur, pred);
                    if (z > widest) widest = z;
                });
                widths[t * TB_DPCM_CHANNELS + c] = (uint8_t)bits_for(widest);
            }
        }
    }

    /* Group bases, in bits. One per 64 tiles; threads recover their own offset
     * from a scan within the group, so no per-tile offset goes on the wire. */
    memset(dst, 0, g.payload_off);
    size_t bitpos = 0;
    for (uint32_t t = 0; t < g.tile_count; ++t) {
        if (t % TB_DPCM_GROUP == 0)
            put_u32(dst + g.group_table_off + (size_t)(t / TB_DPCM_GROUP) * 4,
                    (uint32_t)bitpos);

        const int txi = (int)(t % (uint32_t)g.tiles_x);
        const int tyi = (int)(t / (uint32_t)g.tiles_x);
        const int tw = (txi * TB_DPCM_TILE + TB_DPCM_TILE <= w)
                     ? TB_DPCM_TILE : (w - txi * TB_DPCM_TILE);
        const int th = (tyi * TB_DPCM_TILE + TB_DPCM_TILE <= h)
                     ? TB_DPCM_TILE : (h - tyi * TB_DPCM_TILE);
        const int coded = tw * th - 1;

        for (int c = 0; c < TB_DPCM_CHANNELS; ++c) {
            width_put(dst + g.width_plane_off, t * TB_DPCM_CHANNELS + c,
                      widths[t * TB_DPCM_CHANNELS + c]);
            bitpos += (size_t)widths[t * TB_DPCM_CHANNELS + c] * coded;
        }
    }
    const size_t payload_bits  = bitpos;
    const size_t payload_bytes = (payload_bits + 7) / 8;
    memset(dst + g.payload_off, 0, payload_bytes);

    /* Pass 2: seeds and residuals. */
    bitpos = 0;
    for (int tyi = 0; tyi < g.tiles_y; ++tyi) {
        for (int txi = 0; txi < g.tiles_x; ++txi) {
            const int tx = txi * TB_DPCM_TILE, ty = tyi * TB_DPCM_TILE;
            const int tw = (tx + TB_DPCM_TILE <= w) ? TB_DPCM_TILE : (w - tx);
            const int th = (ty + TB_DPCM_TILE <= h) ? TB_DPCM_TILE : (h - ty);
            const uint32_t t = (uint32_t)tyi * g.tiles_x + txi;
            const uint8_t *tile = src + (size_t)ty * stride + (size_t)tx * 4;
            uint8_t *seeds = dst + g.seed_plane_off + (size_t)t * TB_DPCM_CHANNELS;

            for (int c = 0; c < TB_DPCM_CHANNELS; ++c) {
                seeds[c] = tile[c];
                const int n = widths[t * TB_DPCM_CHANNELS + c];
                if (n == 0) continue;   /* flat: every residual is zero */
                TB_TILE_WALK(tw, th, {
                    int cur  = tile[(size_t)_y  * stride + (size_t)_x  * 4 + c];
                    int pred = tile[(size_t)_py * stride + (size_t)_px * 4 + c];
                    bw_put(dst + g.payload_off, bitpos, resid_encode(cur, pred), n);
                    bitpos += n;
                });
            }
        }
    }
    free(widths);

    put_u32(dst +  0, TB_DPCM_MAGIC);
    put_u32(dst +  4, (uint32_t)w);
    put_u32(dst +  8, (uint32_t)h);
    dst[12] = 3;                                  /* log2(8) */
    dst[13] = TB_DPCM_CHANNELS;
    dst[14] = TB_DPCM_FLAG_ALPHA_OMITTED;
    dst[15] = 0;
    put_u32(dst + 16, g.group_count);
    put_u32(dst + 20, (uint32_t)g.width_plane_bytes);
    put_u32(dst + 24, (uint32_t)g.seed_plane_bytes);
    put_u32(dst + 28, (uint32_t)payload_bytes);

    return g.payload_off + payload_bytes;
}

/* -------------------------------------------------------------------- parsing */

int tb_dpcm_parse(const uint8_t *src, size_t len, struct tb_dpcm_info *out) {
    if (!src || !out || len < TB_DPCM_HEADER) return -1;
    if (get_u32(src) != TB_DPCM_MAGIC) return -1;

    const uint32_t w = get_u32(src + 4);
    const uint32_t h = get_u32(src + 8);
    /* 16384 is far above any real display and keeps every product below from
     * overflowing 32 bits. */
    if (w == 0 || h == 0 || w > 16384 || h > 16384) return -1;
    if (src[12] != 3 || src[13] != TB_DPCM_CHANNELS) return -1;

    struct geom g;
    geom_of((int)w, (int)h, &g);

    if (get_u32(src + 16) != g.group_count)                     return -1;
    if (get_u32(src + 20) != (uint32_t)g.width_plane_bytes)      return -1;
    if (get_u32(src + 24) != (uint32_t)g.seed_plane_bytes)       return -1;
    const uint32_t payload_bytes = get_u32(src + 28);
    if (g.payload_off + payload_bytes != len)                    return -1;

    /* Re-derive every group base from the width plane and require the blob's own
     * table to agree. This is the one check that lets the GPU decoder run
     * without bounds tests: once the table is known to be exactly the prefix sum
     * of the declared widths, and the total matches the payload length, no
     * thread can compute an offset outside the payload. Costs one pass over the
     * width plane (~690 KB at 5K), which is cheap next to what it buys. */
    const uint8_t *wp = src + g.width_plane_off;
    const uint8_t *gt = src + g.group_table_off;
    size_t bitpos = 0;
    for (uint32_t t = 0; t < g.tile_count; ++t) {
        if (t % TB_DPCM_GROUP == 0) {
            if (get_u32(gt + (size_t)(t / TB_DPCM_GROUP) * 4) != (uint32_t)bitpos)
                return -1;
        }
        const int txi = (int)(t % (uint32_t)g.tiles_x);
        const int tyi = (int)(t / (uint32_t)g.tiles_x);
        const int tw = (txi * TB_DPCM_TILE + TB_DPCM_TILE <= (int)w)
                     ? TB_DPCM_TILE : ((int)w - txi * TB_DPCM_TILE);
        const int th = (tyi * TB_DPCM_TILE + TB_DPCM_TILE <= (int)h)
                     ? TB_DPCM_TILE : ((int)h - tyi * TB_DPCM_TILE);
        for (int c = 0; c < TB_DPCM_CHANNELS; ++c) {
            int n = width_get(wp, t * TB_DPCM_CHANNELS + c);
            if (n > 8) return -1;
            bitpos += (size_t)n * (tw * th - 1);
        }
    }
    if ((bitpos + 7) / 8 != payload_bytes) return -1;

    out->width         = (int)w;
    out->height        = (int)h;
    out->tile          = TB_DPCM_TILE;
    out->channels      = TB_DPCM_CHANNELS;
    out->alpha_omitted = (src[14] & TB_DPCM_FLAG_ALPHA_OMITTED) ? 1 : 0;
    out->tiles_x       = g.tiles_x;
    out->tiles_y       = g.tiles_y;
    out->tile_count    = g.tile_count;
    out->group_count   = g.group_count;
    out->group_table_off = g.group_table_off;
    out->width_plane_off = g.width_plane_off;
    out->seed_plane_off  = g.seed_plane_off;
    out->payload_off     = g.payload_off;
    out->payload_bytes   = payload_bytes;
    out->total_bytes     = len;
    return 0;
}

/* ------------------------------------------------------------------- decoding */

int tb_dpcm_decode(const uint8_t *src, size_t len, uint8_t *dst, int stride) {
    struct tb_dpcm_info in;
    if (tb_dpcm_parse(src, len, &in) != 0) return -1;
    if (!dst || stride < in.width * 4) return -1;

    const uint8_t *wp = src + in.width_plane_off;
    const uint8_t *sp = src + in.seed_plane_off;
    const uint8_t *pl = src + in.payload_off;

    size_t bitpos = 0;
    for (uint32_t t = 0; t < in.tile_count; ++t) {
        const int txi = (int)(t % (uint32_t)in.tiles_x);
        const int tyi = (int)(t / (uint32_t)in.tiles_x);
        const int tx = txi * TB_DPCM_TILE, ty = tyi * TB_DPCM_TILE;
        const int tw = (tx + TB_DPCM_TILE <= in.width)  ? TB_DPCM_TILE : (in.width  - tx);
        const int th = (ty + TB_DPCM_TILE <= in.height) ? TB_DPCM_TILE : (in.height - ty);
        uint8_t *tile = dst + (size_t)ty * stride + (size_t)tx * 4;

        for (int c = 0; c < TB_DPCM_CHANNELS; ++c) {
            const int n = width_get(wp, t * TB_DPCM_CHANNELS + c);
            tile[c] = sp[(size_t)t * TB_DPCM_CHANNELS + c];
            if (n == 0) {
                /* Flat tile-channel: every pixel takes the seed's value. Still
                 * has to be written out — the destination is not cleared. A plain
                 * loop rather than TB_TILE_WALK, which exists to supply predictor
                 * coordinates there is nothing here to predict from. */
                const uint8_t v = tile[c];
                for (int y = 0; y < th; ++y)
                    for (int x = 0; x < tw; ++x)
                        tile[(size_t)y * stride + (size_t)x * 4 + c] = v;
                continue;
            }
            TB_TILE_WALK(tw, th, {
                int pred = tile[(size_t)_py * stride + (size_t)_px * 4 + c];
                uint32_t z = br_get(pl, bitpos, n);
                bitpos += n;
                tile[(size_t)_y * stride + (size_t)_x * 4 + c] =
                    (uint8_t)resid_decode(z, pred);
            });
        }
        /* Alpha is not carried. The receiver's drawable is opaque, so anything
         * else would be a lie the compositor might act on. */
        for (int y = 0; y < th; ++y)
            for (int x = 0; x < tw; ++x)
                tile[(size_t)y * stride + (size_t)x * 4 + 3] = 0xFF;
    }
    return 0;
}
