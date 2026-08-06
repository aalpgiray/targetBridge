/* tb_metal_plane.m — the video plane, and the frame surface behind it.
 *
 * WHY THIS BYPASSES SDL AT ALL
 *
 * SDL2's 2D renderer has no 10-bit texture format on any macOS backend, so
 * asking it for ARGB2101010 silently lands on a scalar CPU converter that both
 * costs ~100 ms/frame at 5K and truncates to 8 bits. Measured on the target
 * iMac: 8-bit BGRA 12 ms/frame, the same frame as "10-bit" 102 ms/frame. SDL
 * keeps the window, input and status UI; this owns a sibling layer shown only
 * while video frames are arriving.
 *
 * TWO WAYS A FRAME ARRIVES
 *
 * An uncompressed frame is staged in a shared buffer and presented straight from
 * there, as it always was. A TBD2 frame (tb_dpcm.h) is uploaded compressed and
 * expanded by a compute kernel into a private buffer that lives in VRAM — at 5K
 * that is ~20 MB instead of 59 at 8-bit depth, ~32 MB at 10-bit.
 *
 * That the decoded frame lands in VRAM rather than in CPU-visible memory was
 * measured, not assumed: decoding into shared memory costs 17.2 ms/frame on the
 * target GPU against 7.5 ms into VRAM, and 17.2 ms alone exceeds the 16.67 ms
 * budget at 60 Hz.
 *
 * A compressed full frame therefore fits 60 Hz by itself, which is why damage
 * rectangles are not part of the TBD2 path at all — no base image, no patching,
 * no keyframe bookkeeping. Receivers that cannot decode TBD2 still get damage
 * packets, patched on the CPU and presented through the uncompressed path, since
 * for them it is the only thing that makes 5K viable.
 *
 * The cursor is composited by the render pass, NOT drawn into the frame. A
 * compressed frame never exists in CPU-visible memory, so there is nothing to
 * stamp it into.
 */

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Cocoa/Cocoa.h>

#include "tb_metal_plane.h"
#include "tb_dpcm.h"

#include <SDL.h>
#include <stdio.h>
#include <string.h>

/* Drawables the layer may hand out. Three is plenty for presenting once a frame. */
#define TB_METAL_RING 3

/* Upload staging slots.
 *
 * Sized for SLICES, not frames. This was 3, from when a frame was a single
 * upload — but a sliced frame takes one slot per band, so at 18 bands the
 * thread doing the uploading blocked on slot recycling eighteen times a frame.
 * That thread also services the window and the socket, so the receiver stopped
 * responding while the GPU caught up: not a deadlock, just the main thread used
 * as the throttle.
 *
 * A slice slot is a fraction of a frame (~1.7 MB at 18 bands against ~30 MB
 * whole), so depth is cheap where it used to be expensive. */
#define TB_UPLOAD_RING 32

/* Frames in flight. One surface is not enough once a frame arrives as bands:
 * the next frame's first band starts decoding while the current frame is still
 * being presented, and with a single buffer the screen shows bands from two
 * frames at once. Three is what the source spec called for and what the cost
 * justifies — 59 MB each against 4 GB of VRAM. */
#define TB_FRAME_RING 3

/* Mirrors DpcmParams in the shader. */
struct tb_dpcm_gpu_params {
    uint32_t width, height;
    uint32_t tilesX, tilesY;
    uint32_t tileCount;
    uint32_t outStridePx;
    uint32_t widthOff, seedOff, payOff;
    uint32_t bits;      /* 8 or 10; channel c sits at bit c*bits */
    uint32_t alpha;     /* opaque alpha, pre-shifted for this depth */
    /* First row of the destination this blob belongs to. A slice is simply a
     * shorter frame written further down the surface, which is why slicing needed
     * no new codec: the tiles were already independent. Zero for a whole frame. */
    uint32_t rowOffset;
};

static struct {
    int                   ready;
    SDL_MetalView         view;
    CAMetalLayer         *layer;
    id<MTLDevice>         dev;
    id<MTLCommandQueue>   queue;
    id<MTLRenderPipelineState>  pipe;        /* present + dither */
    id<MTLRenderPipelineState>  cursorPipe;  /* cursor overlay */
    id<MTLComputePipelineState> dpcmPipe;
    size_t                row_align;
    float                 dither;

    id<MTLBuffer>         ring[TB_UPLOAD_RING];
    size_t                ring_cap[TB_UPLOAD_RING];
    int                   ring_idx;
    dispatch_semaphore_t  inflight;

    /* Destinations for decoded frames, in VRAM. 4 bytes per pixel, rows padded
     * so a texture can be viewed over them. */
    id<MTLBuffer>         frame[TB_FRAME_RING];
    size_t                frame_cap[TB_FRAME_RING];
    int                   frame_widx;      /* being decoded into */
    int                   frame_open;      /* a frame holds a ring slot */
    dispatch_semaphore_t  frames_free;
    size_t                frame_bpr;
    int                   frame_w, frame_h;


    id<MTLTexture>        curTex;
    int                   cur_tex_w, cur_tex_h;
    float                 cur_tex_scale;      /* what curTex was built for */
    int                   cur_x, cur_y, cur_sw, cur_sh, cur_visible, cur_type;

    int                   shown;
    /* Default on: tearing should be opted into, never inherited. */
    int                   vsync;
    int                   vsync_initialised;
} g;

