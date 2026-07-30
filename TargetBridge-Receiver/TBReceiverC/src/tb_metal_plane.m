/* tb_metal_plane.m — 10-bit video plane on a CAMetalLayer.
 *
 * SDL2's 2D renderer has no 10-bit texture format on any macOS backend, so
 * asking it for ARGB2101010 silently lands on a scalar CPU converter that both
 * costs ~100 ms/frame at 5K and truncates to 8 bits. Measured on the target
 * iMac: 8-bit BGRA 12 ms/frame, the same frame as "10-bit" 102 ms/frame.
 *
 * This bypasses SDL_Renderer for the 10-bit path only. The sender's capture
 * format ('l10r', ARGB2101010 little-endian) is bit-identical to Metal's
 * MTLPixelFormatBGR10A2Unorm, which is also macOS's native 30-bit scanout
 * format — so capture -> wire -> texture -> drawable -> panel involves no
 * conversion anywhere. SDL keeps the window, input and status UI; this owns a
 * sibling layer that is shown only while 10-bit frames are arriving.
 */

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Cocoa/Cocoa.h>

#include "tb_metal_plane.h"

#include <SDL.h>
#include <stdio.h>

/* Enough in-flight buffers that the CPU can fill frame N+1 while the GPU still
 * reads frame N, without ever allocating inside the frame loop (SDL's own Metal
 * backend reallocates a full-size staging buffer per frame — at 5K that alone
 * is 59 MB of allocation and first-touch faulting every frame). */
#define TB_METAL_RING 3

static struct {
    int                   ready;
    SDL_MetalView         view;
    CAMetalLayer         *layer;
    id<MTLDevice>         dev;
    id<MTLCommandQueue>   queue;
    id<MTLRenderPipelineState> pipe;
    size_t                row_align;
    float                 dither;
    id<MTLBuffer>         ring[TB_METAL_RING];
    size_t                ring_cap[TB_METAL_RING];
    int                   ring_idx;
    dispatch_semaphore_t  inflight;
    int                   frame_w, frame_h;
    int                   shown;
    int                   cur_x, cur_y, cur_sw, cur_sh, cur_visible, cur_type;
} g;

void tb_metal_plane_set_cursor(int x, int y, int source_w, int source_h,
                               int visible, int type) {
    g.cur_x = x; g.cur_y = y;
    g.cur_sw = source_w > 0 ? source_w : 1;
    g.cur_sh = source_h > 0 ? source_h : 1;
    g.cur_visible = visible;
    g.cur_type = type;
}

static inline uint32_t tb_pack10(uint32_t r, uint32_t g_, uint32_t b) {
    return (3u << 30) | ((r & 0x3FF) << 20) | ((g_ & 0x3FF) << 10) | (b & 0x3FF);
}

/* Even-odd scanline fill; the arrow is non-convex so a simple span fill will
 * not do. Coordinates are floats in frame space. */
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

/* Classic arrow, drawn black-offset-then-white so it stays legible on any
 * background — the same reason the SDL path outlines it. */
static void tb_draw_cursor_stride_fmt(uint32_t *px, int w, int h, int stride, int ten) {
    if (!g.cur_visible) return;

    const float ax[7] = { 0.f, 0.f,  4.5f, 7.5f, 10.5f, 7.5f, 12.f };
    const float ay[7] = { 0.f, 17.f, 13.f, 20.f, 19.f,  12.f, 12.f };

    float sx = (float)w / (float)g.cur_sw;
    float sy = (float)h / (float)g.cur_sh;
    float ox = (float)g.cur_x * sx;
    float oy = (float)g.cur_y * sy;
    float scale = ((w >= 5000) ? 58.f : 44.f) / 24.f;

    float bx[7], by[7];
    const int off[8][2] = {{-2,0},{2,0},{0,-2},{0,2},{-2,-2},{2,-2},{-2,2},{2,2}};
    for (int k = 0; k < 8; ++k) {
        for (int i = 0; i < 7; ++i) {
            bx[i] = ox + ax[i] * scale + (float)off[k][0];
            by[i] = oy + ay[i] * scale + (float)off[k][1];
        }
        tb_fill_poly(px, w, h, stride, bx, by, 7, ten ? tb_pack10(0, 0, 0) : 0xFF000000u);
    }
    for (int i = 0; i < 7; ++i) { bx[i] = ox + ax[i] * scale; by[i] = oy + ay[i] * scale; }
    tb_fill_poly(px, w, h, stride, bx, by, 7, ten ? tb_pack10(1023, 1023, 1023) : 0xFFFFFFFFu);
}

