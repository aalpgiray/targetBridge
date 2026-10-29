#ifndef TB_GESTURE_BRIDGE_H
#define TB_GESTURE_BRIDGE_H

typedef void (*tb_gesture_space_switch_callback)(int direction, void *context);

void tb_gesture_bridge_install(tb_gesture_space_switch_callback callback, void *context);
void tb_gesture_bridge_set_active(int active);

/* Returns 1 if the given SDL_Window's Cocoa window is on the active macOS
 * Space (or can't be determined), 0 if it is on a different Space. */
int tb_window_on_active_space(void *sdl_window);

/* 1 if the receiver content window's frame covers its screen, 0 if it is
 * visibly smaller (the 980x620 waiting window), -1 if no window can be
 * found. SDL_GetWindowFlags can still say fullscreen after sleep while this
 * is 0, which is the case a flag check cannot see. */
int tb_window_covers_screen(void);

#endif