void tb_metal_plane_set_vsync(int enabled) {
    const int want = enabled ? 1 : 0;
    if (g.vsync == want) return;
    g.vsync = want;
    /* Applies immediately when a layer exists, and is re-applied at init, so the
     * choice survives the plane being torn down and rebuilt. */
    if (g.layer) g.layer.displaySyncEnabled = want ? YES : NO;
    fprintf(stderr, "[metal] vsync %s\n", want ? "on" : "off (lower latency, may tear)");
}

void tb_metal_plane_set_cursor(int x, int y, int source_w, int source_h,
                               int visible, int type) {
    g.cur_x = x; g.cur_y = y;
    g.cur_sw = source_w > 0 ? source_w : 1;
    g.cur_sh = source_h > 0 ? source_h : 1;
    g.cur_visible = visible;
    g.cur_type = type;
}

/* ------------------------------------------------------------- cursor sprite */

/* Even-odd scanline fill; the arrow is non-convex so a simple span fill will
 * not do. Coordinates are floats in sprite space. */
static void tb_fill_poly(uint32_t *px, int w, int h, int stride,
                         const float *xs, const float *ys, int n,
                         uint32_t colour) {
    float miny = ys[0], maxy = ys[0];
    for (int i = 1; i < n; ++i) { if (ys[i] < miny) miny = ys[i]; if (ys[i] > maxy) maxy = ys[i]; }
    int y0 = (int)miny; if (y0 < 0) y0 = 0;
    int y1 = (int)maxy + 1; if (y1 > h) y1 = h;

    for (int y = y0; y < y1; ++y) {
        float cy = (float)y + 0.5f;
        float xi[16];
        int   cnt = 0;
        for (int i = 0, j = n - 1; i < n && cnt < 16; j = i++) {
            if ((ys[i] > cy) != (ys[j] > cy)) {
                float t = (cy - ys[i]) / (ys[j] - ys[i]);
                xi[cnt++] = xs[i] + t * (xs[j] - xs[i]);
            }
        }
        for (int a = 0; a < cnt - 1; ++a)          /* insertion sort, tiny n */
            for (int b = a + 1; b < cnt; ++b)
                if (xi[b] < xi[a]) { float t = xi[a]; xi[a] = xi[b]; xi[b] = t; }
        for (int s = 0; s + 1 < cnt; s += 2) {
            int xa = (int)xi[s], xb = (int)xi[s + 1];
            if (xa < 0) xa = 0;
            if (xb > w) xb = w;
            uint32_t *row = px + (size_t)y * stride;
            for (int x = xa; x < xb; ++x) row[x] = colour;
        }
    }
}

/* The arrow, in units later multiplied by `scale`. */
static const float kArrowX[7] = { 0.f, 0.f,  4.5f, 7.5f, 10.5f, 7.5f, 12.f };
static const float kArrowY[7] = { 0.f, 17.f, 13.f, 20.f, 19.f,  12.f, 12.f };
#define TB_CUR_PAD 2   /* the black outline reaches this far from the shape */

/* Build the cursor into a small texture, once per scale. Drawn black-offset-then
 * white so it stays legible on any background — the same reason the SDL path
 * outlines it. Alpha is zero everywhere the arrow is not, so the render pass can
 * blend it over the video without touching the frame. */
static void tb_cursor_build(float scale) {
    if (g.curTex && g.cur_tex_scale == scale) return;

    const int w = (int)(12.f * scale) + 2 * TB_CUR_PAD + 2;
    const int h = (int)(20.f * scale) + 2 * TB_CUR_PAD + 2;
    uint32_t *px = calloc((size_t)w * h, 4);
    if (!px) return;

    float bx[7], by[7];
    const int off[8][2] = {{-2,0},{2,0},{0,-2},{0,2},{-2,-2},{2,-2},{-2,2},{2,2}};
    for (int k = 0; k < 8; ++k) {
        for (int i = 0; i < 7; ++i) {
            bx[i] = TB_CUR_PAD + kArrowX[i] * scale + (float)off[k][0];
            by[i] = TB_CUR_PAD + kArrowY[i] * scale + (float)off[k][1];
        }
        tb_fill_poly(px, w, h, w, bx, by, 7, 0xFF000000u);
    }
    for (int i = 0; i < 7; ++i) {
        bx[i] = TB_CUR_PAD + kArrowX[i] * scale;
        by[i] = TB_CUR_PAD + kArrowY[i] * scale;
    }
    tb_fill_poly(px, w, h, w, bx, by, 7, 0xFFFFFFFFu);

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:(NSUInteger)w
                                                         height:(NSUInteger)h
                                                      mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeManaged;
    g.curTex = [g.dev newTextureWithDescriptor:td];
    if (g.curTex) {
        [g.curTex replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
                    mipmapLevel:0
                      withBytes:px
                    bytesPerRow:(NSUInteger)w * 4];
        g.cur_tex_w = w;
        g.cur_tex_h = h;
        g.cur_tex_scale = scale;
    }
    free(px);
}

/* ------------------------------------------------------------------- shaders */