/* The Metal view is a sibling layer over SDL's window, and SDL's renderer here
 * is OpenGL — an opaque Metal layer on top hides it completely, `hidden` or
 * not. So the plane is created lazily on the first 10-bit frame and torn down
 * the moment anything else draws, rather than existing for the whole session. */

int tb_metal_plane_init(SDL_Window *win) {
    if (g.ready) return 0;
    if (!win) return -1;

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
    /* The default (YES) forbids using the drawable as a blit destination. */
    g.layer.framebufferOnly = NO;
    g.layer.opaque = YES;
    g.layer.maximumDrawableCount = TB_METAL_RING;
    g.layer.displaySyncEnabled = YES;
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

    /* Dither on presentation.
     *
     * macOS adds sub-LSB noise on the way to the panel, which is why 8-bit
     * gradients look smooth everywhere else in the OS. A CAMetalLayer writing
     * straight to a 10-bit drawable never picks that up, so quantisation the
     * rest of the system hides is plainly visible in our window — measured with
     * a synthetic ramp: an 8-bit half banded here while the same data was
     * smooth in any ordinary window.
     *
     * The content arrives quantised to 256 levels even in a 10-bit container,
     * so the noise is scaled to one 8-bit step by default.
     *
     * An 8x8 ordered matrix, not random noise. White noise of the same
     * amplitude reads as canvas texture across the whole image — its energy
     * sits at all spatial frequencies, including the low ones the eye is most
     * sensitive to. An ordered pattern puts its energy at high frequencies
     * where the eye does not resolve it, which is why GPUs dither this way.
     *
     * Amplitude is sized to the *output* quantiser, not the input step: the
     * drawable is 10-bit, so one 8-bit step is already four output levels of
     * noise. Half a step is enough to spread values across the levels between
     * two 8-bit codes. TB_DITHER scales it, in units of 8-bit steps. */
    NSString *src = @"#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct VOut { float4 pos [[position]]; float2 uv; };\n"
        "vertex VOut tb_vs(uint vid [[vertex_id]]) {\n"
        "  float2 p = float2((vid << 1) & 2, vid & 2);\n"
        "  VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y);\n"
        "  return o;\n"
        "}\n"
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
        "}\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [g.dev newLibraryWithSource:src options:nil error:&err];
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
    /* Buffer-backed textures need their rows aligned; the staging copy pads to
     * this rather than to the frame width. */
    g.dither = 0.5f / 255.0f;   /* half an 8-bit step = ~2 levels at 10-bit */
    const char *denv = getenv("TB_DITHER");
    if (denv) {
        float scale = (float)atof(denv);
        if (scale >= 0.0f && scale <= 8.0f) g.dither = scale / 255.0f;
    }
    fprintf(stderr, "[metal] dither %.2f of an 8-bit step (%.1f levels at 10-bit)\n",
            g.dither * 255.0f, g.dither * 1023.0f);

    g.row_align = [g.dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGR10A2Unorm];
    if (g.row_align == 0) g.row_align = 256;

    g.queue = [g.dev newCommandQueue];
    g.inflight = dispatch_semaphore_create(TB_METAL_RING);
    g.ring_idx = 0;
    g.ready = 1;

    g.shown = 1;

    fprintf(stderr, "[metal] 10-bit plane ready on %s (BGR10A2Unorm)\n",
            [[g.dev name] UTF8String]);
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
        for (int i = 0; i < TB_METAL_RING; ++i) {
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        }
        /* Hand the counts back before releasing. libdispatch raises SIGILL
         * ("semaphore deallocated while in use") if a semaphore is disposed
         * with a value below the one it was created with — draining it to 0
         * and then dropping the reference crashed on every teardown. */
        for (int i = 0; i < TB_METAL_RING; ++i) {
            dispatch_semaphore_signal(sem);
        }
        g.inflight = nil;
    }
    for (int i = 0; i < TB_METAL_RING; ++i) { g.ring[i] = nil; g.ring_cap[i] = 0; }
    g.queue = nil;
    g.dev = nil;
    g.layer = nil;
    if (g.view) { SDL_Metal_DestroyView(g.view); g.view = NULL; }
    g.ready = 0;
}

