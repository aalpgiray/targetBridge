/* tb_reconnect_hold.h — whether to keep the last frame across a disconnect.
 *
 * Pure policy, no SDL and no Metal, so the wake/reconnect decision can be
 * tested without a panel. The window code asks; this file only answers.
 *
 * An unexpected end (stale session, dropped link, the sender dialing again
 * after the iMac woke, a teardown that is not the person pressing stop)
 * should keep the picture up. explicit_stop is only the stop button and
 * targetbridge://disconnect (reason "user_stop", and the legacy
 * "sender_stop"). A display-sleep teardown is not that.
 *
 * While the sender's display is asleep the 10s grace does not run. The iMac
 * can sit awake longer than that and then actually sleep; time the receiver
 * itself spends asleep is not counted toward the cap below.
 *
 * TB_RECONNECT_HOLD_MS is the clock. Override it without a rebuild:
 *   TB_RECONNECT_HOLD_MS=5000 ./tbreceiver
 *   TB_RECONNECT_HOLD_MS=0    ./tbreceiver   (hold off; today's waiting screen)
 * The value is milliseconds. A non-numeric value is ignored by the caller.
 */

#ifndef TB_RECONNECT_HOLD_H
#define TB_RECONNECT_HOLD_H

#include <stdint.h>

#define TB_RECONNECT_HOLD_MS 10000ull

/* How long the receiver will keep a picture up while the sender has said its
 * display is asleep, counting only time this machine was awake. Past this the
 * ordinary grace runs again, so a sender that never returns cannot pin the
 * old frame. 3 minutes covers the MacBook locking, the iMac following it
 * down, and the dial back on wake (the 2026-10-29 gap was under a minute). */
#define TB_SENDER_ASLEEP_HOLD_MS 180000ull

struct tb_reconnect_hold {
    int active;
    int sender_returned;     /* a TCP accept landed while the hold was up */
    int deadline_suspended;  /* sender display is asleep; grace is not running */
    uint64_t until_ms;       /* drop the picture if still disconnected then */
    uint64_t connected_ms;   /* when that accept happened; 0 if none */
};

static inline void tb_reconnect_hold_clear(struct tb_reconnect_hold *h) {
    if (!h) return;
    h->active = 0;
    h->sender_returned = 0;
    h->deadline_suspended = 0;
    h->until_ms = 0;
    h->connected_ms = 0;
}

/* 1 while the sender's display is asleep and this hold should ignore its
 * deadline. The caller lifts it when the display wakes, a frame arrives, or
 * TB_SENDER_ASLEEP_HOLD_MS of receiver-awake time has passed. */
static inline void tb_reconnect_hold_set_deadline_suspended(struct tb_reconnect_hold *h,
                                                           int suspended) {
    if (!h) return;
    h->deadline_suspended = suspended ? 1 : 0;
}

static inline int tb_sender_asleep_hold_expired(uint64_t accumulated_awake_ms) {
    return accumulated_awake_ms >= TB_SENDER_ASLEEP_HOLD_MS;
}

static inline int tb_reconnect_hold_active(const struct tb_reconnect_hold *h) {
    return h && h->active;
}

/* explicit_stop: the person pressed stop or opened targetbridge://disconnect.
 * had_picture: a frame is on screen, or a hold is already showing one.
 * grace_ms == 0 turns the feature off.
 *
 * A hold that has already reached its deadline is not renewed, unless the
 * deadline is suspended because the sender's display is asleep. A later
 * disconnect must not push the waiting screen further out. */
static inline int tb_reconnect_should_hold(int explicit_stop,
                                           int had_picture,
                                           const struct tb_reconnect_hold *h,
                                           uint64_t now_ms,
                                           uint64_t grace_ms) {
    if (explicit_stop || !had_picture || grace_ms == 0) return 0;
    if (h && h->active && h->deadline_suspended) return 1;
    if (h && h->active && now_ms >= h->until_ms) return 0;
    return 1;
}

/* Start the clock. A second call while the hold is already active keeps the
 * original deadline: the sender's connect/disconnect/connect burst (measured
 * as two accepts a few hundred milliseconds apart) must not extend it. */
static inline void tb_reconnect_hold_begin(struct tb_reconnect_hold *h,
                                           uint64_t now_ms,
                                           uint64_t grace_ms) {
    if (!h || h->active) return;
    h->active = 1;
    h->sender_returned = 0;
    h->connected_ms = 0;
    h->until_ms = now_ms + grace_ms;
}

static inline void tb_reconnect_hold_note_connect(struct tb_reconnect_hold *h,
                                                 uint64_t now_ms) {
    if (!h || !h->active) return;
    h->sender_returned = 1;
    h->connected_ms = now_ms;
}

/* The socket dropped again before a frame. The original deadline still
 * applies; this dial does not count as the sender having come back. */
static inline void tb_reconnect_hold_note_disconnect(struct tb_reconnect_hold *h) {
    if (!h || !h->active) return;
    h->sender_returned = 0;
    h->connected_ms = 0;
}

static inline void tb_reconnect_hold_note_frame(struct tb_reconnect_hold *h) {
    tb_reconnect_hold_clear(h);
}

/* Time that passed while this hold was already up, but the sender was not
 * gone: the main thread was blocked, or the machine was asleep
 * (CLOCK_MONOTONIC jumps across system sleep; CLOCK_UPTIME_RAW does not).
 * Add it to both clocks. Inactive, NULL, and a zero span do nothing.
 * The caller must not pass ordinary time between loop iterations. */
static inline void tb_reconnect_hold_credit_stall(struct tb_reconnect_hold *h,
                                                 uint64_t stalled_ms) {
    if (!h || !h->active || stalled_ms == 0) return;
    h->until_ms += stalled_ms;
    if (h->sender_returned) h->connected_ms += stalled_ms;
}

/* 1 when the waiting screen should replace the held frame.
 *
 * Still disconnected: the original deadline.
 * Reconnected and the socket is still up: one grace period after that
 * accept, so a connection that never produces a frame cannot pin the old
 * picture forever. A sender that returns inside the original window still
 * has a full grace for its first frame — the wake trace's first frame
 * arrived about 2–3s after the new TCP session, which is the gap this
 * exists to cover. */
static inline int tb_reconnect_hold_should_drop(const struct tb_reconnect_hold *h,
                                               uint64_t now_ms,
                                               int client_connected,
                                               uint64_t grace_ms) {
    if (!h || !h->active) return 0;
    if (h->deadline_suspended) return 0;
    if (client_connected && h->sender_returned) {
        return now_ms >= h->connected_ms + grace_ms;
    }
    return now_ms >= h->until_ms;
}

#endif