static NSString *tb_shader_source(void) {
    return
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct VOut { float4 pos [[position]]; float2 uv; };\n"
    "\n"
    "vertex VOut tb_vs(uint vid [[vertex_id]]) {\n"
    "  float2 p = float2((vid << 1) & 2, vid & 2);\n"
    "  VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y);\n"
    "  return o;\n"
    "}\n"
    /* Dither on presentation.
     *
     * macOS adds sub-LSB noise on the way to the panel, which is why 8-bit
     * gradients look smooth everywhere else in the OS. A CAMetalLayer writing
     * straight to a 10-bit drawable never picks that up, so quantisation the
     * rest of the system hides is plainly visible in our window — measured with
     * a synthetic ramp: an 8-bit half banded here while the same data was
     * smooth in any ordinary window.
     *
     * An 8x8 ordered matrix, not random noise. White noise of the same
     * amplitude reads as canvas texture across the whole image, because its
     * energy sits at all spatial frequencies including the low ones the eye is
     * most sensitive to. An ordered pattern puts its energy where the eye does
     * not resolve it, which is why GPUs dither this way. */
    "constant float bayer[64] = {\n"
    "  0,32,8,40,2,34,10,42, 48,16,56,24,50,18,58,26,\n"
    " 12,44,4,36,14,46,6,38, 60,28,52,20,62,30,54,22,\n"
    "  3,35,11,43,1,33,9,41, 51,19,59,27,49,17,57,25,\n"
    " 15,47,7,39,13,45,5,37, 63,31,55,23,61,29,53,21 };\n"
    "fragment float4 tb_fs(VOut in [[stage_in]],\n"
    "                      texture2d<float> tex [[texture(0)]],\n"
    "                      constant float &amp [[buffer(0)]]) {\n"
    "  constexpr sampler s(filter::nearest, address::clamp_to_edge);\n"
    "  float4 c = tex.sample(s, in.uv);\n"
    "  uint2 q = uint2(in.pos.xy);\n"
    "  float t = (bayer[(q.y & 7) * 8 + (q.x & 7)] + 0.5) / 64.0 - 0.5;\n"
    "  c.rgb += t * amp;\n"
    "  return c;\n"
    "}\n"
    "\n"
    /* Cursor overlay: a blended quad, positioned in normalised device
     * coordinates by the host so the sprite needs no scaling here. */
    "vertex VOut tb_cursor_vs(uint vid [[vertex_id]],\n"
    "                         constant float4 &r [[buffer(0)]]) {\n"
    "  float2 c = float2((vid == 1 || vid == 2 || vid == 4) ? r.z : r.x,\n"
    "                    (vid == 2 || vid == 4 || vid == 5) ? r.w : r.y);\n"
    "  float2 uv = float2((c.x - r.x) / (r.z - r.x), (c.y - r.y) / (r.w - r.y));\n"
    "  VOut o; o.pos = float4(c, 0, 1); o.uv = float2(uv.x, 1.0 - uv.y);\n"
    "  return o;\n"
    "}\n"
    "fragment float4 tb_cursor_fs(VOut in [[stage_in]],\n"
    "                             texture2d<float> tex [[texture(0)]]) {\n"
    "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
    "  return tex.sample(s, in.uv);\n"
    "}\n"
    "\n"
    /* ---- TBD1 decode ----
     *
     * One threadgroup per 8x8 tile, one thread per pixel. Tile size, and this
     * mapping, are both measured choices:
     *
     * One thread per TILE — the obvious mapping, since DPCM is serial along the
     * prediction direction — measured 100 ms/frame on the target GPU against
     * 7.5 ms for this one. The reason is memory, not arithmetic: with a thread
     * per tile, the 64 lanes of a wave each read a different scattered byte and
     * each pulls its own cache line to extract a few bits from it. With a thread
     * per pixel, adjacent lanes read adjacent bit ranges, so a whole
     * tile-channel's residuals fall inside one or two lines.
     *
     * The serial dependency is not a problem because DPCM along a row is a
     * prefix sum, and a prefix sum is parallel. Each thread reads only its own
     * residual, then two short prefixes resolve out of threadgroup memory: down
     * column 0 for the row starts, and along the row for everything else.
     *
     * The tile's own payload offset is derived here rather than transmitted. The
     * blob carries one base offset per group of 64 tiles, and this threadgroup's
     * 64 threads each price one earlier tile in their group and reduce. Shipping
     * an offset per tile would cost 921 KB a frame and wreck the ratio on
     * exactly the flat content where it is largest.
     *
     * There are no bounds checks: tb_dpcm_parse has already re-derived the whole
     * offset table from the width plane and rejected the blob unless it agrees,
     * so every offset computed here is inside the payload by construction. */
    "struct DpcmParams {\n"
    "  uint width, height, tilesX, tilesY, tileCount, outStridePx;\n"
    "  uint widthOff, seedOff, payOff;\n"
    "  uint bits, alpha, rowOffset;\n"
    "};\n"
    "static inline uint tb_width_get(device const uchar *plane, uint idx) {\n"
    "  uchar b = plane[idx >> 1];\n"
    "  return (idx & 1u) ? uint(b >> 4) : uint(b & 0xF);\n"
    "}\n"
    /* n reaches 10 at 10-bit depth and the offset within a byte reaches 7, so a
     * value can span three bytes. */
    "static inline uint tb_bits_at(device const uchar *buf, uint p, uint n) {\n"
    "  if (n == 0u) return 0u;\n"
    "  uint byte = p >> 3, sh = p & 7u;\n"
    "  uint x = uint(buf[byte]);\n"
    "  if (sh + n >  8u) x |= uint(buf[byte + 1]) << 8;\n"
    "  if (sh + n > 16u) x |= uint(buf[byte + 2]) << 16;\n"
    "  return (x >> sh) & ((1u << n) - 1u);\n"
    "}\n"
    "static inline int tb_unzig(uint z) { return int((z >> 1) ^ (~(z & 1u) + 1u)); }\n"
    "\n"
    "kernel void tb_dpcm_decode(device const uchar *blob  [[buffer(0)]],\n"
    "                           device const uint  *gtab  [[buffer(1)]],\n"
    "                           device       uint  *out   [[buffer(2)]],\n"
    "                           constant DpcmParams &P    [[buffer(3)]],\n"
    "                           uint tile [[threadgroup_position_in_grid]],\n"
    "                           uint lane [[thread_position_in_threadgroup]]) {\n"
    "  device const uchar *wp = blob + P.widthOff;\n"
    "  device const uint  *seeds = (device const uint *)(blob + P.seedOff);\n"
    "  device const uchar *pay = blob + P.payOff;\n"
    "  const uint grp = tile / 64u, idx = tile % 64u;\n"
    "\n"
    "  uint jcost = 0u;\n"
    "  {\n"
    "    const uint jt = grp * 64u + lane;\n"
    "    if (lane < idx && jt < P.tileCount) {\n"
    "      const uint jx = jt % P.tilesX, jy = jt / P.tilesX;\n"
    "      const uint jw = min(8u, P.width  - jx * 8u);\n"
    "      const uint jh = min(8u, P.height - jy * 8u);\n"
    "      const uint jn = tb_width_get(wp, jt * 3u + 0u)\n"
    "                    + tb_width_get(wp, jt * 3u + 1u)\n"
    "                    + tb_width_get(wp, jt * 3u + 2u);\n"
    "      jcost = jn * (jw * jh - 1u);\n"
    "    }\n"
    "  }\n"
    "  threadgroup uint red[64];\n"
    "  red[lane] = jcost;\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  for (uint off = 32u; off > 0u; off >>= 1) {\n"
    "    if (lane < off) red[lane] += red[lane + off];\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  }\n"
    "\n"
    "  const uint x = lane & 7u, y = lane >> 3;\n"
    "  const uint txi = tile % P.tilesX, tyi = tile / P.tilesX;\n"
    "  const uint tw = min(8u, P.width  - txi * 8u);\n"
    "  const uint th = min(8u, P.height - tyi * 8u);\n"
    "  const uint coded = tw * th - 1u;\n"
    "  const bool live = (x < tw && y < th);\n"
    "\n"
    "  const uint n0 = tb_width_get(wp, tile * 3u + 0u);\n"
    "  const uint n1 = tb_width_get(wp, tile * 3u + 1u);\n"
    "  const uint n2 = tb_width_get(wp, tile * 3u + 2u);\n"
    /* The group base the wire carries is already byte-aligned; within a group
     * residuals are packed with no padding, so the scan is an exact bit sum. */
    "  const uint b0 = gtab[grp] + red[0];\n"
    "  const uint b1 = b0 + n0 * coded;\n"
    "  const uint b2 = b1 + n1 * coded;\n"
    "\n"
    "  int3 d = int3(0);\n"
    "  if (live && !(x == 0u && y == 0u)) {\n"
    "    const uint k = y * tw + x - 1u;\n"
    "    d.x = tb_unzig(tb_bits_at(pay, b0 + k * n0, n0));\n"
    "    d.y = tb_unzig(tb_bits_at(pay, b1 + k * n1, n1));\n"
    "    d.z = tb_unzig(tb_bits_at(pay, b2 + k * n2, n2));\n"
    "  }\n"
    "\n"
    "  threadgroup int3 rowd[64];\n"
    "  threadgroup int3 cold[8];\n"
    "  rowd[lane] = (x == 0u) ? int3(0) : d;\n"
    "  if (x == 0u) cold[y] = (y == 0u) ? int3(0) : d;\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  if (!live) return;\n"
    "\n"
    "  int3 acc = int3(0);\n"
    "  for (uint j = 1u; j <= y; ++j) acc += cold[j];\n"
    "  for (uint i = 1u; i <= x; ++i) acc += rowd[y * 8u + i];\n"
    "\n"
    /* One LE uint32 per tile holds the seed pixel at either depth. */
    "  const uint mask = (1u << P.bits) - 1u;\n"
    "  const uint sraw = seeds[tile];\n"
    "  const int3 seed = int3(int((sraw >> (0u * P.bits)) & mask),\n"
    "                         int((sraw >> (1u * P.bits)) & mask),\n"
    "                         int((sraw >> (2u * P.bits)) & mask));\n"
    "  const uint3 v = uint3(seed + acc) & mask;\n"
    "  out[(P.rowOffset + tyi * 8u + y) * P.outStridePx + (txi * 8u + x)] =\n"
    "      P.alpha | v.x | (v.y << P.bits) | (v.z << (2u * P.bits));\n"
    "}\n";
}

