/* tb_wake_watch.h — macOS system-wake notification, exposed as a flag.
 *
 * WHY
 *
 * The audio watchdog in main.c can tell when the SDL callback has stopped
 * firing, but not when it kept firing into a route CoreAudio already tore
 * down. Measured incident (2026-09-2x, ~5 days of sleep/wake on the iMac):
 * the sender was verifiably streaming audio at a steady rate the whole time
 * and the receiver process was alive, yet the unified log showed zero
 * CoreAudio/HALC activity from TBReceiver in the last hour before a restart
 * fixed it. Whether the callback had actually stopped or was still running
 * into dead air could not be told apart after the fact, so the fix has to
 * cover both: a heartbeat watchdog for the first case, and an unconditional
 * reopen on wake for the second, because NSWorkspaceDidWakeNotification is
 * the one signal that names the exact moment a stale route can appear.
 *
 * This only ever sets a flag. It does not touch SDL, the audio device, or
 * any app state -- main.c's loop polls tb_wake_watch_take_wake() on its own
 * thread and does the actual close/reopen there, which is what keeps a
 * notification-delivery thread (see tb_wake_watch_start() below for which
 * one that is on this build) from racing the audio code. */

#ifndef TB_WAKE_WATCH_H
#define TB_WAKE_WATCH_H

#ifdef __cplusplus
extern "C" {
#endif

/* Install the NSWorkspaceDidWakeNotification observer. Call once at
 * startup; idempotent. */
void tb_wake_watch_start(void);

/* Returns 1 and clears the flag if a wake notification has landed since the
 * last call, 0 otherwise. Cheap enough (one atomic exchange) to poll every
 * main-loop iteration rather than on the ~1s watchdog cadence, so recovery
 * is not held up waiting for the next tick. */
int tb_wake_watch_take_wake(void);

#ifdef __cplusplus
}
#endif

#endif
