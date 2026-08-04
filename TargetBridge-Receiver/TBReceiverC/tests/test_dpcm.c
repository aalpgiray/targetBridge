/* test_dpcm.c — hardware-free unit tests for the TBD1 tile-DPCM codec.
 *
 * Build & run:  make test
 *
 * Only needs tb_dpcm.c + libc — no ffmpeg, no SDL, no GPU. The point of these is
 * that the C decoder is the correctness oracle for the Metal shader: if this is
 * wrong, the shader is verified against the wrong answer. So the tests lean on
 * round-tripping real-shaped content and on rejecting malformed blobs, since
 * tb_dpcm_parse is what lets the shader skip bounds checks entirely. */

#include "../src/tb_dpcm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do {                                              \
    g_checks++;                                                            \
    if (!(cond)) {                                                         \
        g_failures++;                                                      \
        fprintf(stderr, "FAIL %s:%d — %s\n", __FILE__, __LINE__, (msg));   \
    }                                                                      \
} while (0)

/* ---- helpers ----------------------------------------------------------- */

static uint32_t rng_state = 0xC0FFEEu;
static uint32_t rng(void) {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}

/* Round-trip a frame and require it back byte for byte. Alpha is not carried, so
 * the source is built opaque and the comparison includes the alpha byte — that
 * way a decoder that forgets to write alpha fails here rather than showing up as
 * a transparent window much later. */
static void roundtrip(const char *what, const uint8_t *src, int w, int h,
                      double *out_ratio) {
    const int stride = w * 4;
    size_t cap = tb_dpcm_max_size(w, h);
    uint8_t *blob = malloc(cap);
    uint8_t *back = calloc((size_t)h, stride);
    CHECK(blob != NULL && back != NULL, "allocation");
    if (!blob || !back) { free(blob); free(back); return; }

    size_t len = tb_dpcm_encode(src, stride, w, h, blob, cap);
    CHECK(len > 0, what);
    CHECK(len <= cap, "encoder respects its own size bound");

    struct tb_dpcm_info in;
    CHECK(tb_dpcm_parse(blob, len, &in) == 0, "parse accepts what encode produced");
    CHECK(in.width == w && in.height == h, "dimensions survive");
    CHECK(in.alpha_omitted == 1, "alpha is declared omitted");

    CHECK(tb_dpcm_decode(blob, len, back, stride) == 0, "decode succeeds");
    CHECK(memcmp(src, back, (size_t)h * stride) == 0, what);

    if (out_ratio) {
        *out_ratio = (double)((size_t)h * stride) / (double)len;
        /* Printed, not just asserted: a silent drift in ratio is the kind of
         * regression that a pass/fail bound will not surface until it is large. */
        printf("  %-28s %5.2fx  (%d x %d)\n", what, *out_ratio, w, h);
    }
    free(blob);
    free(back);
}

static uint8_t *frame_alloc(int w, int h) {
    uint8_t *p = calloc((size_t)h, (size_t)w * 4);
    if (p) for (size_t i = 3; i < (size_t)w * h * 4; i += 4) p[i] = 0xFF;
    return p;
}

/* ---- tests ------------------------------------------------------------- */

/* A single flat colour is the case where the format should be at its very best:
 * every residual is zero, so every tile costs only its header and seed. */
static void test_flat(void) {
    const int w = 256, h = 128;
    uint8_t *f = frame_alloc(w, h);
    for (size_t i = 0; i < (size_t)w * h; ++i) {
        f[i * 4 + 0] = 0x20; f[i * 4 + 1] = 0x40; f[i * 4 + 2] = 0x60;
    }
    double ratio = 0;
    roundtrip("flat frame round-trips", f, w, h, &ratio);
    /* 4 bytes/px in, 4.5 bytes per 64-px tile out. */
    CHECK(ratio > 30.0, "flat frame compresses hard");
    free(f);
}

/* Pure noise is the adversarial case: residuals span the full range, so every
 * tile-channel lands at 8 bits and the payload equals the raw 3-channel size.
 * The format must not EXPAND here — that is what the mod-256 re-centring buys,
 * and it is why no escape hatch to raw is needed. */