/* ---------------------------------------------------------------------- setup */

int tb_metal_plane_init(SDL_Window *win) {
    if (g.ready) return 0;
    if (!win) return -1;
    /* `g` is zero-initialised, so without this the first plane would come up
     * with vsync off — the opposite of the intended default. */
    if (!g.vsync_initialised) { g.vsync_initialised = 1; g.vsync = 1; }

    g.dev = MTLCreateSystemDefaultDevice();
    if (!g.dev) { fprintf(stderr, "[metal] no Metal device\n"); return -1; }

    g.view = SDL_Metal_CreateView(win);
    if (!g.view) {
        fprintf(stderr, "[metal] SDL_Metal_CreateView: %s\n", SDL_GetError());
        g.dev = nil;
        return -1;
    }

    g.layer = (__bridge CAMetalLayer *)SDL_Metal_GetLayer(g.view);
    if (!g.layer) { fprintf(stderr, "[metal] no CAMetalLayer\n"); return -1; }

    g.layer.device = g.dev;
    g.layer.pixelFormat = MTLPixelFormatBGR10A2Unorm;
    g.layer.framebufferOnly = NO;
    g.layer.opaque = YES;
    g.layer.maximumDrawableCount = TB_METAL_RING;
    g.layer.displaySyncEnabled = g.vsync ? YES : NO;
    /* Tag the layer with the space the pixels are actually in, which is what
     * the sender captures: Display P3.
     *
     * This used to be the *panel's* profile, chosen to avoid a per-frame
     * conversion. That was wrong: it tells the compositor the values are
     * already in display space, so the conversion P3 data needs is skipped.
     * On a panel using its own calibrated profile that shows up as banding in
     * dark gradients and a colour shift — and setting the display profile to
     * P3 by hand "fixed" it only by making the mislabel accidentally true.
     * Labelling correctly lets the compositor convert, in its own higher
     * precision, on the GPU. */
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    if (cs) { g.layer.colorspace = cs; CGColorSpaceRelease(cs); }

    /* What the panel is actually capable of receiving. A 10-bit drawable still
     * gets quantised at scanout if the display is running an 8-bit mode, and
     * that looks exactly like a pipeline that never carried 10 bits. */
    {
        NSScreen *scr = [NSScreen mainScreen];
        CGColorSpaceRef dcs = CGDisplayCopyColorSpace(CGMainDisplayID());
        CFStringRef name = dcs ? CGColorSpaceCopyName(dcs) : NULL;
        fprintf(stderr,
                "[metal] drawable=BGR10A2Unorm  panel bits/sample=%ld  P3=%d  maxEDR=%.2f  colorspace=%s\n",
                (long)NSBitsPerSampleFromDepth(scr.depth),
                (int)[scr canRepresentDisplayGamut:NSDisplayGamutP3],
                (double)scr.maximumExtendedDynamicRangeColorComponentValue,
                name ? [(__bridge NSString *)name UTF8String] : "?");
        if (name) CFRelease(name);
        if (dcs) CGColorSpaceRelease(dcs);
    }

    NSError *err = nil;
    id<MTLLibrary> lib = [g.dev newLibraryWithSource:tb_shader_source() options:nil error:&err];
    if (!lib) {
        fprintf(stderr, "[metal] shader compile failed: %s\n",
                err.localizedDescription.UTF8String ?: "?");
        return -1;
    }

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction   = [lib newFunctionWithName:@"tb_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"tb_fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGR10A2Unorm;
    g.pipe = [g.dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g.pipe) {
        fprintf(stderr, "[metal] pipeline failed: %s\n",
                err.localizedDescription.UTF8String ?: "?");
        return -1;
    }

    MTLRenderPipelineDescriptor *cd = [MTLRenderPipelineDescriptor new];
    cd.vertexFunction   = [lib newFunctionWithName:@"tb_cursor_vs"];
    cd.fragmentFunction = [lib newFunctionWithName:@"tb_cursor_fs"];
    cd.colorAttachments[0].pixelFormat = MTLPixelFormatBGR10A2Unorm;
    cd.colorAttachments[0].blendingEnabled = YES;
    cd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    cd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    cd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    cd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    g.cursorPipe = [g.dev newRenderPipelineStateWithDescriptor:cd error:&err];
    if (!g.cursorPipe)
        fprintf(stderr, "[metal] cursor pipeline failed: %s\n",
                err.localizedDescription.UTF8String ?: "?");

    /* The decode pipeline is optional: without it the plane still presents
     * uncompressed frames, and the receiver simply does not advertise
     * "supportsDPCM", so the sender keeps sending them. */
    g.dpcmPipe = [g.dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"tb_dpcm_decode"]
                                                     error:&err];
    if (!g.dpcmPipe)
        fprintf(stderr, "[metal] dpcm pipeline failed: %s\n",
                err.localizedDescription.UTF8String ?: "?");

    g.dither = 0.5f / 255.0f;   /* half an 8-bit step = ~2 levels at 10-bit */
    const char *denv = getenv("TB_DITHER");
    if (denv) {
        float scale = (float)atof(denv);
        if (scale >= 0.0f && scale <= 8.0f) g.dither = scale / 255.0f;
    }
    fprintf(stderr, "[metal] dither %.2f of an 8-bit step (%.1f levels at 10-bit)\n",
            g.dither * 255.0f, g.dither * 1023.0f);

    /* Buffer-backed textures need their rows aligned; the frame surface pads to
     * this rather than to the frame width. */
    g.row_align = [g.dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGR10A2Unorm];
    if (g.row_align == 0) g.row_align = 256;

    g.queue = [g.dev newCommandQueue];
    g.inflight = dispatch_semaphore_create(TB_UPLOAD_RING);
    g.frames_free = dispatch_semaphore_create(TB_FRAME_RING);
    g.frame_widx = 0;
    g.frame_open = 0;
    g.ring_idx = 0;
    g.ready = 1;
    g.shown = 1;

    fprintf(stderr, "[metal] plane ready on %s (dpcm=%s)\n",
            [[g.dev name] UTF8String], g.dpcmPipe ? "yes" : "no");
    return 0;
}

