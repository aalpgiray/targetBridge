/* test_window_mode.c — when does the receiver put a window on screen?
 *
 * Build & run:  make test
 *
 * Header-only subject, so this needs nothing at all: no SDL, no window server,
 * no ffmpeg. That is the point — the rule used to be unreachable from a test
 * because it was interleaved with SDL_ShowWindow calls, so both of the mistakes
 * below shipped at different times without anything noticing. */

#include "../src/tb_window_mode.h"

#include <stdio.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do {                                              \
    g_checks++;                                                            \
    if (!(cond)) {                                                         \
        g_failures++;                                                      \
        fprintf(stderr, "FAIL %s:%d — %s\n", __FILE__, __LINE__, (msg));   \
    }                                                                      \
} while (0)

/* The regression that makes autostart-at-login unpleasant: a launch agent starts
 * the receiver at boot, and if an idle receiver shows a window then the iMac
 * carries a TargetBridge window all day whether or not anyone is casting to it.
 * Neither preference may override this — there is nothing to show. */
static void test_idle_shows_nothing(void) {
    CHECK(tb_window_mode_for(0, 0, 1) == TB_WINDOW_HIDDEN,
          "idle + prefers fullscreen must still be hidden");
    CHECK(tb_window_mode_for(0, 0, 0) == TB_WINDOW_HIDDEN,
          "idle + prefers windowed must still be hidden");
}

/* The other direction: once something is actually casting, the default build
 * must go fullscreen on its own. `fullscreen` defaults to 1 in main.c and only
 * --windowed clears it, so this is the path the iMac takes every time. */
static void test_casting_goes_fullscreen_by_default(void) {
    CHECK(tb_window_mode_for(1, 0, 1) == TB_WINDOW_FULLSCREEN,
          "a live session with the default preference must fill the screen");
}

/* --windowed is a debugging affordance and has to keep working, otherwise the
 * only way to see the receiver's status panel is to occupy the whole display. */
static void test_windowed_preference_is_honoured(void) {
    CHECK(tb_window_mode_for(1, 0, 0) == TB_WINDOW_WINDOWED,
          "--windowed must survive a live session");
}

/* is_connecting counts as live so the window is up before the first frame
 * rather than a frame behind it — a first frame arriving into a hidden window
 * would be presented to nothing. */
static void test_connecting_already_shows(void) {
    CHECK(tb_window_mode_for(0, 1, 1) == TB_WINDOW_FULLSCREEN,
          "connecting must show, so frame one is not presented into a hidden window");
    CHECK(tb_window_mode_for(0, 1, 0) == TB_WINDOW_WINDOWED,
          "connecting windowed must show too");
}

/* Whatever else changes, exactly one thing decides visibility: whether a session
 * is live. Sweeping the cube states that as an invariant rather than as four
 * separate cases someone could later "fix" one of. */
static void test_visibility_depends_only_on_liveness(void) {
    for (int connected = 0; connected <= 1; connected++) {
        for (int connecting = 0; connecting <= 1; connecting++) {
            for (int prefer_fs = 0; prefer_fs <= 1; prefer_fs++) {
                const enum tb_window_mode m =
                    tb_window_mode_for(connected, connecting, prefer_fs);
                const int live = connected || connecting;
                CHECK((m == TB_WINDOW_HIDDEN) == !live,
                      "hidden must mean not live, and vice versa");
                if (live) {
                    CHECK((m == TB_WINDOW_FULLSCREEN) == (prefer_fs != 0),
                          "when live, only the preference chooses the size");
                }
            }
        }
    }
}

int main(void) {
    test_idle_shows_nothing();
    test_casting_goes_fullscreen_by_default();
    test_windowed_preference_is_honoured();
    test_connecting_already_shows();
    test_visibility_depends_only_on_liveness();

    if (g_failures) {
        fprintf(stderr, "\nwindow mode tests: %d of %d checks FAILED\n",
                g_failures, g_checks);
        return 1;
    }
    printf("window mode tests: %d checks passed\n", g_checks);
    return 0;
}
