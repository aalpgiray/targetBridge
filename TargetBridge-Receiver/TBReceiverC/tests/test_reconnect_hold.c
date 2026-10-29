/* test_reconnect_hold.c — the last-frame hold, without a window.
 *
 * Build & run:  make test
 *
 * The decision of whether a disconnect keeps the picture is pure arithmetic
 * on a struct. These cases are the ones the wake trace actually hits:
 * stale close, a sender that dials twice, a stop button, and a socket that
 * comes back but never sends a frame.
 */

#include "../src/tb_reconnect_hold.h"

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

static void test_explicit_stop_never_holds(void) {
    struct tb_reconnect_hold h;
    tb_reconnect_hold_clear(&h);
    CHECK(!tb_reconnect_should_hold(1, 1, &h, 1000, TB_RECONNECT_HOLD_MS),
          "sender teardown with a picture still goes to the waiting screen");
    CHECK(!tb_reconnect_should_hold(1, 0, &h, 1000, TB_RECONNECT_HOLD_MS),
          "sender teardown with no picture does not hold");
}

static void test_no_picture_and_disabled(void) {
    struct tb_reconnect_hold h;
    tb_reconnect_hold_clear(&h);
    CHECK(!tb_reconnect_should_hold(0, 0, &h, 1000, TB_RECONNECT_HOLD_MS),
          "nothing was on screen, so there is nothing to keep");
    CHECK(!tb_reconnect_should_hold(0, 1, &h, 1000, 0),
          "TB_RECONNECT_HOLD_MS=0 disables the hold");
}

static void test_unexpected_with_picture_holds(void) {
    struct tb_reconnect_hold h;
    tb_reconnect_hold_clear(&h);
    const uint64_t now = 50000;
    CHECK(tb_reconnect_should_hold(0, 1, &h, now, TB_RECONNECT_HOLD_MS),
          "stale session / link drop with a frame holds");
    tb_reconnect_hold_begin(&h, now, TB_RECONNECT_HOLD_MS);
    CHECK(tb_reconnect_hold_active(&h), "hold is active after begin");
    CHECK(h.until_ms == now + TB_RECONNECT_HOLD_MS, "deadline is now + grace");
    CHECK(!h.sender_returned, "begin does not pretend the sender is back");

    tb_reconnect_hold_begin(&h, now + 250, TB_RECONNECT_HOLD_MS);
    CHECK(h.until_ms == now + TB_RECONNECT_HOLD_MS,
          "a second begin does not extend the deadline");
}

static void test_disconnected_deadline(void) {
    struct tb_reconnect_hold h;
    tb_reconnect_hold_clear(&h);
    tb_reconnect_hold_begin(&h, 0, 10000);
    CHECK(!tb_reconnect_hold_should_drop(&h, 9999, 0, 10000),
          "still inside the grace with no sender");
    CHECK(tb_reconnect_hold_should_drop(&h, 10000, 0, 10000),
          "grace elapsed with no sender: waiting screen");
    CHECK(h.active, "should_drop does not clear the hold itself");
}

static void test_reconnect_inside_grace_waits_for_a_frame(void) {
    struct tb_reconnect_hold h;
    tb_reconnect_hold_clear(&h);
    /* Wake trace, scaled: stale close at t=0, accept ~50ms later, first
     * frame a couple of seconds after that. The waiting screen must not
     * come back in between. */
    tb_reconnect_hold_begin(&h, 0, 10000);
    tb_reconnect_hold_note_connect(&h, 50);
    CHECK(h.sender_returned, "accept during the hold is the sender returning");
    CHECK(!tb_reconnect_hold_should_drop(&h, 3000, 1, 10000),
          "connected, frame not here yet, still inside the post-connect grace");
    CHECK(!tb_reconnect_hold_should_drop(&h, 10000, 1, 10000),
          "original deadline alone does not drop a live reconnect");
    CHECK(tb_reconnect_hold_should_drop(&h, 50 + 10000, 1, 10000),
          "a socket that never sends a frame does not pin the picture forever");

    tb_reconnect_hold_note_frame(&h);
    CHECK(!tb_reconnect_hold_active(&h), "first live frame ends the hold");
    CHECK(!tb_reconnect_hold_should_drop(&h, 999999, 1, 10000),
          "a cleared hold does not drop");
}