void tb_metal_plane_shutdown(void) {
    if (!g.ready) return;
    g.shown = 0;
    g.frame_w = g.frame_h = 0;
    /* Drain: reclaim every ring slot so no command buffer is still reading a
     * buffer (or the layer) when we release them. */
    if (g.inflight) {
        dispatch_semaphore_t sem = g.inflight;
        for (int i = 0; i < TB_UPLOAD_RING; ++i) {
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        }
        /* Hand the counts back before releasing. libdispatch raises SIGILL
         * ("semaphore deallocated while in use") if a semaphore is disposed
         * with a value below the one it was created with — draining it to 0
         * and then dropping the reference crashed on every teardown. */
        for (int i = 0; i < TB_UPLOAD_RING; ++i) {
            dispatch_semaphore_signal(sem);
        }
        g.inflight = nil;
    }
    if (g.frames_free) {
        /* Same discipline as `inflight`: drain to prove nothing is in flight,
         * then hand the counts back, because libdispatch raises SIGILL if a
         * semaphore is disposed below the value it was created with. */
        dispatch_semaphore_t fs = g.frames_free;
        for (int i = 0; i < TB_FRAME_RING; ++i) dispatch_semaphore_wait(fs, DISPATCH_TIME_FOREVER);
        for (int i = 0; i < TB_FRAME_RING; ++i) dispatch_semaphore_signal(fs);
        g.frames_free = nil;
    }
    for (int i = 0; i < TB_UPLOAD_RING; ++i) { g.ring[i] = nil; g.ring_cap[i] = 0; }
    for (int i = 0; i < TB_FRAME_RING; ++i) { g.frame[i] = nil; g.frame_cap[i] = 0; }
    g.frame_open = 0; g.frame_widx = 0;
    g.curTex = nil; g.cur_tex_scale = 0.f;
    g.pipe = nil; g.cursorPipe = nil; g.dpcmPipe = nil;
    g.queue = nil;
    g.dev = nil;
    g.layer = nil;
    if (g.view) { SDL_Metal_DestroyView(g.view); g.view = NULL; }
    g.ready = 0;
}

