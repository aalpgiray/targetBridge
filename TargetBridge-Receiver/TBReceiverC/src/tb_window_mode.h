/* tb_window_mode.h — should there be a window on screen right now, and how big?
 *
 * WHY THIS IS ITS OWN FILE
 *
 * The rule is three booleans wide and easy to state, but it lived inside a
 * function that also talks to SDL and CoreGraphics — so it could not be checked
 * without a window server, which means it was never checked at all. The two
 * mistakes it is possible to make here are both invisible in a unit test's
 * absence and obvious in its presence:
 *
 *   - showing a window when nothing is casting, which parks a TargetBridge
 *     window on the iMac all day once it autostarts at login
 *   - going fullscreen while merely *discovering* a sender, which black-flashes
 *     the whole screen during a transient control-only connection
 *
 * Header-only and inline so display.c and the tests share one definition
 * without either a new translation unit or a link against SDL.
 */

#ifndef TB_WINDOW_MODE_H
#define TB_WINDOW_MODE_H

enum tb_window_mode {
    /* This Mac is a monitor. Between sessions it should look like one that is
     * switched off, not like an app waiting for you. */
    TB_WINDOW_HIDDEN = 0,
    TB_WINDOW_WINDOWED = 1,
    TB_WINDOW_FULLSCREEN = 2
};

/* `is_connecting` counts as live so the window is already up when the first
 * frame lands, rather than appearing a frame late. */
static inline enum tb_window_mode tb_window_mode_for(int is_connected,
                                                     int is_connecting,
                                                     int preferred_fullscreen) {
    if (!is_connected && !is_connecting) return TB_WINDOW_HIDDEN;
    return preferred_fullscreen ? TB_WINDOW_FULLSCREEN : TB_WINDOW_WINDOWED;
}

#endif