int tb_metal_plane_available(void) { return g.ready; }

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

static int tb_metal_render(const uint8_t *px, int stride, int w, int h,
                           MTLPixelFormat srcFmt) {
    if (!g.ready || !px || w <= 0 || h <= 0) return -1;

    @autoreleasepool {
        /* Drive the layer at the frame's own resolution and let Core Animation
         * scale it to the window. On this 5K panel fullscreen they match, so
         * scaling is free; when they don't, the compositor handles it without
         * us needing a render pipeline just to blit. */
        if (g.frame_w != w || g.frame_h != h) {
            g.frame_w = w; g.frame_h = h;
            g.layer.drawableSize = CGSizeMake(w, h);
            fprintf(stderr, "[metal] drawable %dx%d\n", w, h);
        }

        const size_t tight = (size_t)w * 4;
        const size_t bpr   = ((tight + g.row_align - 1) / g.row_align) * g.row_align;
        const int    ten   = (srcFmt == MTLPixelFormatBGR10A2Unorm);
        const size_t bytes = bpr * (size_t)h;

        /* Block only if all ring slots are still in GPU use. */
        dispatch_semaphore_wait(g.inflight, DISPATCH_TIME_FOREVER);

        int slot = g.ring_idx;
        g.ring_idx = (g.ring_idx + 1) % TB_METAL_RING;

        if (g.ring_cap[slot] < bytes) {
            g.ring[slot] = [g.dev newBufferWithLength:bytes
                                              options:MTLResourceStorageModeShared];
            g.ring_cap[slot] = g.ring[slot] ? bytes : 0;
        }
        id<MTLBuffer> buf = g.ring[slot];
        if (!buf) { dispatch_semaphore_signal(g.inflight); return -1; }

        uint8_t *dst = (uint8_t *)[buf contents];

        if ((size_t)stride == bpr) {
            memcpy(dst, px, bytes);
        } else {
            for (int y = 0; y < h; ++y) memcpy(dst + (size_t)y * bpr,
                                               px + (size_t)y * stride, tight);
        }

        tb_draw_cursor_stride_fmt((uint32_t *)dst, w, h, (int)(bpr / 4), ten);

        id<CAMetalDrawable> drawable = [g.layer nextDrawable];
        if (!drawable) { dispatch_semaphore_signal(g.inflight); return -1; }

        /* A texture view over the staging buffer — no copy, the shader samples
         * the bytes we just wrote. */
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:srcFmt
                                                               width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> srcTex = [buf newTextureWithDescriptor:td offset:0 bytesPerRow:bpr];
        if (!srcTex) { dispatch_semaphore_signal(g.inflight); return -1; }

        id<MTLCommandBuffer> cb = [g.queue commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture    = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:g.pipe];
        [enc setFragmentTexture:srcTex atIndex:0];
        [enc setFragmentBytes:&g.dither length:sizeof(g.dither) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        [cb presentDrawable:drawable];
        /* Capture the semaphore itself: reading g.inflight at completion time
         * would signal a *replacement* if the plane was torn down meanwhile. */
        dispatch_semaphore_t sem = g.inflight;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
            (void)done;
            dispatch_semaphore_signal(sem);
        }];
        [cb commit];
    }
    return 0;
}

int tb_metal_plane_render_l10r(const uint8_t *px, int stride, int w, int h) {
    return tb_metal_render(px, stride, w, h, MTLPixelFormatBGR10A2Unorm);
}

int tb_metal_plane_render_bgra8(const uint8_t *px, int stride, int w, int h) {
    return tb_metal_render(px, stride, w, h, MTLPixelFormatBGRA8Unorm);
}