static void test_noise_does_not_expand(void) {
    const int w = 128, h = 64;
    uint8_t *f = frame_alloc(w, h);
    for (size_t i = 0; i < (size_t)w * h; ++i) {
        uint32_t r = rng();
        f[i * 4 + 0] = (uint8_t)r; f[i * 4 + 1] = (uint8_t)(r >> 8); f[i * 4 + 2] = (uint8_t)(r >> 16);
    }
    double ratio = 0;
    roundtrip("noise round-trips", f, w, h, &ratio);
    CHECK(ratio > 1.30, "noise still beats raw BGRA (alpha alone is 25%)");
    free(f);
}

/* Gradients are what the format exists for, and they are also where an off-by-one
 * in the predictor hides: a wrong predictor still round-trips if encoder and
 * decoder share the mistake, but the ratio collapses. So this asserts on the
 * ratio, not just on correctness. */
static void test_gradient(void) {
    const int w = 512, h = 256;
    uint8_t *f = frame_alloc(w, h);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            uint8_t *p = f + ((size_t)y * w + x) * 4;
            p[0] = (uint8_t)(x * 255 / (w - 1));
            p[1] = (uint8_t)(y * 255 / (h - 1));
            p[2] = (uint8_t)((x + y) * 255 / (w + h - 2));
        }
    double ratio = 0;
    roundtrip("gradient round-trips", f, w, h, &ratio);
    CHECK(ratio > 4.5, "a smooth gradient compresses well");
    free(f);
}

/* Wrapping is the sharp edge of the mod-256 residual: 0x00 next to 0xFF is a
 * distance of 1, not 255, and only survives if encoder and decoder agree that
 * reconstruction wraps. A frame of alternating extremes exercises nothing else. */
static void test_wraparound(void) {
    const int w = 64, h = 64;
    uint8_t *f = frame_alloc(w, h);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            uint8_t v = ((x + y) & 1) ? 0xFF : 0x00;
            uint8_t *p = f + ((size_t)y * w + x) * 4;
            p[0] = p[1] = p[2] = v;
        }
    roundtrip("alternating 0x00/0xFF round-trips", f, w, h, NULL);
    free(f);
}

/* Sizes that are not multiples of 8 leave partial tiles along the right and
 * bottom edges, whose coded-pixel counts differ from a full tile's. Those counts
 * feed the group offsets, so an error here corrupts every tile after the first
 * short row rather than just the edge. */
static void test_partial_tiles(void) {
    const int sizes[][2] = { {1,1}, {1,8}, {8,1}, {7,7}, {9,9}, {13,5}, {65,33}, {5121,17} };
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); ++i) {
        const int w = sizes[i][0], h = sizes[i][1];
        uint8_t *f = frame_alloc(w, h);
        if (!f) { CHECK(0, "allocation"); continue; }
        for (size_t k = 0; k < (size_t)w * h; ++k) {
            uint32_t r = rng();
            f[k * 4 + 0] = (uint8_t)r;
            f[k * 4 + 1] = (uint8_t)(r >> 3);
            f[k * 4 + 2] = (uint8_t)(r >> 6);
        }
        char msg[64];
        snprintf(msg, sizeof(msg), "%dx%d round-trips", w, h);
        roundtrip(msg, f, w, h, NULL);
        free(f);
    }
}

/* A frame where each tile lands at a different bit width, including zero, so the
 * group offsets have to be right for tiles that contribute nothing. */
static void test_mixed_widths(void) {
    const int w = 8 * 40, h = 8 * 12;
    uint8_t *f = frame_alloc(w, h);
    int t = 0;
    for (int ty = 0; ty < h; ty += 8) {
        for (int tx = 0; tx < w; tx += 8, ++t) {
            int n = t % 9;                       /* 0..8, every width */
            for (int y = 0; y < 8; ++y)
                for (int x = 0; x < 8; ++x) {
                    uint8_t *p = f + ((size_t)(ty + y) * w + (tx + x)) * 4;
                    int span = (n == 0) ? 1 : (1 << n);
                    for (int c = 0; c < 3; ++c)
                        p[c] = (uint8_t)((0x80 + (int)(rng() % (uint32_t)span) - span / 2) & 0xFF);
                }
        }
    }
    roundtrip("mixed per-tile bit widths round-trip", f, w, h, NULL);
    free(f);
}