int tb_metal_plane_available(void) { return g.ready; }

int tb_metal_plane_supports_dpcm(void) {
    if (g.ready) return g.dpcmPipe != nil;

    /* The answer is needed at connect time, in the display profile, but the plane
     * is not created until the first frame arrives — it sits over SDL's window
     * and would hide the status UI. So probe standalone: make a device, compile
     * the library, build the pipeline. Nothing short of that is evidence, and
     * claiming the capability we cannot deliver would leave the sender
     * transmitting frames this receiver has no way to display.
     *
     * Cached because it costs a shader compile, and answered once per process. */
    static int cached = -1;
    if (cached >= 0) return cached;
    cached = 0;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return cached;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:tb_shader_source() options:nil error:&err];
        if (!lib) {
            fprintf(stderr, "[metal] dpcm probe: shader failed: %s\n",
                    err.localizedDescription.UTF8String ?: "?");
            return cached;
        }
        id<MTLComputePipelineState> p =
            [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"tb_dpcm_decode"]
                                              error:&err];
        cached = p != nil;
        fprintf(stderr, "[metal] dpcm decode %s on %s\n",
                cached ? "available" : "unavailable", [[dev name] UTF8String]);
    }
    return cached;
}

void tb_metal_plane_set_hidden(int hidden) {
    if (!hidden) return;
    /* Fully remove the view: hiding the layer is not enough to reveal the
     * OpenGL content underneath. Only fires on an actual transition. */
    if (g.ready && g.shown) {
        g.shown = 0;
        tb_metal_plane_shutdown();
        fprintf(stderr, "[metal] plane released; SDL owns the window\n");
    }
}

/* ---------------------------------------------------------------- geometry */

/* Drive the layer at the frame's own resolution and let Core Animation scale it
 * to the window. On this 5K panel fullscreen they match, so scaling is free;
 * when they don't, the compositor handles it. */
static size_t tb_row_bytes(int w) {
    const size_t tight = (size_t)w * 4;
    return ((tight + g.row_align - 1) / g.row_align) * g.row_align;
}

static void tb_geometry_set(int w, int h) {
    if (g.frame_w == w && g.frame_h == h) return;
    g.frame_w = w; g.frame_h = h;
    g.frame_bpr = tb_row_bytes(w);
    g.layer.drawableSize = CGSizeMake(w, h);
    fprintf(stderr, "[metal] drawable %dx%d\n", w, h);
}

/* Take an upload slot. The caller must signal `inflight` if it does not go on to
 * submit a command buffer that signals it on completion. */
static id<MTLBuffer> tb_upload_take(size_t bytes) {
    /* Bounded for the same reason the frame-surface wait is: this runs on the
     * thread that services the window. Returning nil drops a band, which costs
     * one stale strip for a frame; blocking costs the whole session. */
    const dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC);
    if (dispatch_semaphore_wait(g.inflight, deadline) != 0) {
        static int warned = 0;
        if (!warned) {
            warned = 1;
            fprintf(stderr, "[metal] upload ring exhausted; dropping bands\n");
        }
        return nil;
    }
    int slot = g.ring_idx;
    g.ring_idx = (g.ring_idx + 1) % TB_UPLOAD_RING;
    if (g.ring_cap[slot] < bytes) {
        g.ring[slot] = [g.dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        g.ring_cap[slot] = g.ring[slot] ? bytes : 0;
    }
    if (!g.ring[slot]) { dispatch_semaphore_signal(g.inflight); return nil; }
    return g.ring[slot];
}