static void test_double_dial_does_not_expire_early_or_renew(void) {
    struct tb_reconnect_hold h;
    tb_reconnect_hold_clear(&h);
    tb_reconnect_hold_begin(&h, 0, 10000);

    /* First of the sender's two back-to-back dials. */
    tb_reconnect_hold_note_connect(&h, 50);
    tb_reconnect_hold_note_disconnect(&h);
    CHECK(!h.sender_returned, "the probe disconnect is not 'sender returned'");
    CHECK(h.until_ms == 10000, "probe disconnect keeps the original deadline");
    CHECK(tb_reconnect_should_hold(0, 1, &h, 200, 10000),
          "the second dial's disconnect still holds");
    CHECK(!tb_reconnect_hold_should_drop(&h, 200, 0, 10000),
          "gap between the two dials stays on the last frame");

    tb_reconnect_hold_begin(&h, 200, 10000);   /* no-op: already active */
    tb_reconnect_hold_note_connect(&h, 220);
    CHECK(h.connected_ms == 220, "the real dial starts its own frame clock");
    CHECK(h.until_ms == 10000, "the real dial does not move the disconnect deadline");
    CHECK(!tb_reconnect_hold_should_drop(&h, 2500, 1, 10000),
          "frames a couple of seconds later still suppress the waiting screen");
}

static void test_expired_hold_is_not_renewed(void) {
    struct tb_reconnect_hold h;
    tb_reconnect_hold_clear(&h);
    tb_reconnect_hold_begin(&h, 0, 10000);
    CHECK(!tb_reconnect_should_hold(0, 1, &h, 10000, 10000),
          "past the deadline, another unexpected close does not start a new hold");
    CHECK(tb_reconnect_hold_should_drop(&h, 10000, 0, 10000),
          "that close is also time to show the waiting screen");
}

static void test_connect_and_frame_outside_a_hold(void) {
    struct tb_reconnect_hold h;
    tb_reconnect_hold_clear(&h);
    tb_reconnect_hold_note_connect(&h, 10);
    CHECK(!h.sender_returned, "an accept with no hold is just a normal connect");
    tb_reconnect_hold_note_frame(&h);
    CHECK(!tb_reconnect_hold_active(&h), "a frame with no hold stays idle");
    CHECK(!tb_reconnect_hold_should_drop(NULL, 0, 0, 10000), "null hold does not drop");
    CHECK(tb_reconnect_should_hold(0, 1, NULL, 0, 10000),
          "null state with a picture still wants a hold");
}

static void test_stall_credit_keeps_the_picture(void) {
    struct tb_reconnect_hold idle;
    tb_reconnect_hold_clear(&idle);
    tb_reconnect_hold_credit_stall(&idle, 15000);
    CHECK(!idle.active, "credit on an idle hold does nothing");
    CHECK(idle.until_ms == 0 && idle.connected_ms == 0,
          "idle credit does not invent a deadline");
    tb_reconnect_hold_credit_stall(NULL, 15000);

    struct tb_reconnect_hold h;
    tb_reconnect_hold_clear(&h);
    tb_reconnect_hold_begin(&h, 0, 10000);
    tb_reconnect_hold_credit_stall(&h, 0);
    CHECK(h.until_ms == 10000, "a zero stall does not move the deadline");

    /* Second wake, 2026-10-29: hold began, the sender accepted, then
     * AudioQueueStart blocked the main thread for ~15s. The 10s grace must
     * still be intact when that call returns. */
    tb_reconnect_hold_note_connect(&h, 50);
    tb_reconnect_hold_credit_stall(&h, 15000);
    CHECK(h.until_ms == 25000, "blocked time is added to the disconnect deadline");
    CHECK(h.connected_ms == 15050, "blocked time is added to the post-connect clock");
    CHECK(!tb_reconnect_hold_should_drop(&h, 16000, 1, 10000),
          "a 15s stall does not expire a hold whose grace is 10s");
    CHECK(tb_reconnect_should_hold(0, 1, &h, 16000, 10000),
          "another close during that stall still keeps the picture");

    struct tb_reconnect_hold raw;
    tb_reconnect_hold_clear(&raw);
    tb_reconnect_hold_begin(&raw, 0, 10000);
    tb_reconnect_hold_note_connect(&raw, 50);
    CHECK(!tb_reconnect_should_hold(0, 1, &raw, 16000, 10000),
          "the same close without credit gives up the picture");
    CHECK(tb_reconnect_hold_should_drop(&raw, 16000, 1, 10000),
          "without credit the post-connect grace has already elapsed");
}

int main(void) {
    test_explicit_stop_never_holds();
    test_no_picture_and_disabled();
    test_unexpected_with_picture_holds();
    test_disconnected_deadline();
    test_reconnect_inside_grace_waits_for_a_frame();
    test_double_dial_does_not_expire_early_or_renew();
    test_expired_hold_is_not_renewed();
    test_connect_and_frame_outside_a_hold();
    test_stall_credit_keeps_the_picture();

    if (g_failures) {
        fprintf(stderr, "%d/%d checks failed\n", g_failures, g_checks);
        return 1;
    }
    printf("reconnect hold: %d checks passed\n", g_checks);
    return 0;
}
