/* tb_menubar.h — the receiver's menu bar presence.
 *
 * WHY
 *
 * This Mac is a monitor. Between sessions it should look like a monitor that is
 * switched off — no window, no Dock icon, no Cmd-Tab entry — and the only way to
 * still be reachable in that state is the menu bar. Without it, an app with
 * LSUIElement set and its window hidden is running with no way to see or quit
 * it, which is worse than the window it replaced.
 *
 * It also carries the one fact somebody standing at the iMac actually wants:
 * whether anything is casting, and from where. That used to require reading a
 * fullscreen splash.
 *
 * WHAT IT IS NOT
 *
 * Not a control surface for the link. Everything worth changing — preset, depth,
 * audio — lives on the sending Mac, where the person deciding is sitting. Adding
 * the same switches here would mean two places to disagree about one session.
 */

#ifndef TB_MENUBAR_H
#define TB_MENUBAR_H

#ifdef __cplusplus
extern "C" {
#endif

/* Install the status item. Call once, after SDL has finished initialising —
 * SDL_Init creates the NSApplication this attaches to, and doing it earlier
 * gets an item that never draws.
 *
 * Safe to call when there is no GUI session; it does nothing and says so. */
void tb_menubar_start(void);

/* Reflect the current session in the menu bar. Cheap and idempotent: it only
 * touches AppKit when the text actually changes, because this is called from
 * the render loop and a status item redraw is not free.
 *
 * `casting` drives the icon, `detail` the first menu line — a sender name, or a
 * reason there is no session. Either may be NULL. */
void tb_menubar_set_state(int casting, const char *detail);

/* Whether the user chose Quit from the menu. The run loop polls this rather than
 * exiting from the menu handler, so teardown happens in one place instead of on
 * whichever thread AppKit used. */
int tb_menubar_quit_requested(void);

#ifdef __cplusplus
}
#endif

#endif