/* Draw `src` into the next drawable, dither it, and blend the cursor on top.
 * Consumes the `inflight` count that the caller took.
 *
 * `src` is a texture VIEW over a buffer, not a copy — for an uncompressed frame
 * that is the staging buffer the CPU just filled, and for a TBD1 frame it is the
 * VRAM buffer the decode kernel just wrote. Either way the shader samples those
 * bytes in place. */
static int tb_present(id<MTLCommandBuffer> cb, id<MTLBuffer> src,
                      MTLStorageMode mode, int ten_bit) {
    id<CAMetalDrawable> drawable = [g.layer nextDrawable];
    if (!drawable) { dispatch_semaphore_signal(g.inflight); return -1; }

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
             ten_bit ? MTLPixelFormatBGR10A2Unorm : MTLPixelFormatBGRA8Unorm
                                                          width:(NSUInteger)g.frame_w
                                                         height:(NSUInteger)g.frame_h
                                                      mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = mode;
    id<MTLTexture> srcTex = [src newTextureWithDescriptor:td offset:0
                                             bytesPerRow:g.frame_bpr];
    if (!srcTex) { dispatch_semaphore_signal(g.inflight); return -1; }

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture     = drawable.texture;
    rp.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:g.pipe];
    [enc setFragmentTexture:srcTex atIndex:0];
    [enc setFragmentBytes:&g.dither length:sizeof(g.dither) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    if (g.cur_visible && g.cursorPipe) {
        const float scale = ((g.frame_w >= 5000) ? 58.f : 44.f) / 24.f;
        tb_cursor_build(scale);
        if (g.curTex) {
            /* Cursor coordinates arrive in the sender's source-frame space, which
             * is not necessarily the frame we are showing. */
            const float sx = (float)g.frame_w / (float)g.cur_sw;
            const float sy = (float)g.frame_h / (float)g.cur_sh;
            const float px = (float)g.cur_x * sx - (float)TB_CUR_PAD;
            const float py = (float)g.cur_y * sy - (float)TB_CUR_PAD;
            /* Pixels to normalised device coordinates; y is flipped. */
            const float x0 =  (px / (float)g.frame_w) * 2.f - 1.f;
            const float x1 = ((px + (float)g.cur_tex_w) / (float)g.frame_w) * 2.f - 1.f;
            const float y0 = 1.f -  (py / (float)g.frame_h) * 2.f;
            const float y1 = 1.f - ((py + (float)g.cur_tex_h) / (float)g.frame_h) * 2.f;
            const float rect[4] = { x0, y0, x1, y1 };
            [enc setRenderPipelineState:g.cursorPipe];
            [enc setVertexBytes:rect length:sizeof(rect) atIndex:0];
            [enc setFragmentTexture:g.curTex atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }
    }
    [enc endEncoding];

    [cb presentDrawable:drawable];
    /* Capture the semaphore itself: reading g.inflight at completion time would
     * signal a *replacement* if the plane was torn down meanwhile. */
    dispatch_semaphore_t sem = g.inflight;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
        (void)done;
        dispatch_semaphore_signal(sem);
    }];
    [cb commit];
    return 0;
}

/* -------------------------------------------------------------- entry points */

int tb_metal_plane_render_packed(const uint8_t *px, int stride, int w, int h,
                                 int ten_bit) {
    if (!g.ready || !px || w <= 0 || h <= 0) return -1;

    @autoreleasepool {
        tb_geometry_set(w, h);

        const size_t tight = (size_t)w * 4;
        const size_t bytes = g.frame_bpr * (size_t)h;
        id<MTLBuffer> up = tb_upload_take(bytes);
        if (!up) return -1;

        uint8_t *dst = (uint8_t *)[up contents];
        if ((size_t)stride == g.frame_bpr) {
            memcpy(dst, px, bytes);
        } else {
            for (int y = 0; y < h; ++y)
                memcpy(dst + (size_t)y * g.frame_bpr, px + (size_t)y * stride, tight);
        }

        id<MTLCommandBuffer> cb = [g.queue commandBuffer];
        return tb_present(cb, up, MTLStorageModeShared, ten_bit);
    }
}

/* Size the VRAM destination currently being written. Returns 0 on success. */
static int tb_frame_ensure(void) {
    const int i = g.frame_widx;
    const size_t need = g.frame_bpr * (size_t)g.frame_h;
    if (g.frame_cap[i] < need) {
        g.frame[i] = [g.dev newBufferWithLength:need options:MTLResourceStorageModePrivate];
        g.frame_cap[i] = g.frame[i] ? need : 0;
    }
    return g.frame[i] ? 0 : -1;
}

int tb_metal_plane_render_dpcm(const uint8_t *blob, size_t len) {
    /* A whole frame is the single-slice case: one band, at row 0, presented
     * immediately. Kept as one code path so the sliced path is the tested one
     * even when the sender is not slicing. */
    return tb_metal_plane_render_dpcm_slice(blob, len, 0, 0, 0, 1);
}

