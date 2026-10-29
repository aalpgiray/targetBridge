/* tb_reconnect_hold.h — whether to keep the last frame across a disconnect.
 *
 * Pure policy, no SDL and no Metal, so the wake/reconnect decision can be
 * tested without a panel. The window code asks; this file only answers.
 *
 * An unexpected end (stale session, dropped link, the sender dialing again
 * after the iMac woke) should keep the picture up. The sender's own stop
 * (TB_PKT_TEARDOWN) should not: that is the person asking for the waiting
 * screen, and it should come back at once.
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

struct tb_reconnect_hold {
    int active;
    int sender_returned;     /* a TCP accept landed while the hold was up */
    uint64_t until_ms;       /* drop the picture if still disconnected then */
    uint64_t connected_ms;   /* when that accept happened; 0 if none */
};

static inline void tb_reconnect_hold_clear(struct tb_reconnect_hold *h) {
    if (!h) return;
    h->active = 0;
    h->sender_returned = 0;
    h->until_ms = 0;
    h->connected_ms = 0;
}

static inline int tb_reconnect_hold_active(const struct tb_reconnect_hold *h) {
    return h && h->active;
}

/* explicit_stop: the sender sent TEARDOWN (the user pressed stop).
 * had_picture: a frame is on screen, or a hold is already showing one.
 * grace_ms == 0 turns the feature off.
 *
 * A hold that has already reached its deadline is not renewed. A later
 * disconnect must not push the waiting screen further out. */
static inline int tb_reconnect_should_hold(int explicit_stop,
                                           int had_picture,
                                           const struct tb_reconnect_hold *h,
                                           uint64_t now_ms,
                                           uint64_t grace_ms) {
    if (explicit_stop || !had_picture || grace_ms == 0) return 0;
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

/* The main thread was blocked for stalled_ms while this hold was already
 * up (AudioQueueStart, a wedged write). That time is not the sender being
 * gone. Add it to both clocks. Inactive, NULL, and a zero stall do nothing.
 * The caller decides which span counts: time before the hold began, and the
 * gap between loop iterations (a real sleep), must not be passed in. */
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
    if (client_connected && h->sender_returned) {
        return now_ms >= h->connected_ms + grace_ms;
    }
    return now_ms >= h->until_ms;
}

#endif