/* tb_dpcm_parse is the receiver's only defence: it re-derives the whole offset
 * table from the width plane so the GPU decoder can run without a single bounds
 * check. If it ever accepts a blob whose table disagrees, threads read outside
 * the payload. These are the mutations that must be caught. */
static void test_parse_rejects_malformed(void) {
    const int w = 64, h = 64;
    uint8_t *f = frame_alloc(w, h);
    for (size_t i = 0; i < (size_t)w * h; ++i) {
        uint32_t r = rng();
        f[i * 4 + 0] = (uint8_t)r; f[i * 4 + 1] = (uint8_t)(r >> 8); f[i * 4 + 2] = (uint8_t)(r >> 16);
    }
    size_t cap = tb_dpcm_max_size(w, h);
    uint8_t *good = malloc(cap);
    size_t len = tb_dpcm_encode(f, w * 4, w, h, good, cap);
    CHECK(len > 0, "encode for malformed-input tests");

    struct tb_dpcm_info in;
    CHECK(tb_dpcm_parse(good, len, &in) == 0, "the unmodified blob parses");

    uint8_t *bad = malloc(len);

    CHECK(tb_dpcm_parse(good, TB_DPCM_HEADER - 1, &in) != 0, "truncated header rejected");
    CHECK(tb_dpcm_parse(good, len - 1, &in) != 0, "truncated blob rejected");
    CHECK(tb_dpcm_parse(good, len + 1, &in) != 0, "over-long blob rejected");

    memcpy(bad, good, len); bad[0] ^= 0xFF;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "bad magic rejected");

    memcpy(bad, good, len); bad[12] = 4;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "unsupported tile size rejected");

    memcpy(bad, good, len); bad[13] = 4;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "unsupported channel count rejected");

    /* Width plane edited without the group table following: the declared offsets
     * no longer match the widths, which is exactly the shape of an attack that
     * would push a thread past the end of the payload. */
    memcpy(bad, good, len);
    bad[in.width_plane_off] ^= 0x0F;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "width/offset-table disagreement rejected");

    /* A group base pointing somewhere else entirely. */
    memcpy(bad, good, len);
    bad[in.group_table_off + 4] ^= 0x40;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "tampered group base rejected");

    /* A nibble claiming a width of 9..15, which no encoder emits. */
    memcpy(bad, good, len);
    bad[in.width_plane_off] |= 0x0F;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "out-of-range bit width rejected");

    memcpy(bad, good, len);
    bad[4] = 0; bad[5] = 0; bad[6] = 0; bad[7] = 0;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "zero width rejected");

    free(bad); free(good); free(f);
}

/* The encoder must refuse rather than overrun when handed a buffer that is even
 * one byte short of what it promised it would need. */
static void test_encode_respects_capacity(void) {
    const int w = 64, h = 64;
    uint8_t *f = frame_alloc(w, h);
    size_t cap = tb_dpcm_max_size(w, h);
    uint8_t *dst = malloc(cap);
    CHECK(tb_dpcm_encode(f, w * 4, w, h, dst, cap - 1) == 0, "short buffer refused");
    CHECK(tb_dpcm_encode(f, w * 4, w, h, dst, cap) > 0, "exact buffer accepted");
    CHECK(tb_dpcm_encode(f, w * 4 - 1, w, h, dst, cap) == 0, "stride below the row width refused");
    CHECK(tb_dpcm_encode(f, w * 4, 0, h, dst, cap) == 0, "zero width refused");
    free(dst); free(f);
}

int main(void) {
    test_flat();
    test_noise_does_not_expand();
    test_gradient();
    test_wraparound();
    test_partial_tiles();
    test_mixed_widths();
    test_parse_rejects_malformed();
    test_encode_respects_capacity();

    if (g_failures == 0) {
        printf("dpcm codec tests: %d checks passed\n", g_checks);
        return 0;
    }
    fprintf(stderr, "dpcm codec tests: %d/%d checks FAILED\n", g_failures, g_checks);
    return 1;
}