int tb_metal_plane_render_dpcm_slice(const uint8_t *blob, size_t len,
                                     int frame_w, int frame_h, int y0,
                                     int is_last) {
    if (!g.ready || !g.dpcmPipe || !blob) return -1;

    /* Validate before anything touches the GPU. This is also what lets the
     * shader run without a single bounds check: parse re-derives the entire
     * offset table from the width plane and rejects the blob unless its own
     * table agrees. */
    struct tb_dpcm_info in;
    if (tb_dpcm_parse(blob, len, &in) != 0) {
        fprintf(stderr, "[metal] rejected malformed TBD2 blob (%zu bytes)\n", len);
        return -1;
    }

    /* A slice describes a band of a larger surface; a whole frame describes
     * itself. Passing 0 for the frame size means "this blob is the frame". */
    if (frame_w <= 0 || frame_h <= 0) { frame_w = in.width; frame_h = in.height; }
    if (in.width != frame_w) return -1;                       /* bands are full width */
    if (y0 < 0 || (int64_t)y0 + in.height > frame_h) return -1;
    if (y0 % TB_DPCM_TILE) return -1;                         /* must land on a tile row */

    @autoreleasepool {
        tb_geometry_set(frame_w, frame_h);

        /* Claim a ring slot for this frame. Held until the frame presents, so
         * the next frame's bands cannot land in a surface still on screen. */
        if (!g.frame_open) {
            /* A frame may only begin at its first band. Otherwise a frame whose
             * start was dropped would decode its remaining bands over whatever
             * the slot last held and present a mixture — the failure this ring
             * exists to prevent. */
            if (y0 != 0) return -1;
            /* Bounded, never DISPATCH_TIME_FOREVER: this runs on the thread that
             * also services the window, so an unbounded wait turns a GPU backlog
             * into an unresponsive app. Dropping a frame costs one stale 16.7 ms
             * on a fixed-refresh panel; blocking costs the whole session. */
            const dispatch_time_t deadline =
                dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC);
            if (dispatch_semaphore_wait(g.frames_free, deadline) != 0) {
                static int warned = 0;
                if (!warned) {
                    warned = 1;
                    fprintf(stderr, "[metal] all %d frame surfaces busy; dropping frames\n",
                            TB_FRAME_RING);
                }
                return -1;
            }
            g.frame_open = 1;
        }
        if (tb_frame_ensure() != 0) {
            dispatch_semaphore_signal(g.frames_free);
            g.frame_open = 0;
            return -1;
        }
        id<MTLBuffer> dst = g.frame[g.frame_widx];

        id<MTLBuffer> up = tb_upload_take(len);
        if (!up) return -1;
        memcpy([up contents], blob, len);

        /* The blob is bound whole and the planes reached by offset, because
         * Metal wants buffer offsets 4-byte aligned and the seed and payload
         * planes can start anywhere. The group table is the one exception: it
         * always begins at TB_DPCM_HEADER, which is aligned, so it can be bound
         * as uint32 directly. */
        struct tb_dpcm_gpu_params P = {
            (uint32_t)in.width, (uint32_t)in.height,
            (uint32_t)in.tiles_x, (uint32_t)in.tiles_y,
            in.tile_count, (uint32_t)(g.frame_bpr / 4),
            (uint32_t)in.width_plane_off, (uint32_t)in.seed_plane_off,
            (uint32_t)in.payload_off,
            in.ten_bit ? 10u : 8u,
            in.ten_bit ? (3u << 30) : (0xFFu << 24),
            (uint32_t)y0
        };

        id<MTLCommandBuffer> cb = [g.queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:g.dpcmPipe];
        [ce setBuffer:up offset:0 atIndex:0];
        [ce setBuffer:up offset:in.group_table_off atIndex:1];
        [ce setBuffer:dst offset:0 atIndex:2];
        [ce setBytes:&P length:sizeof(P) atIndex:3];
        [ce dispatchThreadgroups:MTLSizeMake(in.tile_count, 1, 1)
           threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];

        /* Bands other than the last are pure work: the GPU decodes band k while
         * band k+1 is still arriving, which is the whole point of slicing. Each
         * hands back the upload slot it took, which is only needed until the
         * decode reading it finishes.
         *
         * No explicit ordering between these decodes and the present below.
         * Command buffers on one MTLCommandQueue execute in the order they were
         * committed, so the present — committed last — already runs after every
         * band. An MTLEvent was tried here and is exactly wrong: events
         * synchronise ACROSS queues, and waiting on one within a single queue
         * deadlocks, which is what it did. */
        if (!is_last) {
            dispatch_semaphore_t sem = g.inflight;
            [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
                (void)done;
                dispatch_semaphore_signal(sem);
            }];
            [cb commit];
            return 0;
        }

        /* The last band shares its command buffer with the present, so the two
         * cannot be separated by anything. */
        const int presented_idx = g.frame_widx;
        g.frame_widx = (g.frame_widx + 1) % TB_FRAME_RING;
        g.frame_open = 0;

        dispatch_semaphore_t frames = g.frames_free;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
            (void)done;
            dispatch_semaphore_signal(frames);
        }];

        /* The blob says which depth it carries, so the texture view matches it.
         * At 8 bits the shader dithers into the 10-bit drawable — what macOS
         * does with 8-bit content everywhere else. At 10 bits the dither is
         * still applied but has almost nothing left to spread, because the
         * samples already resolve the drawable. */
        const int rc = tb_present(cb, g.frame[presented_idx], MTLStorageModePrivate, in.ten_bit);
        if (rc != 0) {
            /* tb_present returns without committing when no drawable is free, so
             * the handler above never runs and the ring slot would be lost —
             * three of those and the next frame blocks forever. */
            dispatch_semaphore_signal(frames);
        }
        return rc;
    }
}
