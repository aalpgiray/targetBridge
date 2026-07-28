/* tb_metal_plane.h — 10-bit (ARGB2101010) video plane, bypassing SDL_Renderer.
 *
 * SDL2 has no 10-bit texture format on any macOS backend; requesting one lands
 * on a scalar CPU conversion that also truncates to 8 bits. See tb_metal_plane.m.
 */

#ifndef TB_METAL_PLANE_H
#define TB_METAL_PLANE_H

#include <stdint.h>

struct SDL_Window;

/* Create the Metal layer alongside SDL's window. Returns 0 on success; on
 * failure the caller should stay on the SDL render path. Starts hidden. */
int  tb_metal_plane_init(struct SDL_Window *win);
void tb_metal_plane_shutdown(void);

/* Non-zero once init() has succeeded. */
int  tb_metal_plane_available(void);

/* Show/hide the video plane. Hidden while the SDL status/connecting UI owns
 * the window, shown once 10-bit frames arrive. */
void tb_metal_plane_set_hidden(int hidden);

/* Cursor overlay state, in source-frame coordinates. SDL used to draw the
 * cursor over the video texture; on the Metal path there is no SDL pass, so it
 * is composited into the frame before the blit instead. */
void tb_metal_plane_set_cursor(int x, int y, int source_w, int source_h,
                               int visible, int type);

/* Blit one packed ARGB2101010 ('l10r') frame and present it. Returns 0 on
 * success. */
int  tb_metal_plane_render_l10r(const uint8_t *px, int stride, int w, int h);

#endif
