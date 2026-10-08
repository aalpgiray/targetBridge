/* main.c — TBReceiver pure-C entry point.
 *
 * Single-threaded event loop:
 *   - SDL_PollEvent (non-blocking)  → quit detection
 *   - non-blocking socket read     → packet parser → decoder → renderer
 *   - 1ms sleep when idle           → CPU yield
 *
 * No ObjC. No Cocoa NSApplication. No autoreleasepool.
 * Crashes from objc_release/__CFAutoreleasePoolPop cannot happen here:
 * no Objective-C runtime objects are managed by us. SDL2 may use Cocoa
 * windowing internally on macOS, but with this minimal setup the OCLP-
 * triggered bug pattern (corrupt object in main-thread ARP) is dramatically
 * less likely than with SwiftUI / AppKit programmatic UIs.
 */

#include "net.h"
#include "decoder.h"
#include "display.h"
#include "tb_metal_plane.h"
#include "proto.h"
#include "tb_gesture_bridge.h"
#include "tb_display_tweaks.h"
#include "tb_mic_capture.h"
#include "tb_i18n.h"
#include "tb_logship.h"
#include "tb_health.h"
#include "tb_wake_watch.h"

#include <SDL.h>
#include <ApplicationServices/ApplicationServices.h>
#include <dns_sd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreAudio/CoreAudio.h>
#include <IOKit/pwr_mgt/IOPMLib.h>

/* kAudioObjectPropertyElementMain is the macOS 12+ SDK spelling; older SDKs
 * only define kAudioObjectPropertyElementMaster (both are numerically 0). */
#ifndef kAudioObjectPropertyElementMain
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <time.h>
#include <poll.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

/* Format constants live in proto.h, next to the packet definitions they
 * describe. Only the buffer policy is local. */
#define AUDIO_BUF_CAP          (1000 * AUDIO_BYTES_PER_MS)   /* 1 second capacity */

/* Playout backlog ceiling. Cushions network and scheduling jitter without
 * letting delay accumulate; the excess is dropped oldest-first, which is the
 * standard jitter-buffer behaviour and what keeps latency from ratcheting up
 * as the two ends' clocks drift apart. */
#define AUDIO_BACKLOG_MAX_MS   150

/* Reap a connected sender that has gone completely silent. The sender
 * heartbeats every 2s and streams frames continuously, so 10s of silence
 * (5 missed heartbeats) means it died without a FIN. */
#define TB_SENDER_IDLE_TIMEOUT_MS 10000

/* Grace period after a session is accepted (cold accept or replacing a
 * dead one) during which it will not itself be torn down just because
 * another dial shows up. Measured live: the sender's own reconnect logic
 * can fire two overlapping dials from one retry burst, and the second one
 * arrived only 13ms after the first session's first frame -- a fraction of
 * a network round-trip, nothing like a real second failure.
 *
 * Freshness is measured off last_recv_ms, not connecting_since, on purpose:
 * connecting_since is stamped with SDL_GetTicks() at accept (a different
 * clock than the now_ms()/CLOCK_MONOTONIC used everywhere else in the loop,
 * including here), and once have_video_frame goes true the render-status
 * branch below re-stamps connecting_since to "now" on *every* tick, not
 * just when a new frame lands -- so a session that has ever decoded one
 * frame reads as "just started" forever, dead or alive, until the passive
 * TB_SENDER_IDLE_TIMEOUT_MS reaper finally closes it. Reusing it here as
 * the sole signal would make any post-first-frame session immune to fast
 * replacement, reintroducing a bounded (10s) version of tonight's original
 * stale-socket lockout. last_recv_ms has neither problem: it is set with
 * now_ms() at accept and after that only advances when the socket actually
 * produced bytes (see drain_socket()/pump_network() below), which is
 * exactly "provably not delivering frames" stated as a duration instead of
 * a bool.
 *
 * 2s is two orders of magnitude above the measured 13ms race window
 * (ample margin for scheduler/GC-style jitter) yet a fifth of
 * TB_SENDER_IDLE_TIMEOUT_MS: a session that goes genuinely silent right
 * after being protected is still replaceable on the very next dial once
 * 2s of true silence has elapsed -- faster than waiting for the passive
 * 10s idle reaper, not slower, so this cannot re-lock out a dead sender. */
#define TB_NEW_SESSION_GRACE_MS 2000

/* While idle (no client attached), re-publish Bonjour on this tick so a
 * sender that lost the receiver mid-session -- for any reason, sleep, cable
 * pull, crash, the receiver does not need to know which -- sees it reappear
 * in a browse without a human restarting either app. bonjour_update() is the
 * same idempotent deinit+re-register the interface-change path already calls
 * (see ~line 2936), so this reuses that call rather than adding a new one.
 * 5s matches this file's other passive-tick idiom (tb_health.m's
 * TB_HEALTH_INTERVAL_MS, confirmed live in receiver-local.log as "[health]
 * thermal nominal..." every ~5s) -- frequent enough that a sender's own
 * Bonjour browse (which re-resolves on every service announcement) notices
 * within one health tick, not so frequent it spams mDNSResponder while
 * nothing has changed. */
#define TB_IDLE_ANNOUNCE_INTERVAL_MS 5000

/* Audio output self-healing.
 *
 * The SDL audio device is opened once at startup and nothing ever checked it
 * again -- measured incident, 2026-09-2x: the receiver ran across ~5 days of
 * this iMac's sleep/wake cycles, the sender kept streaming audio the whole
 * time (driver->app loopback measured ~385 KB/s, matching 48kHz stereo
 * float), the iMac's own output (iMac Speakers, volume 82, not muted) was
 * fine, and the unified log showed zero CoreAudio/HALC activity from
 * TBReceiver in the last hour. Restarting the process fixed it instantly,
 * which only proves the device object SDL held was no longer a live route --
 * not which of the two ways that happens (callback stopped firing, or kept
 * firing into dead air) actually occurred. So two independent detectors:
 *
 *   1. A heartbeat: audio_callback() bumps a counter every time CoreAudio
 *      calls it. If the counter has not advanced across two consecutive ~1s
 *      checks, or SDL itself reports the device is not SDL_AUDIO_PLAYING,
 *      the callback has stopped -- close and reopen.
 *   2. NSWorkspaceDidWakeNotification (tb_wake_watch.h): covers the case the
 *      heartbeat cannot see, where the callback keeps firing on schedule but
 *      into a route CoreAudio already tore down under it. Reopen unconditionally
 *      on wake; the cost of one needless reopen is a few ms of silence, and
 *      unlike the heartbeat this fires the instant the OS says the machine
 *      is back, not up to a watchdog period later.
 *
 * Threshold: 2 ticks means at least one full check interval (~1s, matching
 * this file's TB_IDLE_ANNOUNCE_INTERVAL_MS-style 1Hz idiom) with zero
 * progress, i.e. up to ~2s of silence before recovery fires. A single ~21ms
 * callback period stalling once is normal scheduling jitter, not death; the
 * SDL callback buffer is spec.samples=1024 frames at 48kHz (~21ms), so a
 * device that is still alive calls back roughly 47 times a second -- a full
 * second of zero calls is unambiguous. Longer than that just delays
 * recovery for no benefit, since the callback itself is essentially free. */
#define TB_AUDIO_WATCHDOG_INTERVAL_MS 1000
#define TB_AUDIO_WATCHDOG_STALL_TICKS 2
/* Reopen retries (startup failure, or a reopen that itself fails) back off to
 * this cadence rather than trying every loop iteration or staying silent
 * forever -- matches the health/idle-announce family's ~5s idiom. */
#define TB_AUDIO_REOPEN_RETRY_MS 5000

#define TB_CTRL_QUEUE_MAX 512

/* Video packets the reader may hand over before the main thread has caught up.
 * Three frames at EIGHT bands, matching the sender's in-flight budget at its
 * highest usable slice count, so the two ends agree on how far ahead the wire
 * may get.
 *
 * It was 12 (three frames at four bands), which is why N=8 overflowed even with
 * everything else healthy: twelve slots is one and a half frames at eight bands.
 * Each slot holds a reader's parser buffer, and a band shrinks as the count
 * rises, so doubling the slots does not double the memory — it is tens of MB
 * either way, not the 4.4 GB an earlier oversized ring cost. */
#define TB_VIDEO_QUEUE 24
#define TB_VIDEO_POOL  (TB_VIDEO_QUEUE + 4)

/* How far behind capture a frame is presented. It must exceed the usual
 * encode+wire delay or frames arrive after their slot; covering the rare 45 ms
 * tail instead would cost 50 ms of latency to fix a 4% case, and a frame that
 * misses simply shows one refresh late — which is what happens today anyway. */
#define TB_PACE_LEAD_NS      (25ull * 1000000ull)
/* A frame never waits longer than this, whatever the clock estimate says. A
 * wrong offset then costs one late frame instead of the session. */
#define TB_PACE_MAX_HOLD_MS  50

/* A non-frame packet copied off a reader thread for the main thread to run
 * through on_packet() unchanged. */
struct tb_ctrl_msg {
    uint8_t  type;
    uint8_t *payload;
    size_t   len;
    /* When this packet was pulled off the socket, so a handler can report how
     * long it then waited to be processed. That wait is not hypothetical: the
     * main loop used to park on a vblank while arming a frame, and everything
     * queued here waited with it. */
    double   recv_ms;
};

struct app;

struct tb_link_reader {
    pthread_t         thread;
    int               fd;
    int               active;
    volatile int      stop;
    volatile int      ended;   /* peer closed, or a fatal parse/read error */
    struct tb_parser  parser;
    struct app       *app;
    const uint8_t    *pending_payload;   /* set by the callback, published after commit */
    size_t            pending_len;
    uint8_t           pending_type;
};

struct app {
    struct tb_display *disp;
    struct tb_decoder *dec;
    struct tb_parser   parser;

    int      server_fd;
    int      client_fd;

    /* Threaded receive. read() of a 5K raw frame costs ~23 ms and the GPU
     * upload ~13 ms; run on one thread they serialize to ~36 ms/frame. Each
     * cable gets a reader thread so the two reads run in parallel AND overlap
     * the main thread's render. Packet handlers stay on the main thread (they
     * touch SDL and app state), so readers only parse and hand work across. */
    pthread_mutex_t net_lock;
    int              threaded_rx;

    /* Video packets waiting for the main thread.
     *
     * This was ONE slot, which was right when a frame was one packet. Slicing
     * made a frame four, and because a band is an increment that must not be
     * overwritten, the reader waited up to 100 ms for the slot to clear. That
     * wait is inside the read loop, and the reader is the only thing draining
     * the socket — so on fullscreen video the mailbox saturated, the reader
     * stopped reading, 2.5 MB piled up in the sender's send queue, its
     * in-flight budget pinned at 15/12 and it dropped 206 frames in a window.
     * The receiver sat 94% idle at 4 fps throughout, starved by its own reader,
     * and only killing both ends recovered it.
     *
     * A queue instead, so the reader never stops draining. Twelve is three
     * frames at four bands, matching the sender's in-flight budget: a burst is
     * absorbed, and a genuinely overwhelmed receiver drops rather than wedges.
     *
     * Owned buffers handed over by a reader, plus where the packet sits inside
     * each. No copy: the reader yields its whole parser buffer. */
    struct tb_video_slot {
        uint8_t       *buf;       /* owned allocation */
        size_t         cap;
        const uint8_t *payload;   /* points into buf */
        size_t         len;
        uint8_t        type;      /* RAW_FRAME, RAW_DPCM[_SLICE] */
        /* When this packet came off the socket. The frame path bypasses
         * on_packet, so g_pkt_recv_ms is never set for it -- without carrying the
         * stamp here, a recv->present measurement silently measures nothing. */
        double         recv_ms;
    }                vq[TB_VIDEO_QUEUE];
    int              vq_head;
    int              vq_count;
    uint64_t         vq_overflow;    /* increments dropped because it was full */

    /* Presentation pacing.
     *
     * The transport is clean -- 94-96% of presents one refresh apart, no drops,
     * no lost bands -- and 25 fps video still judders, because macOS has already
     * composited it as a 2,3,2,3 pulldown and we resample that onto this panel's
     * refresh grid. A frame arriving a hair late waits a whole extra period, so
     * 2,3,2,3 becomes 2,4,1,3: a hitch roughly twice a second, worst on the slow
     * pans where the eye is tracking.
     *
     * Presenting on the sender's CAPTURE time instead of on arrival reproduces
     * its spacing rather than the wire's. Simulated against the measured
     * distributions before writing any of it: hitches 8.8% -> 4.7% for 14 ms.
     *
     * `offset` converts a sender capture time into receiver time, estimated as
     * the SMALLEST (arrival - capture) seen recently: the least-delayed frame is
     * the closest thing to a pure clock difference, since every other sample has
     * queueing added and none can have less. */
    uint64_t         pace_offset_ns;
    uint64_t         pace_min_ns;      /* smallest delta this window */
    uint64_t         pace_win_end_ms;
    uint64_t         pace_held_since;  /* 0 when nothing is waiting */
    int              pace_enabled;
    uint32_t         connecting_since;/* when this client last had no video */
    uint32_t         dpcm_frame_id;   /* frame currently being assembled from slices */
    /* Which bands of the current frame actually decoded. A frame presents on its
     * last band whether or not the others arrived, and a missing band leaves the
     * previous frame's pixels in that strip — which looks exactly like a glitch,
     * so it has to be measured rather than assumed. */
    /* Frame assembly latency, reported with the [slices] line once a second. */
    double           dpcm_asm_ms_sum;
    double           dpcm_asm_ms_max;
    uint32_t         dpcm_asm_n;
    uint32_t         frame_lat_last_report;
    uint64_t         frames_dropped;

    /* Recycled buffers handed back to readers so nothing allocates (or
     * re-faults 59 MB) inside the frame loop. Sized against the video queue:
     * every slot's buffer comes back here when the main thread is done with it,
     * and a pool smaller than the queue would start freeing and reallocating
     * multi-MB blocks in the steady state. */
    uint8_t         *pool_buf[TB_VIDEO_POOL];
    size_t           pool_cap[TB_VIDEO_POOL];
    int              pool_n;

    struct tb_ctrl_msg    *ctrl_q;
    int              ctrl_head;
    int              ctrl_count;
    uint64_t         reader_recv_ms;

    struct tb_link_reader *reader1;


    uint64_t frames;
    uint64_t last_fps_tick_ms;
    uint64_t last_fps_count;
    uint64_t last_ip_check_ms;
    uint64_t last_idle_announce_ms; /* last idle-tick bonjour_update() while client_fd < 0 */
    /* Idle watchdog: last time the sender sent anything. Reader threads stamp
     * this asynchronously, so it can be *newer* than the `t` sampled at the top
     * of a loop iteration — every comparison must be underflow-safe. */
    /* Last display-tweak state reported to the sender, so changes made on this
     * Mac (Control Center, System Settings) propagate back and the sender's
     * toggles stay truthful. -1 = nothing sent yet. */
    int      reported_night_shift;
    int      reported_true_tone;
    uint64_t last_tweak_poll_ms;

    uint64_t last_recv_ms;
    int      close_requested;
    int      have_video_frame;
    /* A real streaming session has begun (the sender sent a session packet, not
     * just a transient probe like a UI-language push). Gates the fullscreen
     * "connecting" splash so a bare/short-lived connection doesn't flash it. */
    int      session_active;

    char     ip_text[64];
    char     tb_ip_text[64];
    char     net_ip_text[64];
    char     display_host[128]; /* short hostname (or hostname+IP), cached at startup */
    char     status_text[128];
    char     sender_text[128];
    char     panel_text[128];
    char     mode_text[128];
    char     language_pref[8];
    char     language_text[96];
    char     permissions_text[160];
    char     sender_ui_language[8];
    char     input_control_mode[32];
    int      last_input_monitoring_trusted;
    int      last_accessibility_trusted;
    uint64_t last_permissions_poll_ms;

    DNSServiceRef bonjour_ref;
    char     bonjour_name[128];
    CFMachPortRef input_tap;
    CFRunLoopSourceRef input_tap_source;
    int      input_tap_consumes_events;

    SDL_AudioDeviceID audio_device;

    /* Watchdog bookkeeping for tb_audio_open()/tb_audio_watchdog_tick() below.
     * audio_cb_ticks is written by audio_callback() (CoreAudio's own audio
     * thread, per SDL2's HAL-backed implementation -- see tb_audio_open()'s
     * comment for why the main loop reading it here is safe without a lock)
     * and read+compared by the main loop, hence atomic rather than a plain
     * counter: on x86_64 a lone uint64_t increment/read is already atomic at
     * the ISA level, but marking the intent explicitly is what stops a future
     * change (e.g. compiler auto-vectorizing, or porting to an arch without
     * that guarantee) from silently reintroducing a race on a variable whose
     * only job is telling the truth about whether audio is still alive. */
    _Atomic uint64_t audio_cb_ticks;
    uint64_t audio_watchdog_last_ticks;   /* value sampled at the previous check */
    uint64_t audio_watchdog_last_ms;      /* when that sample was taken */
    uint32_t audio_watchdog_stall_count;  /* consecutive checks with zero progress */
    uint64_t audio_reopen_retry_ms;       /* next time to retry an open that failed; 0 = not pending */
    uint64_t audio_diag_last_ms;          /* last [audio] diagnostic line, separate cadence from the watchdog */
    uint64_t audio_diag_last_ticks;
    /* Set when this receiver asks the iMac to sleep; the output is closed
     * and the watchdog stands down until the next wake or reopen. */
    int audio_suspended_for_sleep;

    /* Senders older than the Float32 change send Int16 and do not say so in
     * their hello. Assume Int16 until told otherwise, so such a sender plays
     * correctly instead of as noise. */
    int     audio_input_is_s16;
    uint8_t audio_buf[AUDIO_BUF_CAP];
    int     audio_buf_head;
    int     audio_buf_tail;
    int     audio_buf_size;

    uint64_t input_events_sent;
    uint64_t input_events_received;
    uint64_t last_target_switch_ms;
    uint64_t last_space_switch_ms;
    uint64_t last_space_gesture_ms;
    int      space_gesture_accum_x;
    int      sent_command_down;
    int      sent_shift_down;
    int      sent_option_down;
    int      sent_control_down;
    int      sent_caps_down;
    uint64_t last_clipboard_poll_ms;
    char     last_clipboard_text[4096];
};

static int tb_should_log_input_event(uint64_t count) {
    return count <= 20 || (count % 100) == 0;
}

static void tb_receiver_input_log(const char *fmt, ...) {
    char message[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(message, sizeof(message), fmt, args);
    va_end(args);

    fprintf(stderr, "%s\n", message);

    const char *home = getenv("HOME");
    if (!home || !*home) return;

    char dir[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s/Library/Application Support/TargetBridge Receiver/Logs", home);
    mkdir(dir, 0755);

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/input-debug.log", dir);
    FILE *f = fopen(path, "a");
    if (!f) return;

    time_t now = time(NULL);
    struct tm tm_now;
    localtime_r(&now, &tm_now);
    char timestamp[64];
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S%z", &tm_now);
    fprintf(f, "%s %s\n", timestamp, message);
    fclose(f);
}

static volatile sig_atomic_t g_term = 0;
static volatile sig_atomic_t g_term_signal = 0;
/* Record WHICH signal asked us to stop.
 *
 * The receiver exited silently, so a restart mid-session was indistinguishable
 * from a crash, a logout, or someone quitting it -- and the sender only sees the
 * link go away. Knowing whether this was SIGTERM (something asked politely, e.g.
 * an installer or launchctl) or SIGINT decides where to look next.
 *
 * async-signal-safe: just a flag. The reason is printed from the main loop. */
static void on_sigint(int s) { g_term_signal = s; g_term = 1; }

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
}

static void tb_copy_i18n(char *dest, size_t size, const char *key);
static void tb_format_i18n(char *dest,
                           size_t size,
                           const char *key,
                           const struct tb_i18n_pair *pairs,
                           size_t pair_count);
static void tb_set_receiver_mode_requested(char *dest,
                                           size_t size,
                                           int width,
                                           int height,
                                           const char *source,
                                           const char *preset,
                                           const char *codec);
static void tb_refresh_idle_localized_strings(struct app *a);
static void tb_receiver_load_language_preference(char *dest, size_t size);
static void tb_receiver_save_language_preference(const char *language_pref);
static void tb_receiver_apply_language_preference(struct app *a);
static void tb_receiver_cycle_language_preference(struct app *a);
static void tb_receiver_refresh_language_text(struct app *a);
static void tb_receiver_refresh_permissions_text(struct app *a);
static void tb_receiver_poll_permissions(struct app *a);
static int tb_receiver_input_monitoring_trusted(void);
static int tb_receiver_accessibility_trusted(void);
static void send_receiver_info(struct app *a);
static void tb_receiver_apply_input_event(const uint8_t *payload, size_t len);
static void tb_receiver_apply_input_control_mode(struct app *a, const uint8_t *payload, size_t len);
static void tb_receiver_refresh_input_capture(struct app *a);
static void tb_receiver_set_clipboard_text(const char *text);
static int tb_receiver_get_clipboard_text(char *dest, size_t size);
static void tb_receiver_send_clipboard_if_changed(struct app *a);
static void write_be32(uint8_t *dst, uint32_t value);
static int send_all(int fd, const uint8_t *buf, size_t len);
static void tb_receiver_send_display_tweaks_if_changed(struct app *a);

static int tb_receiver_is_valid_language_pref(const char *language_pref) {
    return language_pref &&
           (strcmp(language_pref, "auto") == 0 ||
            strcmp(language_pref, "it") == 0 ||
            strcmp(language_pref, "en") == 0 ||
            strcmp(language_pref, "de") == 0 ||
            strcmp(language_pref, "fr") == 0 ||
            strcmp(language_pref, "zh") == 0);
}

static void tb_receiver_settings_path(char *dest, size_t size) {
    const char *home = getenv("HOME");
    if (!dest || size == 0) return;
    dest[0] = '\0';
    if (!home || !*home) return;
    snprintf(dest, size, "%s/Library/Application Support/TargetBridge Receiver/settings.json", home);
}

static void tb_receiver_ensure_settings_dir(void) {
    const char *home = getenv("HOME");
    if (!home || !*home) return;

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/Library", home);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/Library/Application Support", home);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/Library/Application Support/TargetBridge Receiver", home);
    mkdir(path, 0755);
}

static void tb_receiver_load_language_preference(char *dest, size_t size) {
    if (!dest || size == 0) return;
    snprintf(dest, size, "%s", "auto");

    char path[PATH_MAX];
    tb_receiver_settings_path(path, sizeof(path));
    if (!path[0]) return;

    FILE *fp = fopen(path, "rb");
    if (!fp) return;

    char buf[256];
    size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
    fclose(fp);
    buf[n] = '\0';

    const char *pos = strstr(buf, "\"language\"");
    if (!pos) return;
    pos = strchr(pos, ':');
    if (!pos) return;
    pos = strchr(pos, '"');
    if (!pos) return;
    pos++;

    char code[8];
    size_t i = 0;
    while (*pos && *pos != '"' && i + 1 < sizeof(code)) code[i++] = *pos++;
    code[i] = '\0';

    if (tb_receiver_is_valid_language_pref(code)) {
        snprintf(dest, size, "%s", code);
    }
}

static void tb_receiver_save_language_preference(const char *language_pref) {
    if (!tb_receiver_is_valid_language_pref(language_pref)) return;
    tb_receiver_ensure_settings_dir();

    char path[PATH_MAX];
    tb_receiver_settings_path(path, sizeof(path));
    if (!path[0]) return;

    FILE *fp = fopen(path, "wb");
    if (!fp) return;
    fprintf(fp, "{\n  \"language\": \"%s\"\n}\n", language_pref);
    fclose(fp);
}

static const char *tb_receiver_language_display_name(const char *language_code) {
    if (!language_code || !*language_code) language_code = "en";
    if (strcmp(language_code, "it") == 0) return tb_i18n_get("common.language.italian");
    if (strcmp(language_code, "de") == 0) return tb_i18n_get("common.language.german");
    if (strcmp(language_code, "fr") == 0) return tb_i18n_get("common.language.french");
    if (strcmp(language_code, "zh") == 0) return tb_i18n_get("common.language.chinese");
    return tb_i18n_get("common.language.english");
}

static void tb_receiver_refresh_language_text(struct app *a) {
    if (!a) return;
    if (strcmp(a->language_pref, "auto") == 0) {
        snprintf(a->language_text,
                 sizeof(a->language_text),
                 "%s · %s",
                 tb_i18n_get("receiver.language.auto"),
                 tb_receiver_language_display_name(tb_i18n_current_language()));
    } else {
        snprintf(a->language_text,
                 sizeof(a->language_text),
                 "%s",
                 tb_receiver_language_display_name(a->language_pref));
    }
}

static void tb_receiver_refresh_permissions_text(struct app *a) {
    if (!a) return;

    const int input_monitoring = (a->last_input_monitoring_trusted >= 0)
        ? a->last_input_monitoring_trusted
        : tb_receiver_input_monitoring_trusted();
    const int accessibility = (a->last_accessibility_trusted >= 0)
        ? a->last_accessibility_trusted
        : tb_receiver_accessibility_trusted();
    const char *lang = tb_i18n_current_language();

    if (lang && strncmp(lang, "it", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Monitoraggio input: %s   Accessibilità: %s",
            input_monitoring ? "OK" : "Mancante",
            accessibility ? "OK" : "Mancante"
        );
    } else if (lang && strncmp(lang, "de", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Input-Monitoring: %s   Bedienungshilfen: %s",
            input_monitoring ? "OK" : "Fehlt",
            accessibility ? "OK" : "Fehlt"
        );
    } else if (lang && strncmp(lang, "zh", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "输入监控：%s   辅助功能：%s",
            input_monitoring ? "正常" : "缺失",
            accessibility ? "正常" : "缺失"
        );
    } else {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Input Monitoring: %s   Accessibility: %s",
            input_monitoring ? "OK" : "Missing",
            accessibility ? "OK" : "Missing"
        );
    }
}

static void tb_receiver_poll_permissions(struct app *a) {
    if (!a) return;

    const int input_monitoring = tb_receiver_input_monitoring_trusted();
    const int accessibility = tb_receiver_accessibility_trusted();

    const int changed =
        input_monitoring != a->last_input_monitoring_trusted ||
        accessibility != a->last_accessibility_trusted;

    a->last_input_monitoring_trusted = input_monitoring;
    a->last_accessibility_trusted = accessibility;

    if (!changed) return;

    tb_receiver_refresh_permissions_text(a);
    tb_receiver_refresh_input_capture(a);
    if (a->client_fd >= 0) {
        send_receiver_info(a);
    }
    tb_receiver_input_log("[input] permission state changed inputMonitoring=%s accessibility=%s",
                          input_monitoring ? "true" : "false",
                          accessibility ? "true" : "false");
}

static void tb_receiver_apply_language_preference(struct app *a) {
    if (!a) return;

    if (strcmp(a->language_pref, "auto") == 0) {
        if (a->sender_ui_language[0] != '\0') {
            tb_i18n_set_runtime_language(a->sender_ui_language);
        } else {
            tb_i18n_set_runtime_language("auto");
        }
    } else {
        tb_i18n_set_runtime_language(a->language_pref);
    }

    tb_refresh_idle_localized_strings(a);
    tb_receiver_refresh_language_text(a);
    tb_receiver_refresh_permissions_text(a);
}

static int tb_receiver_input_monitoring_trusted(void) {
    return CGPreflightListenEventAccess() ? 1 : 0;
}

static int tb_receiver_accessibility_trusted(void) {
    return AXIsProcessTrusted() ? 1 : 0;
}

static void tb_receiver_cycle_language_preference(struct app *a) {
    if (!a) return;

    if (strcmp(a->language_pref, "auto") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "it");
    } else if (strcmp(a->language_pref, "it") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "en");
    } else if (strcmp(a->language_pref, "en") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "de");
    } else if (strcmp(a->language_pref, "de") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "fr");
    } else if (strcmp(a->language_pref, "fr") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "zh");
    } else {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "auto");
    }

    tb_receiver_save_language_preference(a->language_pref);
    tb_receiver_apply_language_preference(a);
}

static void tb_refresh_idle_localized_strings(struct app *a) {
    if (!a) return;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.waiting_for_sender");
    tb_copy_i18n(a->sender_text, sizeof(a->sender_text), "receiver.status.waiting");
    tb_copy_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.default");
    tb_receiver_refresh_permissions_text(a);
    if (a->ip_text[0] == '\0') {
        tb_copy_i18n(a->ip_text, sizeof(a->ip_text), "receiver.network.not_detected");
    }
}

static void tb_copy_i18n(char *dest, size_t size, const char *key) {
    if (!dest || size == 0) return;
    snprintf(dest, size, "%s", tb_i18n_get(key));
}

static void tb_json_escape_string(const char *src, char *dest, size_t size) {
    if (!dest || size == 0) return;
    if (!src) {
        dest[0] = '\0';
        return;
    }

    size_t j = 0;
    for (size_t i = 0; src[i] != '\0' && j + 1 < size; i++) {
        char c = src[i];
        const char *escape = NULL;
        switch (c) {
        case '\\': escape = "\\\\"; break;
        case '"': escape = "\\\""; break;
        case '\n': escape = "\\n"; break;
        case '\r': escape = "\\r"; break;
        case '\t': escape = "\\t"; break;
        default: break;
        }

        if (escape) {
            for (size_t k = 0; escape[k] != '\0' && j + 1 < size; k++) {
                dest[j++] = escape[k];
            }
        } else {
            dest[j++] = c;
        }
    }
    dest[j] = '\0';
}

static void tb_receiver_set_clipboard_text(const char *text) {
    FILE *pipe = popen("pbcopy", "w");
    if (!pipe) return;
    if (text && *text) {
        fwrite(text, 1, strlen(text), pipe);
    }
    pclose(pipe);
}

static int tb_receiver_get_clipboard_text(char *dest, size_t size) {
    if (!dest || size == 0) return 0;
    dest[0] = '\0';

    FILE *pipe = popen("pbpaste", "r");
    if (!pipe) return 0;

    size_t total = 0;
    while (!feof(pipe) && total + 1 < size) {
        size_t n = fread(dest + total, 1, size - total - 1, pipe);
        total += n;
        if (n == 0) break;
    }
    dest[total] = '\0';
    pclose(pipe);
    return 1;
}

static void tb_receiver_send_clipboard_if_changed(struct app *a) {
    if (!a || strcmp(a->input_control_mode, "receiverMaster") != 0 || a->client_fd < 0) return;

    char text[4096];
    if (!tb_receiver_get_clipboard_text(text, sizeof(text))) return;
    if (strcmp(text, a->last_clipboard_text) == 0) return;

    snprintf(a->last_clipboard_text, sizeof(a->last_clipboard_text), "%s", text);

    char escaped[8192];
    tb_json_escape_string(text, escaped, sizeof(escaped));

    char json[8300];
    int len = snprintf(json, sizeof(json), "{\"text\":\"%s\"}", escaped);
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    uint8_t header[TB_HDR_BYTES];
    write_be32(header, (uint32_t)(1 + len));
    header[4] = TB_PKT_CLIPBOARD;
    if (write(a->client_fd, header, TB_HDR_BYTES) != TB_HDR_BYTES) return;
    (void)write(a->client_fd, json, (size_t)len);
}

static void tb_format_i18n(char *dest,
                           size_t size,
                           const char *key,
                           const struct tb_i18n_pair *pairs,
                           size_t pair_count) {
    tb_i18n_format(dest, size, key, pairs, pair_count);
}

static void tb_set_receiver_mode_requested(char *dest,
                                           size_t size,
                                           int width,
                                           int height,
                                           const char *source,
                                           const char *preset,
                                           const char *codec) {
    char width_text[16];
    char height_text[16];
    snprintf(width_text, sizeof(width_text), "%d", width);
    snprintf(height_text, sizeof(height_text), "%d", height);

    struct tb_i18n_pair pairs[] = {
        { "width", width_text },
        { "height", height_text },
        { "source", source ? source : "" },
        { "preset", preset ? preset : "" },
        { "codec", codec ? codec : "" }
    };

    if (width > 0 && height > 0 && source && *source && preset && *preset && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_source_preset_codec", pairs, 5);
    } else if (width > 0 && height > 0 && preset && *preset && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_preset_codec", pairs, 5);
    } else if (width > 0 && height > 0 && preset && *preset) {
        tb_format_i18n(dest, size, "receiver.mode.requested_preset", pairs, 5);
    } else if (width > 0 && height > 0 && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_codec", pairs, 5);
    } else if (width > 0 && height > 0) {
        tb_format_i18n(dest, size, "receiver.mode.requested", pairs, 5);
    }
}

static void bonjour_deinit(struct app *a) {
    if (a->bonjour_ref) {
        DNSServiceRefDeallocate(a->bonjour_ref);
        a->bonjour_ref = NULL;
    }
}

static void on_bonjour_register(DNSServiceRef sdRef,
                                DNSServiceFlags flags,
                                DNSServiceErrorType errorCode,
                                const char *name,
                                const char *regtype,
                                const char *domain,
                                void *context) {
    (void)sdRef;
    (void)flags;
    (void)context;
    if (errorCode == kDNSServiceErr_NoError) {
        fprintf(stderr, "[bonjour] published %s.%s%s\n", name ? name : "TargetBridge Receiver", regtype ? regtype : "", domain ? domain : "");
    } else {
        fprintf(stderr, "[bonjour] register failed: %d\n", (int)errorCode);
    }
}

static void bonjour_update(struct app *a, uint16_t port) {
    bonjour_deinit(a);

    if (a->ip_text[0] == '\0' || strcmp(a->ip_text, tb_i18n_get("receiver.network.not_detected")) == 0) return;

    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    TXTRecordSetValue(&txt, "name", (uint8_t)strlen(a->bonjour_name), a->bonjour_name);
    TXTRecordSetValue(&txt, "ip", (uint8_t)strlen(a->ip_text), a->ip_text);
    if (a->tb_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "tbIP", (uint8_t)strlen(a->tb_ip_text), a->tb_ip_text);
    }
    if (a->net_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "netIP", (uint8_t)strlen(a->net_ip_text), a->net_ip_text);
    }
    TXTRecordSetValue(&txt, "panel", (uint8_t)strlen(a->panel_text), a->panel_text);
    TXTRecordSetValue(&txt, "version", (uint8_t)strlen(TB_RECEIVER_VERSION), TB_RECEIVER_VERSION);
    TXTRecordSetValue(&txt, "supportsHEVCDecode", 1, tb_dec_supports_hevc_hwdecode() ? "1" : "0");
    TXTRecordSetValue(&txt, "supportsRawNV12", 1, "1");

    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) == 0) {
        char panel_w[16];
        char panel_h[16];
        snprintf(panel_w, sizeof(panel_w), "%u", info.active_w);
        snprintf(panel_h, sizeof(panel_h), "%u", info.active_h);
        TXTRecordSetValue(&txt, "panelWidth", (uint8_t)strlen(panel_w), panel_w);
        TXTRecordSetValue(&txt, "panelHeight", (uint8_t)strlen(panel_h), panel_h);
    }

    DNSServiceErrorType err = DNSServiceRegister(
        &a->bonjour_ref,
        0,
        0,
        a->bonjour_name,
        "_targetbridge._tcp",
        "local.",
        NULL,
        htons(port),
        TXTRecordGetLength(&txt),
        TXTRecordGetBytesPtr(&txt),
        on_bonjour_register,
        a
    );
    TXTRecordDeallocate(&txt);

    if (err != kDNSServiceErr_NoError) {
        fprintf(stderr, "[bonjour] unable to publish receiver service: %d\n", (int)err);
        bonjour_deinit(a);
    }
}

static void extract_json_string_field(const uint8_t *payload,
                                      size_t len,
                                      const char *key,
                                      char *out,
                                      size_t out_size) {
    if (!payload || !key || !out || out_size == 0) return;
    out[0] = '\0';

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return;

    pos = strchr(pos, ':');
    if (!pos) return;
    pos = strchr(pos, '"');
    if (!pos) return;
    pos++;

    size_t i = 0;
    while ((size_t)(pos - text) < len && *pos && *pos != '"' && i + 1 < out_size) {
        if (*pos == '\\' && (size_t)(pos - text + 1) < len && pos[1] != '\0') pos++;
        out[i++] = *pos++;
    }
    out[i] = '\0';
}

static int extract_json_int_field(const uint8_t *payload,
                                  size_t len,
                                  const char *key,
                                  int *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    char *end = NULL;
    long value = strtol(pos, &end, 10);
    if (end == pos) return 0;
    *out_value = (int)value;
    return 1;
}

static int extract_json_bool_field(const uint8_t *payload,
                                   size_t len,
                                   const char *key,
                                   int *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    if (strncmp(pos, "true", 4) == 0) {
        *out_value = 1;
        return 1;
    }
    if (strncmp(pos, "false", 5) == 0) {
        *out_value = 0;
        return 1;
    }
    return extract_json_int_field(payload, len, key, out_value);
}

static int extract_json_double_field(const uint8_t *payload,
                                     size_t len,
                                     const char *key,
                                     double *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    char *end = NULL;
    double value = strtod(pos, &end);
    if (end == pos) return 0;
    *out_value = value;
    return 1;
}

static CGPoint tb_receiver_current_mouse_location(void) {
    CGPoint point = CGPointZero;
    CGEventRef event = CGEventCreate(NULL);
    if (event) {
        point = CGEventGetLocation(event);
        CFRelease(event);
    }
    return point;
}

static void tb_receiver_post_mouse_move(int dx, int dy, CGEventType type, CGMouseButton button) {
    CGPoint current = tb_receiver_current_mouse_location();
    CGPoint target = CGPointMake(current.x + dx, current.y + dy);
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, target, button);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_mouse_button(CGEventType type, CGMouseButton button) {
    CGPoint current = tb_receiver_current_mouse_location();
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, current, button);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_scroll(int scroll_x, int scroll_y) {
    CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 2, scroll_y, scroll_x);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_key(uint16_t key_code, int is_down) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key_code, is_down ? true : false);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_apply_input_event(const uint8_t *payload, size_t len) {
    char kind[32];
    kind[0] = '\0';
    extract_json_string_field(payload, len, "\"kind\"", kind, sizeof(kind));
    if (kind[0] == '\0') return;
    tb_receiver_input_log("[input][sender->receiver] received kind=%s len=%zu", kind, len);

    if (strcmp(kind, "move") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventMouseMoved, kCGMouseButtonLeft);
        return;
    }

    if (strcmp(kind, "leftDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventLeftMouseDragged, kCGMouseButtonLeft);
        return;
    }

    if (strcmp(kind, "rightDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventRightMouseDragged, kCGMouseButtonRight);
        return;
    }

    if (strcmp(kind, "otherDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventOtherMouseDragged, kCGMouseButtonCenter);
        return;
    }

    if (strcmp(kind, "leftDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventLeftMouseDown, kCGMouseButtonLeft);
        return;
    }
    if (strcmp(kind, "leftUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventLeftMouseUp, kCGMouseButtonLeft);
        return;
    }
    if (strcmp(kind, "rightDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventRightMouseDown, kCGMouseButtonRight);
        return;
    }
    if (strcmp(kind, "rightUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventRightMouseUp, kCGMouseButtonRight);
        return;
    }
    if (strcmp(kind, "otherDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventOtherMouseDown, kCGMouseButtonCenter);
        return;
    }
    if (strcmp(kind, "otherUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventOtherMouseUp, kCGMouseButtonCenter);
        return;
    }
    if (strcmp(kind, "scroll") == 0) {
        int scroll_x = 0;
        int scroll_y = 0;
        (void)extract_json_int_field(payload, len, "\"scrollX\"", &scroll_x);
        (void)extract_json_int_field(payload, len, "\"scrollY\"", &scroll_y);
        tb_receiver_post_scroll(scroll_x, scroll_y);
        return;
    }
    if (strcmp(kind, "keyDown") == 0 || strcmp(kind, "keyUp") == 0) {
        int key_code = 0;
        if (extract_json_int_field(payload, len, "\"keyCode\"", &key_code)) {
            tb_receiver_post_key((uint16_t)key_code, strcmp(kind, "keyDown") == 0);
        }
    }
}

static void tb_receiver_apply_input_control_mode(struct app *a, const uint8_t *payload, size_t len) {
    char mode[32];
    mode[0] = '\0';
    extract_json_string_field(payload, len, "\"mode\"", mode, sizeof(mode));
    if (mode[0] == '\0') {
        snprintf(a->input_control_mode, sizeof(a->input_control_mode), "off");
    } else {
        snprintf(a->input_control_mode, sizeof(a->input_control_mode), "%s", mode);
    }
    tb_receiver_input_log("[input] control mode updated to %s", a->input_control_mode);
    if (strcmp(a->input_control_mode, "receiverMaster") != 0) {
        a->sent_command_down = 0;
        a->sent_shift_down = 0;
        a->sent_option_down = 0;
        a->sent_control_down = 0;
        a->sent_caps_down = 0;
    }
    tb_receiver_refresh_input_capture(a);
}

/* ---- Callbacks: decoder → display ------------------------------------ */

static void on_frame(const uint8_t *y, int y_stride,
                     const uint8_t *uv, int uv_stride,
                     int w, int h, void *ud) {
    struct app *a = (struct app *)ud;
    a->have_video_frame = 1;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    {
        char width_text[16];
        char height_text[16];
        struct tb_i18n_pair pairs[] = {
            { "width", width_text },
            { "height", height_text }
        };
        snprintf(width_text, sizeof(width_text), "%d", w);
        snprintf(height_text, sizeof(height_text), "%d", h);
        tb_format_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.receiving", pairs, 2);
    }
    tb_disp_render_nv12(a->disp, y, y_stride, uv, uv_stride, w, h);
    a->frames++;
}

/* Raw passthrough: render received NV12 planes directly, bypassing the decoder.
 * Payload: [1: format=1(NV12)][BE32 w][BE32 h][BE32 yStride][BE32 uvStride]
 *          [Y plane: yStride*h][CbCr plane: uvStride*(h/2)] */
static void handle_raw_frame(struct app *a, const uint8_t *p, size_t len) {
    if (len < 13) return;
    uint8_t format = p[0];  /* 1 = NV12 4:2:0, 2 = BGRA8888 4:4:4, 3 = ARGB2101010 4:4:4 */
    uint32_t w = ((uint32_t)p[1] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 8) | (uint32_t)p[4];
    uint32_t h = ((uint32_t)p[5] << 24) | ((uint32_t)p[6] << 16) | ((uint32_t)p[7] << 8) | (uint32_t)p[8];
    /* Sanity bounds: reject implausible dimensions so the size math below can't
     * overflow on a malformed packet. */
    if (w == 0 || h == 0 || w > 16384 || h > 16384) return;

    const uint8_t *y = NULL, *uv = NULL, *rgba = NULL;
    uint32_t ys = 0, us = 0, stride = 0;

    if (format == 1) {
        if (len < 17) return;
        ys = ((uint32_t)p[9]  << 24) | ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 8) | (uint32_t)p[12];
        us = ((uint32_t)p[13] << 24) | ((uint32_t)p[14] << 16) | ((uint32_t)p[15] << 8) | (uint32_t)p[16];
        if (ys < w || us < w) return;
        size_t y_size  = (size_t)ys * h;
        size_t uv_size = (size_t)us * (h / 2);
        if (len < (size_t)17 + y_size + uv_size) return;
        y  = p + 17;
        uv = y + y_size;
    } else if (format == 2 || format == 3) {
        /* Both packed 4:4:4 at 4 bytes/pixel — identical layout, and only the
         * texture format the receiver picks differs. */
        stride = ((uint32_t)p[9] << 24) | ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 8) | (uint32_t)p[12];
        if ((uint64_t)stride < (uint64_t)w * 4) return;   /* 4 bytes/pixel */
        size_t size = (size_t)stride * h;
        if (len < (size_t)13 + size) return;
        rgba = p + 13;
    } else {
        return;  /* unknown format */
    }

    a->have_video_frame = 1;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    {
        char width_text[16];
        char height_text[16];
        struct tb_i18n_pair pairs[] = {
            { "width", width_text },
            { "height", height_text }
        };
        snprintf(width_text, sizeof(width_text), "%u", w);
        snprintf(height_text, sizeof(height_text), "%u", h);
        tb_format_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.receiving", pairs, 2);
    }
    if (format == 1) {
        tb_disp_render_nv12(a->disp, y, (int)ys, uv, (int)us, (int)w, (int)h);
    } else {
        tb_disp_render_packed32(a->disp, rgba, (int)stride, (int)w, (int)h, format == 3);
    }
    a->frames++;
}


/* TB_PKT_RAW_DPCM — a whole frame, losslessly compressed (tb_dpcm.h). Decoded
 * on the GPU; there is no CPU-side copy and no base image, which is why the
 * sender does not mix damage packets into this path.
 *
 * Nothing is validated here on purpose: tb_metal_plane_render_dpcm calls
 * tb_dpcm_parse, which checks every declared length against the actual one and
 * re-derives the offset table from the width plane. That check is what allows
 * the decode kernel to run with no bounds tests at all. */
/* Declared here: both frame handlers below time presentation with it. */
static double now_ms_f(void);
static double g_pkt_recv_ms;

/* Frame latency: first byte of this frame off the socket -> frame presented.
 *
 * Called from BOTH the sliced and the unsliced handler with the same clock and
 * the same start point (the reader thread's receive stamp), which is the only way
 * to compare N=1 against N>1. The first version of this lived inside the sliced
 * path only and therefore could not measure the thing it was built to compare.
 *
 * Excludes capture, encode and the network hop on purpose: the sender's clock is
 * on another machine and unsynchronised, so including them would report skew. */
static void tb_note_frame_latency(struct app *a, double first_byte_ms) {
    if (first_byte_ms <= 0.0) return;
    const double span = now_ms_f() - first_byte_ms;
    /* A negative or absurd span means the start stamp was not this frame's. */
    if (span < 0.0 || span > 200.0) return;
    a->dpcm_asm_ms_sum += span;
    if (span > a->dpcm_asm_ms_max) a->dpcm_asm_ms_max = span;
    a->dpcm_asm_n++;

    /* Reported from HERE, not from the [slices] line, because [slices] only fires
     * on the sliced packet path -- so at TBSliceCount=1 the number the whole
     * exercise exists to compare would never print. Both handlers reach this. */
    const uint32_t now_s = SDL_GetTicks() / 1000;
    if (now_s != a->frame_lat_last_report && a->dpcm_asm_n >= 30) {
        a->frame_lat_last_report = now_s;
        fprintf(stderr, "[latency] frame recv->present %.2f avg / %.2f worst ms | n=%u\n",
                a->dpcm_asm_ms_sum / a->dpcm_asm_n, a->dpcm_asm_ms_max, a->dpcm_asm_n);
        a->dpcm_asm_ms_sum = a->dpcm_asm_ms_max = 0.0; a->dpcm_asm_n = 0;
    }
}

static void handle_raw_dpcm(struct app *a, const uint8_t *payload, size_t len) {
    const double first_byte = g_pkt_recv_ms;
    if (tb_disp_render_dpcm(a->disp, payload, len) != 0) {
        a->frames_dropped++;
        return;
    }
    tb_note_frame_latency(a, first_byte);
    a->have_video_frame = 1;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    a->frames++;
}

/* The protocol is big-endian on the wire; main.c had only a writer. */
static inline uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] <<  8) | (uint32_t)p[3];
}

static void ring_read(struct app *a, Uint8 *dst, int len) {
    int first = AUDIO_BUF_CAP - a->audio_buf_tail;
    if (first >= len) {
        memcpy(dst, a->audio_buf + a->audio_buf_tail, len);
    } else {
        memcpy(dst, a->audio_buf + a->audio_buf_tail, first);
        memcpy(dst + first, a->audio_buf, len - first);
    }
    a->audio_buf_tail = (a->audio_buf_tail + len) % AUDIO_BUF_CAP;
    a->audio_buf_size -= len;
}

static void audio_callback(void *userdata, Uint8 *stream, int len) {
    struct app *a = (struct app *)userdata;
    /* Heartbeat: proves this callback is still being driven by CoreAudio at
     * all, independent of whether the ring buffer had anything queued for it.
     * Runs on CoreAudio's own render thread (SDL2's macOS backend calls this
     * straight from the HAL I/O proc), which is why it is a plain increment
     * on an atomic rather than anything that could block -- see the field's
     * declaration in struct app and tb_audio_open()'s comment for the full
     * threading picture. */
    atomic_fetch_add_explicit(&a->audio_cb_ticks, 1, memory_order_relaxed);
    if (a->audio_buf_size >= len) {
        ring_read(a, stream, len);
    } else {
        int available = a->audio_buf_size;
        if (available > 0) ring_read(a, stream, available);
        memset(stream + available, 0, len - available);
    }
}

/* ---- Audio output open/close/watchdog ---------------------------------
 *
 * See the TB_AUDIO_WATCHDOG_* comment near the top of the file for why this
 * exists at all. tb_audio_open()/tb_audio_close() factor out what used to be
 * inline, startup-only code in main() so the exact same path opens the
 * device the first time and reopens it later -- a startup-only helper that a
 * reopen calls slightly differently is exactly how this class of bug hides.
 *
 * THREADING: audio_device is only ever written here, and all call sites --
 * the accept branch's client-connect handling, close_client(), and
 * tb_audio_watchdog_tick() below -- run on the main thread. TB_PKT_AUDIO_FRAME
 * (the other reader of audio_device, in on_packet)
 * also only ever runs on the main thread: reader_on_packet() queues audio
 * frames into ctrl_q for anything that is not TB_PKT_RAW_FRAME/RAW_DPCM, and
 * pump_network() drains that queue by calling on_packet() from inside the
 * main loop; the non-threaded fallback path (drain_socket() -> the parser's
 * callback) reaches on_packet() the same way, synchronously from the main
 * loop. So a reopen and an incoming audio frame can never actually run at
 * the same time -- confirmed by reading the call graph, not assumed. The one
 * real cross-thread access is CoreAudio's render thread calling
 * audio_callback() while the main thread calls SDL_CloseAudioDevice(): SDL
 * itself makes that safe (SDL_CloseAudioDevice stops and joins the device's
 * audio thread before returning, so the callback cannot be mid-flight when
 * the device handle is invalidated), which is the same guarantee close_client()
 * already relies on implicitly today. The ring-buffer field reset below still
 * takes SDL_LockAudioDevice on the *new* device, matching close_client()'s
 * existing pattern, because audio_callback on that new device starts running
 * immediately once SDL_PauseAudioDevice(0) is called and must not observe a
 * half-written head/tail/size. */

static void tb_audio_close(struct app *a) {
    if (a->audio_device == 0) return;
    SDL_CloseAudioDevice(a->audio_device);   /* stops+joins the callback thread first */
    a->audio_device = 0;
}

/* 0 on success. On failure a.audio_device is left at 0 and the caller is
 * responsible for scheduling a retry (see TB_AUDIO_REOPEN_RETRY_MS) --
 * this function never blocks or spins waiting for the device to appear. */
static int tb_audio_open(struct app *a) {
    a->audio_suspended_for_sleep = 0;
    SDL_AudioSpec spec;
    SDL_zero(spec);
    spec.freq = AUDIO_SAMPLE_RATE;
    spec.format = AUDIO_F32SYS; // 32-bit float, native endian — CoreAudio's own format
    spec.channels = AUDIO_CHANNELS;          // Stereo
    spec.samples = 1024;   // ~21ms at 48kHz; see the startup comment this replaced
    spec.callback = audio_callback;
    spec.userdata = a;
    SDL_AudioSpec obtained;
    SDL_AudioDeviceID dev = SDL_OpenAudioDevice(NULL, 0, &spec, &obtained, 0);
    if (dev == 0) {
        fprintf(stderr, "[audio] SDL_OpenAudioDevice failed: %s\n", SDL_GetError());
        return -1;
    }
    a->audio_device = dev;

    /* Fresh device, fresh ring buffer -- matching close_client()'s existing
     * reset (~line 2799). Anything queued for the old device is audio timed
     * against a route that is gone; playing it out on the new one would just
     * be stale sound at the wrong moment, and it is a few ms of buffer at
     * most (AUDIO_BACKLOG_MAX_MS=150). */
    SDL_LockAudioDevice(a->audio_device);
    a->audio_buf_head = 0;
    a->audio_buf_tail = 0;
    a->audio_buf_size = 0;
    SDL_UnlockAudioDevice(a->audio_device);

    /* Rebaseline the watchdog against this device's own callback stream --
     * comparing post-reopen ticks against a pre-reopen count would read the
     * gap while the old device was dead as more of the same stall. */
    atomic_store_explicit(&a->audio_cb_ticks, 0, memory_order_relaxed);
    a->audio_watchdog_last_ticks = 0;
    a->audio_watchdog_last_ms = now_ms();
    a->audio_watchdog_stall_count = 0;

    SDL_PauseAudioDevice(a->audio_device, 0); // Start playing (unpaused)
    fprintf(stderr, "[audio] output device opened: %d Hz, %d ch, 32-bit float (obtained %d samples)\n",
            AUDIO_SAMPLE_RATE, AUDIO_CHANNELS, obtained.samples);
    return 0;
}

/* Called once per main-loop iteration; internally rate-limited to
 * TB_AUDIO_WATCHDOG_INTERVAL_MS for the stall check and
 * TB_AUDIO_DIAG_INTERVAL_MS for the diagnostic line, so calling it every
 * iteration costs one atomic load and two integer comparisons in the common
 * case where neither is due yet. */
static void tb_audio_watchdog_tick(struct app *a, uint64_t t) {
    /* No client attached: audio output is intentionally closed (see
     * close_client()), not merely paused, so CoreAudio's IO actually stops
     * and coreaudiod drops its PreventUserIdleSystemSleep assertion --
     * measured on the iMac, that assertion was held by coreaudiod for the
     * entire 49h+ runtime of a receiver that left the device open and
     * unpaused (playing silence) with no client connected at all. There is
     * nothing to stall-check or reopen until a session exists, so bail
     * before any of that; drain the wake flag too, so a wake that lands
     * while idle doesn't queue up a spurious reopen-on-wake for whatever
     * session connects next (tb_audio_open() on that accept already starts
     * clean). */
    if (a->client_fd < 0) {
        (void)tb_wake_watch_take_wake();
        a->audio_reopen_retry_ms = 0;
        if (t - a->audio_diag_last_ms >= TB_AUDIO_WATCHDOG_INTERVAL_MS * 5) {
            fprintf(stderr, "[audio] idle (no client)\n");
            a->audio_diag_last_ms = t;
        }
        return;
    }

    /* Going to sleep on purpose (request_system_sleep()). CoreAudio stops
     * the output as the machine goes down, which the heartbeat below reads
     * as a stall. Measured 2026-10-08: it then retried the open every 5s,
     * each failing with AudioQueueStart -66681 and blocking this loop for
     * ~2.5s, and the iMac took 21s instead of ~15s to reach sleep. Stand
     * down until a real wake; the wake flag reopens it. A dark wake does not
     * post NSWorkspaceDidWakeNotification, so maintenance wakes leave the
     * output closed. */
    if (a->audio_suspended_for_sleep) {
        if (tb_wake_watch_take_wake()) {
            fprintf(stderr, "[audio] system wake after sleep -- reopening\n");
            a->audio_reopen_retry_ms = (tb_audio_open(a) != 0) ? t + TB_AUDIO_REOPEN_RETRY_MS : 0;
        } else if (t - a->audio_diag_last_ms >= TB_AUDIO_WATCHDOG_INTERVAL_MS * 5) {
            fprintf(stderr, "[audio] suspended (system sleep requested)\n");
            a->audio_diag_last_ms = t;
        }
        return;
    }

    /* System wake: the failure mode this covers is a callback that keeps
     * firing right through the sleep/wake (ticks advancing normally) into a
     * route CoreAudio has already torn down, which the heartbeat below
     * cannot distinguish from healthy output. Reopen unconditionally rather
     * than trying to confirm it is actually dead first -- an unnecessary
     * reopen costs a few ms of silence, a missed dead route costs the rest
     * of the session, same trade the heartcheck below makes the other way
     * for a stall that is NOT a wake. */
    if (tb_wake_watch_take_wake()) {
        fprintf(stderr, "[audio] output stalled (system wake) -- reopening\n");
        tb_audio_close(a);
        a->audio_reopen_retry_ms = (tb_audio_open(a) != 0) ? t + TB_AUDIO_REOPEN_RETRY_MS : 0;
        return;
    }

    if (a->audio_device == 0) {
        /* Never opened, or a previous (re)open attempt failed outright.
         * Retry on a timer rather than spinning every loop iteration or
         * staying silent forever until someone restarts the process. */
        if (a->audio_reopen_retry_ms != 0 && t >= a->audio_reopen_retry_ms) {
            fprintf(stderr, "[audio] retrying output device open\n");
            a->audio_reopen_retry_ms = (tb_audio_open(a) != 0) ? t + TB_AUDIO_REOPEN_RETRY_MS : 0;
        }
        if (t - a->audio_diag_last_ms >= TB_AUDIO_WATCHDOG_INTERVAL_MS * 5) {
            fprintf(stderr, "[audio] dead (device not open)\n");
            a->audio_diag_last_ms = t;
        }
        return;
    }

    if (t - a->audio_watchdog_last_ms >= TB_AUDIO_WATCHDOG_INTERVAL_MS) {
        const uint64_t ticks = atomic_load_explicit(&a->audio_cb_ticks, memory_order_relaxed);
        const SDL_AudioStatus status = SDL_GetAudioDeviceStatus(a->audio_device);
        const int status_bad = (status != SDL_AUDIO_PLAYING);
        /* Compared against the value sampled at the PREVIOUS tick, not
         * against any wall-clock-derived expectation of how many ticks
         * "should" have happened by now -- a single long loop stall (a
         * 68-minute single iteration was observed live across a sleep) must
         * not read as "zero progress since forever ago" on the very first
         * tick after it. audio_watchdog_last_ticks only ever changes here,
         * so whatever real time elapsed during that stall, this compares
         * against the count from immediately before it, which is the
         * correct comparison rather than a false trigger. */
        const int no_progress = (ticks == a->audio_watchdog_last_ticks);
        a->audio_watchdog_stall_count = no_progress ? a->audio_watchdog_stall_count + 1 : 0;
        a->audio_watchdog_last_ticks = ticks;
        a->audio_watchdog_last_ms = t;

        if (status_bad || a->audio_watchdog_stall_count >= TB_AUDIO_WATCHDOG_STALL_TICKS) {
            const char *reason = status_bad ? "device not playing" : "callback stalled";
            fprintf(stderr, "[audio] output stalled (%s) -- reopening\n", reason);
            tb_audio_close(a);
            a->audio_reopen_retry_ms = (tb_audio_open(a) != 0) ? t + TB_AUDIO_REOPEN_RETRY_MS : 0;
            return;   /* tb_audio_open() already rebaselined the diag counters */
        }
    }

    /* Low-noise periodic diagnostic, separate cadence from the stall check
     * above (5x slower) so next time this needs measuring there is a number
     * on record instead of only a restart to go on. */
    if (t - a->audio_diag_last_ms >= TB_AUDIO_WATCHDOG_INTERVAL_MS * 5) {
        const uint64_t ticks = atomic_load_explicit(&a->audio_cb_ticks, memory_order_relaxed);
        const double elapsed_s = (double)(t - a->audio_diag_last_ms) / 1000.0;
        const double rate = elapsed_s > 0.0 ? (double)(ticks - a->audio_diag_last_ticks) / elapsed_s : 0.0;
        fprintf(stderr, "[audio] %s cb=%.1f/s\n", rate > 1.0 ? "ok" : "dead", rate);
        a->audio_diag_last_ms = t;
        a->audio_diag_last_ticks = ticks;
    }
}

/* Drive the receiver's master output volume knob (with the system volume HUD).
 * level is clamped to 0.0..1.0. Sets the default output device's scalar volume,
 * preferring the master element and falling back to per-channel when a device
 * has no master volume control. Safe to call from the network/parser thread. */
static void tb_set_system_volume(double level) {
    if (level < 0.0) level = 0.0;
    if (level > 1.0) level = 1.0;
    Float32 vol = (Float32)level;

    AudioObjectPropertyAddress dev_addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &dev_addr, 0, NULL,
                                   &size, &device) != noErr ||
        device == kAudioObjectUnknown) {
        return;
    }

    AudioObjectPropertyAddress vol_addr = {
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain   /* element 0 = master */
    };
    Boolean settable = false;
    if (AudioObjectHasProperty(device, &vol_addr) &&
        AudioObjectIsPropertySettable(device, &vol_addr, &settable) == noErr &&
        settable) {
        AudioObjectSetPropertyData(device, &vol_addr, 0, NULL, sizeof(vol), &vol);
        return;
    }

    /* No master element — set the left/right channels individually. */
    for (UInt32 ch = 1; ch <= 2; ch++) {
        vol_addr.mElement = ch;
        settable = false;
        if (AudioObjectHasProperty(device, &vol_addr) &&
            AudioObjectIsPropertySettable(device, &vol_addr, &settable) == noErr &&
            settable) {
            AudioObjectSetPropertyData(device, &vol_addr, 0, NULL, sizeof(vol), &vol);
        }
    }
}

/* ---- Whole-machine sleep on the sender's full-system-sleep signal ------ */

/* Ask the kernel to sleep THIS machine (the iMac), because the sender's whole
 * Mac is going to sleep, not just its display.
 *
 * Called only for reason == "systemSleep". A display-only sleep must not come
 * here: the receiver's job then is just to stop holding the panel awake and let
 * this machine's own idle timer take it down, which is what the existing
 * SDL_EnableScreenSaver() already does. Sleeping the whole iMac because the
 * MacBook's screen went off would be the feature firing on the wrong signal.
 *
 * IOPMLib.h documents the rule for this call as "caller must be root or the
 * console user". MEASURED on this iMac (iMac20,1, macOS 26.6.2) on 2026-09-19:
 * an unprivileged uid-501 process -- an ssh session, which is not even the GUI
 * session -- got kIOReturnSuccess (0x0) and the machine entered Sleep state
 * ~15 s later, with pmset logging `Sleep Entering Sleep state due to 'Software
 * Sleep pid=<probe>'`. So the receiver, which runs as uid 501 in the Aqua
 * session, needs no privilege escalation and no privileged helper.
 *
 * The call does NOT block: it returned immediately (output file mtime == call
 * time) and powerd's own display-off / dark-wake-linger timers delayed the
 * actual Sleep entry by ~15 s. Safe to call from the packet handler on the
 * event-loop thread.
 *
 * The connect port is opened per call and closed again: this fires at most once
 * per sleep so there is no state worth caching. IOPMFindPowerManagement() is
 * the documented route and performs the user-client open itself. The
 * IOServiceOpen route does NOT work here: IORegistryEntryFromPath() could not
 * resolve IOPMrootDomain on any of the plane strings tried ("IOPower:" and
 * "IOService:", with and without a leading plane name; all returned 0), and
 * there is no kIOPMSleepSystemConnectType constant anywhere in the SDK headers
 * -- only the kPMSleepSystem *selector* in IOPMLibDefs.h. */
static void request_system_sleep(void) {
    io_connect_t pm = IOPMFindPowerManagement(MACH_PORT_NULL);
    if (pm == MACH_PORT_NULL) {
        fprintf(stderr, "[sleep] IOPMFindPowerManagement failed; iMac not put to sleep\n");
        return;
    }
    IOReturn r = IOPMSleepSystem(pm);
    fprintf(stderr, "[sleep] IOPMSleepSystem -> 0x%08x %s\n", (unsigned)r,
            r == kIOReturnSuccess ? "(system sleep requested)"
                                  : "(FAILED; iMac stays awake)");
    fprintf(stderr, "[sleep] sender's Mac is going to sleep; iMac follows. "
                    "Nothing here restarts the receiver afterwards: the LaunchAgent "
                    "runs only at login and this Mac does not log out to sleep, so "
                    "the human presses the power button to wake it. Measured "
                    "2026-09-19: this process SURVIVES that sleep and returns to its "
                    "listen loop, but the display-link TCP session does not -- the "
                    "sender has to dial in again.\n");
    IOServiceClose(pm);
}

/* ---- Callbacks: parser → decoder ------------------------------------- */

/* Arrival time of the packet on_packet is currently handling.
 *
 * on_packet is a parser callback with a fixed signature, so this cannot be an
 * argument. Set by the queue drain, where a packet CAN have waited; left at 0 on
 * the direct parser path, where it cannot have, and read as "now" there. */

/* Defined further down; needed here for the direct-parser path's "now". */

static void on_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct app *a = (struct app *)ud;
    switch (type) {
    case TB_PKT_UI_LANGUAGE:
        {
            char ui_language[16];
            ui_language[0] = '\0';
            extract_json_string_field(payload, len, "\"uiLanguage\"", ui_language, sizeof(ui_language));
            if (ui_language[0] != '\0') {
                snprintf(a->sender_ui_language, sizeof(a->sender_ui_language), "%s", ui_language);
                if (strcmp(a->language_pref, "auto") == 0) {
                    tb_i18n_set_runtime_language(ui_language);
                }
                if (a->client_fd < 0 || !a->have_video_frame) {
                    tb_refresh_idle_localized_strings(a);
                }
            }
        }
        break;
    case TB_PKT_HELLO_RECEIVER:
        extract_json_string_field(payload, len, "\"senderName\"", a->sender_text, sizeof(a->sender_text));
        {
            char ui_language[16];
            ui_language[0] = '\0';
            extract_json_string_field(payload, len, "\"uiLanguage\"", ui_language, sizeof(ui_language));
            if (ui_language[0] != '\0') {
                snprintf(a->sender_ui_language, sizeof(a->sender_ui_language), "%s", ui_language);
                if (strcmp(a->language_pref, "auto") == 0) {
                    tb_i18n_set_runtime_language(ui_language);
                }
            }
        }
        if (a->sender_text[0] == '\0') {
            tb_copy_i18n(a->sender_text, sizeof(a->sender_text), "receiver.status.sender_connected");
        }
        {
            char preset[64];
            char source[64];
            char codec[64];
            int capture_w = 0;
            int capture_h = 0;
            preset[0] = '\0';
            source[0] = '\0';
            codec[0] = '\0';
            extract_json_string_field(payload, len, "\"capturePreset\"", preset, sizeof(preset));
            extract_json_string_field(payload, len, "\"captureSource\"", source, sizeof(source));
            extract_json_string_field(payload, len, "\"codec\"", codec, sizeof(codec));
            (void)extract_json_int_field(payload, len, "\"captureWidth\"", &capture_w);
            (void)extract_json_int_field(payload, len, "\"captureHeight\"", &capture_h);

            tb_set_receiver_mode_requested(a->mode_text, sizeof(a->mode_text), capture_w, capture_h, source, preset, codec);
        }
        {
            char audio_format[8] = {0};
            extract_json_string_field(payload, len, "\"audioFormat\"",
                                      audio_format, sizeof(audio_format));
            a->audio_input_is_s16 = (strcmp(audio_format, "f32") != 0);
            if (a->audio_input_is_s16) {
                fprintf(stderr, "[main] sender sends Int16 audio; converting\n");
            }
        }
        a->session_active = 1;
        fprintf(stderr, "[main] hello from sender\n");
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.sender_connected_profile_sent");
        break;
    case TB_PKT_CREATE_SESSION_ACK:
        a->session_active = 1;
        fprintf(stderr, "[main] sender session ack: %.*s\n", (int)len, (const char *)payload);
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_accepted_waiting_frames");
        break;
    case TB_PKT_PARAM_SETS:
        a->session_active = 1;
        /* tb_dec_set_param_sets is now a no-op if the sets are unchanged,
         * so we don't spam a log line per keyframe. */
        tb_dec_set_param_sets(a->dec, payload, len);
        break;
    case TB_PKT_FRAME:
        a->session_active = 1;
        tb_dec_feed_frame(a->dec, payload, len);
        break;
    case TB_PKT_RAW_FRAME:
        handle_raw_frame(a, payload, len);
        break;
    case TB_PKT_RAW_DPCM:
        handle_raw_dpcm(a, payload, len);
        break;
    case TB_PKT_CURSOR:
        /* Latency of the half we own: off the socket to on the compositor,
         * queue wait included. The sender's clock is on another machine and not
         * synchronised, so this deliberately excludes the network hop rather
         * than pretending to measure it. */
        tb_metal_plane_note_cursor_arrival(g_pkt_recv_ms > 0.0 ? g_pkt_recv_ms
                                                               : now_ms_f());
        {
            int x = 0;
            int y = 0;
            int w = 0;
            int h = 0;
            int visible = 0;
            int type = 0;
            (void)extract_json_int_field(payload, len, "\"x\"", &x);
            (void)extract_json_int_field(payload, len, "\"y\"", &y);
            (void)extract_json_int_field(payload, len, "\"width\"", &w);
            (void)extract_json_int_field(payload, len, "\"height\"", &h);
            (void)extract_json_bool_field(payload, len, "\"visible\"", &visible);
            (void)extract_json_int_field(payload, len, "\"type\"", &type);
            tb_disp_set_cursor(a->disp, x, y, w, h, visible, type);
        }
        break;
    case TB_PKT_BRIGHTNESS:
        {
            double level = 1.0;
            (void)extract_json_double_field(payload, len, "\"level\"", &level);
            tb_disp_set_brightness(a->disp, level);
        }
        break;
    case TB_PKT_DISPLAY_TWEAKS:
        {
            /* Absent fields are left alone rather than defaulted, so the sender
             * can change one without disturbing the other. */
            int night = 0, tone = 0;
            if (extract_json_bool_field(payload, len, "\"nightShift\"", &night)) {
                tb_night_shift_set(night);
            }
            if (extract_json_bool_field(payload, len, "\"trueTone\"", &tone)) {
                tb_true_tone_set(tone);
            }
            int vsync = 0;
            if (extract_json_bool_field(payload, len, "\"vsync\"", &vsync)) {
                tb_metal_plane_set_vsync(vsync);
            }
        }
        break;
    case TB_PKT_CLIPBOARD:
        {
            char text[4096];
            extract_json_string_field(payload, len, "\"text\"", text, sizeof(text));
            tb_receiver_set_clipboard_text(text);
        }
        break;
    case TB_PKT_VOLUME:
        {
            double level = 1.0;
            (void)extract_json_double_field(payload, len, "\"level\"", &level);
            tb_set_system_volume(level);
        }
        break;
    case TB_PKT_AUDIO_FRAME:
        if (a->audio_device != 0) {
            /* The output device is opened as float. Widen an older sender's
             * Int16 rather than reopening the device mid-session. */
            const uint8_t *audio = payload;
            size_t audio_len = len;
            float *widened = NULL;
            if (a->audio_input_is_s16) {
                const size_t samples = len / sizeof(int16_t);
                widened = (float *)malloc(samples * sizeof(float));
                if (!widened) break;
                const int16_t *src = (const int16_t *)payload;
                for (size_t i = 0; i < samples; ++i) {
                    widened[i] = (float)src[i] / AUDIO_INT16_TO_FLOAT;
                }
                audio = (const uint8_t *)widened;
                audio_len = samples * sizeof(float);
            }
            payload = audio;
            len = audio_len;

            SDL_LockAudioDevice(a->audio_device);

            // Cap the backlog so playout stays tight, cushioning network and
            // scheduling jitter without letting delay accumulate.
            const int cap_bytes = AUDIO_BACKLOG_MAX_MS * AUDIO_BYTES_PER_MS;
            if (a->audio_buf_size + len > cap_bytes) {
                int excess = (a->audio_buf_size + len) - cap_bytes;
                a->audio_buf_tail = (a->audio_buf_tail + excess) % AUDIO_BUF_CAP;
                a->audio_buf_size -= excess;
            }

            // Write payload to circular buffer
            if (a->audio_buf_size + (int)len <= AUDIO_BUF_CAP) {
                int first = AUDIO_BUF_CAP - a->audio_buf_head;
                if (first >= (int)len) {
                    memcpy(a->audio_buf + a->audio_buf_head, payload, len);
                } else {
                    memcpy(a->audio_buf + a->audio_buf_head, payload, first);
                    memcpy(a->audio_buf, payload + first, len - first);
                }
                a->audio_buf_head = (a->audio_buf_head + (int)len) % AUDIO_BUF_CAP;
                a->audio_buf_size += (int)len;
            }

            SDL_UnlockAudioDevice(a->audio_device);
            free(widened);
        }
        break;
    case TB_PKT_CURSOR_IMAGE: {
        /* uint16 w, uint16 h, int16 hotX, int16 hotY, then RGBA8 rows. Every
         * field is checked against the actual length: this is the only packet
         * whose payload size is derived from its own header, so a truncated or
         * hostile one would otherwise read past the buffer. */
        if (len < 8) break;
        const uint16_t iw = (uint16_t)(payload[0] | (payload[1] << 8));
        const uint16_t ih = (uint16_t)(payload[2] | (payload[3] << 8));
        const int16_t  hx = (int16_t)(payload[4] | (payload[5] << 8));
        const int16_t  hy = (int16_t)(payload[6] | (payload[7] << 8));
        if (iw == 0 || ih == 0 || iw > 512 || ih > 512) break;
        const size_t need = (size_t)iw * (size_t)ih * 4u;
        if (len - 8 < need) break;
        tb_metal_plane_set_cursor_image(payload + 8, iw, ih, hx, hy);
        break;
    }
    case TB_PKT_INPUT_EVENT:
        tb_receiver_apply_input_event(payload, len);
        break;
    case TB_PKT_INPUT_CONTROL:
        tb_receiver_apply_input_control_mode(a, payload, len);
        break;
    case TB_PKT_HEARTBEAT:
        break;
    case TB_PKT_SENDER_DISPLAY_SLEEP:
        {
            /* Sender-authoritative panel sleep: the sender's screen has gone
             * down (or its whole Mac has), so this panel no longer needs to be
             * held awake for it.
             *
             * ONLY an explicit asleep:true releases the assertion, and only
             * SDL_EnableScreenSaver() releases it -- there is no timer, no
             * missing-packet path and no inference from silence anywhere in
             * this file, deliberately. The failure mode this feature can have
             * is a panel that sleeps while somebody is working, which is far
             * worse than a panel that stays on. So a sender that never sends
             * this, or whose signal stops arriving, keeps today's always-on
             * behaviour; the disconnect path still re-enables the screen saver
             * when the session is torn down.
             *
             * Called on the main thread like every other on_packet case
             * (drain_socket inline, pump_network from the main loop), which is
             * the same thread the connect path asserts on.
             *
             * Two different sleeps arrive on this one packet, and they must do
             * different things (see request_system_sleep above):
             *   reason "displaySleep" -> release the panel assertion ONLY.
             *     macOS then takes the panel down on its own idle timer.
             *   reason "systemSleep"  -> the sender's whole Mac is sleeping, so
             *     this whole iMac sleeps too.
             * An absent or unrecognised reason keeps today's behaviour (panel
             * assertion only), so an older sender cannot make this machine
             * sleep by accident.
             *
             * Sleeping here means this receiver is then asleep with the machine
             * and gets no wake packet: pmset shows the display-sleep/wake
             * packets keep the TCP session alive across a display sleep, but a
             * full system sleep drops it (measured 2026-09-19: the receiver
             * process survived and went back to listening, the sender's session
             * did not). The LaunchAgent only runs at login and sleeping does
             * not log out, so nothing restarts the receiver: the human presses
             * the iMac's power button and the sender dials in again. That is
             * the accepted trade for the iMac following the MacBook to sleep. */
            int asleep = 0;
            if (!extract_json_bool_field(payload, len, "\"asleep\"", &asleep)) break;
            char reason[24];
            reason[0] = '\0';
            extract_json_string_field(payload, len, "\"reason\"", reason, sizeof(reason));
            if (asleep) {
                SDL_EnableScreenSaver();
                fprintf(stderr, "[main] sender display asleep; panel may sleep\n");
                /* Full sleep on ANY asleep:true, not just reason "systemSleep".
                 *
                 * The two reasons exist because the sender can tell which kind
                 * of sleep it is asking for -- but on a real, fast system sleep
                 * the display-sleep notification can fire first (or alone) and
                 * win the sender's own transitions-only guard, so "systemSleep"
                 * sometimes never arrives at all (measured 2026-09-20: a real
                 * `Entering Sleep state due to 'Idle Sleep'` produced only a
                 * displaySleep packet here). Racing to tell the two apart is
                 * not worth it: whatever the reason, nothing is being shown on
                 * this panel while the sender's display is off, so there is no
                 * cost to sleeping the whole machine instead of just the panel
                 * -- the visible result is identical (dark screen) and full
                 * sleep saves more power. If the sender's display comes back
                 * quickly the wake packet never gets here because sleeping
                 * takes the network with it, so this is a deliberate trade: the
                 * human presses the iMac's power button after every full sleep,
                 * same as for a real systemSleep reason. */
                tb_audio_close(a);
                a->audio_reopen_retry_ms = 0;
                a->audio_suspended_for_sleep = 1;
                request_system_sleep();
            } else {
                SDL_DisableScreenSaver();
                fprintf(stderr, "[main] sender display awake; holding panel awake\n");
                /* Sleep was requested but never happened (display came back
                 * first): bring the output back now rather than wait for a
                 * wake notification that will not come. */
                if (a->audio_suspended_for_sleep) {
                    fprintf(stderr, "[audio] sleep did not happen -- reopening\n");
                    a->audio_reopen_retry_ms = (tb_audio_open(a) != 0) ? now_ms() + TB_AUDIO_REOPEN_RETRY_MS : 0;
                }
            }
        }
        break;
    case TB_PKT_TEST_DATA:
        /* Performance test data; discard */
        break;
    case TB_PKT_TEARDOWN:
        fprintf(stderr, "[main] teardown requested by sender\n");
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_closed_by_sender");
        a->close_requested = 1;
        break;
    default:
        fprintf(stderr, "[main] unknown pkt type=0x%02x\n", type);
        break;
    }
}

/* ---- Networking helpers ---------------------------------------------- */

static double now_ms_f(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static int drain_fd(int fd, struct tb_parser *parser) {
    /* Read straight into the parser buffer: at raw 4:4:4 a 5K frame is ~59 MB,
     * so a staging buffer would cost a full extra copy of every frame. */
    const size_t chunk = 1024 * 1024;
    int saw_data = 0;
    for (;;) {
        uint8_t *dst   = NULL;
        size_t   avail = 0;
        if (tb_parser_reserve_space(parser, chunk, &dst, &avail) < 0) return -1;
        ssize_t n = read(fd, dst, avail);
        if (n > 0) {
            saw_data = 1;
            if (tb_parser_commit(parser, (size_t)n) < 0) return -1;
        } else if (n == 0) {
            return -1;  /* peer closed */
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return saw_data;
            perror("[main] read");
            return -1;
        }
    }
}

static int drain_socket(struct app *a) {
    return drain_fd(a->client_fd, &a->parser);
}

static void write_be32(uint8_t *dst, uint32_t value) {
    dst[0] = (uint8_t)((value >> 24) & 0xff);
    dst[1] = (uint8_t)((value >> 16) & 0xff);
    dst[2] = (uint8_t)((value >> 8) & 0xff);
    dst[3] = (uint8_t)(value & 0xff);
}

static int send_all_within(int fd, const uint8_t *buf, size_t len, unsigned budget_ms) {
    /* Bound the EAGAIN retry loop: this runs on the event-loop thread, so an
     * unresponsive reader (half-open peer, saturated link) must not wedge
     * rendering and quit handling forever. 2s of zero progress means the
     * session is effectively dead; give up and let the caller/watchdog
     * tear it down.
     *
     * Optional traffic passes a much smaller budget — see pump_log_shipping. */
    const uint64_t deadline_ms = now_ms() + budget_ms;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n > 0) {
            off += (size_t)n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (now_ms() >= deadline_ms) {
                fprintf(stderr, "[net] send stalled for 2s; dropping write\n");
                return -1;
            }
            usleep(1000);
            continue;
        }
        return -1;
    }
    return 0;
}

static int send_all(int fd, const uint8_t *buf, size_t len) {
    return send_all_within(fd, buf, len, 2000);
}

/* Every packet written to the client socket goes through here.
 *
 * There is more than one writer: the mic callback runs on AVFoundation's
 * capture queue while the main loop sends profiles, input events and shipped
 * log text. send_all() loops over partial writes, so without this lock two
 * writers interleave mid-packet and the sender sees a length field spliced out
 * of somebody else's payload. It reported exactly that —
 * "corrupt inbound stream (invalid packet length 2199163323)" — and dropped the
 * connection. The race was always there; it only became certain once log
 * shipping gave the main loop something to send every frame. */
static pthread_mutex_t g_send_lock = PTHREAD_MUTEX_INITIALIZER;

/* Caller must hold g_send_lock. */
static int tb_send_packet_locked(struct app *a, uint8_t type,
                                 const uint8_t *body, size_t len) {
    uint8_t header[TB_HDR_BYTES];
    write_be32(header, (uint32_t)(1 + len));
    header[4] = type;
    if (send_all(a->client_fd, header, sizeof(header)) < 0) return -1;
    if (len > 0 && send_all(a->client_fd, body, len) < 0) return -1;
    return 0;
}

static int tb_send_packet(struct app *a, uint8_t type,
                          const uint8_t *body, size_t len) {
    if (!a || a->client_fd < 0) return -1;
    pthread_mutex_lock(&g_send_lock);
    const int rc = tb_send_packet_locked(a, type, body, len);
    pthread_mutex_unlock(&g_send_lock);
    return rc;
}

static void tb_receiver_send_input_event(struct app *a,
                                         const char *kind,
                                         int has_dx, int dx,
                                         int has_dy, int dy,
                                         int has_scroll_x, int scroll_x,
                                         int has_scroll_y, int scroll_y,
                                         int has_key_code, uint16_t key_code) {
    if (!a || a->client_fd < 0) return;
    if (strcmp(a->input_control_mode, "receiverMaster") != 0) return;

    char json[256];
    int len = snprintf(json, sizeof(json), "{\"kind\":\"%s\"", kind ? kind : "");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    if (has_dx) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"dx\":%d", dx);
    if (has_dy) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"dy\":%d", dy);
    if (has_scroll_x) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"scrollX\":%d", scroll_x);
    if (has_scroll_y) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"scrollY\":%d", scroll_y);
    if (has_key_code) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"keyCode\":%u", (unsigned int)key_code);
    len += snprintf(json + len, sizeof(json) - (size_t)len, "}");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    uint8_t pkt[4 + 1 + sizeof(json)];
    write_be32(pkt, (uint32_t)(1 + len));
    pkt[4] = TB_PKT_INPUT_EVENT;
    memcpy(pkt + 5, json, (size_t)len);
    a->input_events_sent += 1;
    if (tb_should_log_input_event(a->input_events_sent)) {
        tb_receiver_input_log("[input][receiver->sender] send #%llu kind=%s dx=%d dy=%d sx=%d sy=%d key=%u mode=%s",
                              (unsigned long long)a->input_events_sent,
                              kind ? kind : "?",
                              has_dx ? dx : 0,
                              has_dy ? dy : 0,
                              has_scroll_x ? scroll_x : 0,
                              has_scroll_y ? scroll_y : 0,
                              has_key_code ? (unsigned int)key_code : 0,
                              a->input_control_mode);
    }
    (void)tb_send_packet(a, TB_PKT_INPUT_EVENT, pkt + 5, (size_t)len);
}

static void tb_receiver_send_target_switch(struct app *a, int direction) {
    tb_receiver_send_input_event(a,
                                 direction < 0 ? "switchPrevTarget" : "switchNextTarget",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void tb_receiver_sync_modifier_state(struct app *a,
                                            int command_down,
                                            int shift_down,
                                            int option_down,
                                            int control_down,
                                            int caps_down) {
    if (!a) return;

    struct {
        int *state;
        int desired;
        uint16_t key_code;
    } modifiers[] = {
        { &a->sent_command_down, command_down, 55 },
        { &a->sent_shift_down,   shift_down,   56 },
        { &a->sent_option_down,  option_down,  58 },
        { &a->sent_control_down, control_down, 59 },
        { &a->sent_caps_down,    caps_down,    57 }
    };

    for (size_t i = 0; i < sizeof(modifiers) / sizeof(modifiers[0]); i++) {
        if (*modifiers[i].state == modifiers[i].desired) continue;
        tb_receiver_send_input_event(a,
                                     modifiers[i].desired ? "keyDown" : "keyUp",
                                     0, 0, 0, 0, 0, 0, 0, 0, 1, modifiers[i].key_code);
        *modifiers[i].state = modifiers[i].desired;
    }
}

static void tb_receiver_send_space_switch(struct app *a, int direction) {
    tb_receiver_send_input_event(a,
                                 direction < 0 ? "switchPrevSpace" : "switchNextSpace",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void tb_receiver_space_switch_callback(int direction, void *context) {
    struct app *a = (struct app *)context;
    if (!a || strcmp(a->input_control_mode, "receiverMaster") != 0 || a->client_fd < 0) return;
    tb_receiver_send_space_switch(a, direction);
}

static void tb_receiver_send_deactivate_control(struct app *a) {
    tb_receiver_send_input_event(a,
                                 "deactivateInputControl",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static CGEventRef tb_receiver_input_tap_callback(CGEventTapProxy proxy,
                                                 CGEventType type,
                                                 CGEventRef event,
                                                 void *user_info) {
    (void)proxy;
    struct app *a = (struct app *)user_info;
    if (!a) return event;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (a->input_tap) CGEventTapEnable(a->input_tap, true);
        return event;
    }

    if (strcmp(a->input_control_mode, "receiverMaster") != 0) return event;

    /* Only drive the sender while the user is actually on the shared display
     * window's Space. The global tap also sees events from other receiver
     * Spaces; forwarding those would make the sender's cursor jump while the
     * user is doing local work on the receiver. When the window is on a
     * different Space, pass the event through untouched and forward nothing. */
    if (!tb_disp_window_on_active_space(a->disp)) return event;

    int should_consume = 0;

    switch (type) {
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDragged: {
        int dx = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
        int dy = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
        CGPoint location = CGEventGetLocation(event);
        CGRect bounds = CGDisplayBounds(CGMainDisplayID());
        uint64_t now = now_ms();
        if (now - a->last_target_switch_ms > 450) {
            if (location.x <= CGRectGetMinX(bounds) + 2.0 && dx < 0) {
                a->last_target_switch_ms = now;
                tb_receiver_send_target_switch(a, -1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
            if (location.x >= CGRectGetMaxX(bounds) - 2.0 && dx > 0) {
                a->last_target_switch_ms = now;
                tb_receiver_send_target_switch(a, 1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        const char *kind = "move";
        if (type == kCGEventLeftMouseDragged) kind = "leftDrag";
        else if (type == kCGEventRightMouseDragged) kind = "rightDrag";
        else if (type == kCGEventOtherMouseDragged) kind = "otherDrag";
        tb_receiver_send_input_event(a, kind, 1, dx, 1, dy, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventLeftMouseDown:
        tb_receiver_send_input_event(a, "leftDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventLeftMouseUp:
        tb_receiver_send_input_event(a, "leftUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseDown:
        tb_receiver_send_input_event(a, "rightDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseUp:
        tb_receiver_send_input_event(a, "rightUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseDown:
        tb_receiver_send_input_event(a, "otherDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseUp:
        tb_receiver_send_input_event(a, "otherUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventScrollWheel: {
        int sx = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
        int sy = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
        int point_sx = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
        int point_sy = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
        int is_continuous = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        uint64_t now = now_ms();
        if ((effective_flags & kCGEventFlagMaskAlternate) &&
            (llabs((long long)point_sx) > llabs((long long)point_sy) * 2 || llabs((long long)sx) > llabs((long long)sy) * 2) &&
            now - a->last_space_switch_ms > 300) {
            int direction = 0;
            if (point_sx != 0) direction = point_sx > 0 ? 1 : -1;
            else if (sx != 0) direction = sx > 0 ? 1 : -1;
            if (direction != 0) {
                a->last_space_switch_ms = now;
                a->space_gesture_accum_x = 0;
                tb_receiver_send_space_switch(a, direction);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        if (is_continuous &&
            (point_sx != 0 || point_sy != 0) &&
            llabs((long long)point_sx) > llabs((long long)point_sy) * 2) {
            if (now - a->last_space_gesture_ms > 250) {
                a->space_gesture_accum_x = 0;
            }
            a->last_space_gesture_ms = now;
            a->space_gesture_accum_x += point_sx;
            if (llabs((long long)a->space_gesture_accum_x) >= 45 &&
                now - a->last_space_switch_ms > 450) {
                a->last_space_switch_ms = now;
                tb_receiver_send_space_switch(a, a->space_gesture_accum_x > 0 ? 1 : -1);
                a->space_gesture_accum_x = 0;
            }
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if (now - a->last_space_gesture_ms > 250) {
            a->space_gesture_accum_x = 0;
        }
        tb_receiver_send_input_event(a, "scroll", 0, 0, 0, 0, 1, sx, 1, sy, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventKeyDown: {
        uint16_t key_code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        if ((flags & kCGEventFlagMaskControl) &&
            (flags & kCGEventFlagMaskAlternate) &&
            (flags & kCGEventFlagMaskCommand) &&
            key_code == 40) {
            tb_receiver_send_deactivate_control(a);
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if ((effective_flags & kCGEventFlagMaskControl) && (effective_flags & kCGEventFlagMaskCommand)) {
            if (key_code == 123) {
                tb_receiver_send_target_switch(a, -1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
            if (key_code == 124) {
                tb_receiver_send_target_switch(a, 1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        tb_receiver_send_input_event(a, "keyDown", 0, 0, 0, 0, 0, 0, 0, 0, 1, key_code);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventKeyUp:
    {
        uint16_t key_code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        if ((flags & kCGEventFlagMaskControl) &&
            (flags & kCGEventFlagMaskAlternate) &&
            (flags & kCGEventFlagMaskCommand) &&
            key_code == 40) {
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if ((effective_flags & kCGEventFlagMaskControl) && (effective_flags & kCGEventFlagMaskCommand) &&
            (key_code == 123 || key_code == 124)) {
            should_consume = a->input_tap_consumes_events;
            break;
        }
        tb_receiver_send_input_event(a, "keyUp", 0, 0, 0, 0, 0, 0, 0, 0, 1, key_code);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventFlagsChanged: {
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        should_consume = a->input_tap_consumes_events;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        break;
    }
    default:
        break;
    }

    return should_consume ? NULL : event;
}

static void tb_receiver_stop_input_tap(struct app *a) {
    if (!a) return;
    if (a->input_tap_source) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), a->input_tap_source, kCFRunLoopCommonModes);
        CFRelease(a->input_tap_source);
        a->input_tap_source = NULL;
    }
    if (a->input_tap) {
        CFMachPortInvalidate(a->input_tap);
        CFRelease(a->input_tap);
        a->input_tap = NULL;
    }
    a->input_tap_consumes_events = 0;
}

static void tb_receiver_start_input_tap(struct app *a) {
    if (!a || a->input_tap) return;

    if (!tb_receiver_input_monitoring_trusted()) {
        return;
    }

    const int can_consume = tb_receiver_accessibility_trusted() ? 1 : 0;
    CGEventTapOptions tap_options = can_consume ? kCGEventTapOptionDefault : kCGEventTapOptionListenOnly;

    CGEventMask mask =
        CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged) |
        CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventOtherMouseDown) |
        CGEventMaskBit(kCGEventOtherMouseUp) |
        CGEventMaskBit(kCGEventScrollWheel) |
        CGEventMaskBit(kCGEventKeyDown) |
        CGEventMaskBit(kCGEventKeyUp) |
        CGEventMaskBit(kCGEventFlagsChanged);

    a->input_tap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        tap_options,
        mask,
        tb_receiver_input_tap_callback,
        a
    );
    if (!a->input_tap) {
        tb_receiver_input_log("[input] global event tap unavailable; will fall back to SDL window input");
        return;
    }

    a->input_tap_source = CFMachPortCreateRunLoopSource(NULL, a->input_tap, 0);
    if (!a->input_tap_source) {
        tb_receiver_stop_input_tap(a);
        tb_receiver_input_log("[input] failed to create runloop source for event tap; using SDL fallback");
        return;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), a->input_tap_source, kCFRunLoopCommonModes);
    CGEventTapEnable(a->input_tap, true);
    a->input_tap_consumes_events = can_consume;
    tb_receiver_input_log("[input] global event tap enabled for receiverMaster mode (consume=%s)",
                          can_consume ? "true" : "false");
}

static void tb_receiver_refresh_input_capture(struct app *a) {
    if (!a) return;
    if (strcmp(a->input_control_mode, "receiverMaster") == 0 && a->client_fd >= 0) {
        const int wants_global_tap = tb_receiver_input_monitoring_trusted() ? 1 : 0;
        const int wants_consume = tb_receiver_accessibility_trusted() ? 1 : 0;
        if (a->input_tap && (!wants_global_tap || a->input_tap_consumes_events != wants_consume)) {
            tb_receiver_stop_input_tap(a);
        }
        tb_receiver_start_input_tap(a);
        tb_disp_set_input_intercept_active(a->disp, 1);
        tb_disp_set_input_capture_active(a->disp, a->input_tap == NULL ? 1 : 0);
        tb_gesture_bridge_set_active(1);
        tb_receiver_input_log("[input] receiverMaster capture path = %s",
                              a->input_tap ? "global-tap" : "sdl-fallback");
    } else {
        tb_receiver_stop_input_tap(a);
        tb_disp_set_input_intercept_active(a->disp, 0);
        tb_disp_set_input_capture_active(a->disp, 0);
        tb_gesture_bridge_set_active(0);
        tb_receiver_input_log("[input] input capture disabled");
    }
}


/* Report Night Shift / True Tone back to the sender when they change, so its
 * menu reflects the panel's real state rather than only what it last asked for. */
static void tb_receiver_send_display_tweaks_if_changed(struct app *a) {
    if (a->client_fd < 0) return;

    const int night = tb_night_shift_supported() ? tb_night_shift_enabled() : 0;
    const int tone  = tb_true_tone_supported() ? tb_true_tone_enabled() : 0;
    if (night == a->reported_night_shift && tone == a->reported_true_tone) return;

    a->reported_night_shift = night;
    a->reported_true_tone = tone;

    char json[192];
    int len = snprintf(json, sizeof(json),
                       "{\"nightShift\":%s,\"trueTone\":%s}",
                       night ? "true" : "false",
                       tone ? "true" : "false");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    (void)tb_send_packet(a, TB_PKT_DISPLAY_TWEAKS, (const uint8_t *)json, (size_t)len);
}


/* Mic frames come from AVFoundation's capture queue, not the main loop, so this
 * only touches the socket. send_all() on a non-blocking fd may drop under
 * pressure, which for live audio is the right trade — better a gap than a
 * growing backlog of stale sound. */
static struct app *g_mic_app = NULL;

static void tb_mic_frame_cb(const uint8_t *pcm, size_t bytes, void *user_data) {
    struct app *a = (struct app *)user_data;
    if (!a || a->client_fd < 0 || bytes == 0) return;
    /* Cap per packet so one oversized buffer cannot stall the link. */
    const size_t kMax = 8192;
    while (bytes > 0) {
        const size_t chunk = bytes > kMax ? kMax : bytes;
        if (tb_send_packet(a, TB_PKT_MIC_FRAME, pcm, chunk) < 0) return;
        pcm += chunk;
        bytes -= chunk;
    }
}

static void tb_mic_start_if_possible(struct app *a) {
    if (!tb_mic_capture_available()) return;
    g_mic_app = a;
    if (tb_mic_capture_start(tb_mic_frame_cb, a) != 0) {
        /* Permission not granted yet; the prompt has been raised and the next
         * session will retry. */
        fprintf(stderr, "[mic] not started (microphone permission pending)\n");
    } else {
        fprintf(stderr, "[mic] capturing and streaming to sender\n");
    }
}

static void send_receiver_info(struct app *a) {
    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) < 0) return;

    /* Always advertise the intended iMac target panel, not the transient
     * SDL window/debug drawable size. Using the drawable here breaks the
     * sender's virtual display creation path when running windowed or on
     * scaled desktops because macOS rejects a HiDPI mode larger than the
     * advertised backing panel. */
    const uint32_t panel_w = 5120;
    const uint32_t panel_h = 2880;
    const uint32_t mode_w = 2560;
    const uint32_t mode_h = 1440;
    const uint32_t capture_w = 2560;
    const uint32_t capture_h = 1440;

    char escaped_name[256];
    size_t out = 0;
    for (size_t i = 0; info.name[i] != '\0' && out + 2 < sizeof(escaped_name); i++) {
        unsigned char c = (unsigned char)info.name[i];
        if (c == '"' || c == '\\') {
            escaped_name[out++] = '\\';
            escaped_name[out++] = (char)c;
        } else if (c >= 0x20) {
            escaped_name[out++] = (char)c;
        }
    }
    escaped_name[out] = '\0';

    char json[1024];
    int json_len = snprintf(
        json,
        sizeof(json),
        "{\"receiverName\":\"%s\",\"panelWidth\":%u,\"panelHeight\":%u,"
        "\"modeWidth\":%u,\"modeHeight\":%u,\"refreshRate\":60,"
        "\"hiDPI\":true,\"captureWidth\":%u,\"captureHeight\":%u,"
        "\"supportsHEVCDecode\":%s,\"supportsRawNV12\":true,\"supportsFloat32Audio\":true,\"supportsDPCM\":%s,\"inputMonitoringTrusted\":%s,\"accessibilityTrusted\":%s,"
        "\"supportsNightShift\":%s,\"supportsTrueTone\":%s}",
        escaped_name,
        panel_w,
        panel_h,
        mode_w,
        mode_h,
        capture_w,
        capture_h,
        tb_dec_supports_hevc_hwdecode() ? "true" : "false",
        tb_disp_supports_dpcm() ? "true" : "false",
        tb_receiver_input_monitoring_trusted() ? "true" : "false",
        tb_receiver_accessibility_trusted() ? "true" : "false",
        tb_night_shift_supported() ? "true" : "false",
        tb_true_tone_supported() ? "true" : "false");
    if (json_len <= 0 || (size_t)json_len >= sizeof(json)) return;

    const size_t packet_len = 4 + 1 + (size_t)json_len;
    uint8_t *pkt = (uint8_t *)calloc(1, packet_len);
    if (!pkt) return;

    write_be32(pkt, (uint32_t)(1 + json_len));
    pkt[4] = TB_PKT_DISPLAY_PROFILE;
    memcpy(pkt + 5, json, (size_t)json_len);

    if (tb_send_packet(a, TB_PKT_DISPLAY_PROFILE, pkt + 5, (size_t)json_len) == 0) {
        fprintf(stderr,
                "[main] sent display profile: panel=%ux%u mode=%ux%u hidpi name=%s\n",
                panel_w, panel_h, mode_w, mode_h, info.name);
    }
    free(pkt);
}


/* ---- threaded link readers --------------------------------------------- */

/* Runs on a reader thread. Frames go to the newest-wins mailbox; everything
 * else is copied into a queue so the main thread can run the existing
 * handlers unchanged. */
static void reader_on_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct tb_link_reader *r = (struct tb_link_reader *)ud;
    struct app *a = r->app;

    if (type == TB_PKT_RAW_FRAME ||
        type == TB_PKT_RAW_DPCM) {
        /* Keep this packet without copying it: ask the parser to yield its
         * buffer. The `payload` pointer stays valid inside that buffer, which
         * the reader loop collects and publishes right after commit returns. */
        r->pending_payload = payload;
        r->pending_len     = len;
        r->pending_type    = type;
        tb_parser_hold_current(&r->parser);
        return;
    }

    pthread_mutex_lock(&a->net_lock);
    if (a->ctrl_count < TB_CTRL_QUEUE_MAX) {
        uint8_t *copy = (uint8_t *)malloc(len ? len + 1 : 1);
        if (copy) {
            if (len) memcpy(copy, payload, len);
            copy[len] = '\0';   /* preserve on_packet's NUL-sentinel guarantee */
            int slot = (a->ctrl_head + a->ctrl_count) % TB_CTRL_QUEUE_MAX;
            a->ctrl_q[slot].type    = type;
            a->ctrl_q[slot].payload = copy;
            a->ctrl_q[slot].len     = len;
            a->ctrl_q[slot].recv_ms = now_ms_f();
            a->ctrl_count++;
        }
    }
    pthread_mutex_unlock(&a->net_lock);
}

static void *link_reader_main(void *ud) {
    struct tb_link_reader *r = (struct tb_link_reader *)ud;
    struct app *a = r->app;

    while (!r->stop) {
        struct pollfd pfd;
        pfd.fd = r->fd; pfd.events = POLLIN; pfd.revents = 0;
        int pr = poll(&pfd, 1, 20);   /* bounded so `stop` is noticed promptly */
        if (pr < 0) {
            if (errno == EINTR) continue;
            r->ended = 1; return NULL;
        }
        if (pr == 0) continue;

        for (;;) {
            uint8_t *dst = NULL;
            size_t   avail = 0;
            if (tb_parser_reserve_space(&r->parser, 1024 * 1024, &dst, &avail) < 0) {
                r->ended = 1; return NULL;
            }
            double rd0 = now_ms_f();
            ssize_t n = read(r->fd, dst, avail);
            tb_health_note_read(now_ms_f() - rd0);
            if (n > 0) {
                pthread_mutex_lock(&a->net_lock);
                a->reader_recv_ms = now_ms();
                pthread_mutex_unlock(&a->net_lock);
                if (tb_parser_commit(&r->parser, (size_t)n) < 0) { r->ended = 1; return NULL; }
                if (r->pending_payload) {
                    size_t held_cap = 0;
                    uint8_t *held = tb_parser_take_held(&r->parser, &held_cap);
                    if (held) {
                        pthread_mutex_lock(&a->net_lock);
                        /* Never block here. This thread is the only one draining
                         * the socket, so anything it waits for it also stops
                         * receiving — which is precisely how the old 100 ms wait
                         * turned a busy moment into a wedged session.
                         *
                         * The two packet kinds still mean different things:
                         *
                         * A whole frame is a complete image, so it supersedes
                         * everything queued — including bands of a frame that
                         * will now never be finished. Keeping at most one also
                         * stops the queue adding latency on the unsliced path,
                         * where newest-wins has always been correct.
                         *
                         * A band or a damage rect is an INCREMENT: discarding it
                         * loses those pixels for good. Bands were briefly filed
                         * with the whole frames when slicing was added and each
                         * overwrote the last, presenting 4-40% of frames with
                         * strips of the previous one. So they queue, and only
                         * when the queue is genuinely full is the arriving one
                         * dropped and counted — the sender's ~1s resync repairs
                         * it, exactly as the old timeout path did, but without
                         * stalling the socket to get there. */
                        // A whole frame supersedes anything queued; a BAND is an
                        // increment, and discarding one loses those pixels for good.
                        const int is_increment =
                            0;   /* slicing removed: no partial-frame gate */

                        if (!is_increment) {
                            while (a->vq_count > 0) {
                                struct tb_video_slot *old =
                                    &a->vq[(a->vq_head + a->vq_count - 1) % TB_VIDEO_QUEUE];
                                if (a->pool_n < TB_VIDEO_POOL) {
                                    a->pool_buf[a->pool_n] = old->buf;
                                    a->pool_cap[a->pool_n] = old->cap;
                                    a->pool_n++;
                                } else {
                                    free(old->buf);
                                }
                                old->buf = NULL;
                                a->vq_count--;
                                a->frames_dropped++;
                            }
                        }

                        if (a->vq_count >= TB_VIDEO_QUEUE) {
                            /* Full, and this one is an increment (a whole frame
                             * just cleared the queue above). Give the buffer
                             * back rather than leak it. */
                            a->vq_overflow++;
                            if (a->pool_n < TB_VIDEO_POOL) {
                                a->pool_buf[a->pool_n] = held;
                                a->pool_cap[a->pool_n] = held_cap;
                                a->pool_n++;
                            } else {
                                free(held);
                            }
                        } else {
                            struct tb_video_slot *slot =
                                &a->vq[(a->vq_head + a->vq_count) % TB_VIDEO_QUEUE];
                            slot->recv_ms = now_ms_f();
                            slot->buf     = held;
                            slot->cap     = held_cap;
                            slot->payload = r->pending_payload;
                            slot->len     = r->pending_len;
                            slot->type    = r->pending_type;
                            a->vq_count++;
                        }
                        /* Take a recycled buffer back for the next frame. */
                        if (a->pool_n > 0) {
                            a->pool_n--;
                            tb_parser_set_spare(&r->parser,
                                                a->pool_buf[a->pool_n],
                                                a->pool_cap[a->pool_n]);
                            a->pool_buf[a->pool_n] = NULL;
                            a->pool_cap[a->pool_n] = 0;
                        }
                        pthread_mutex_unlock(&a->net_lock);
                    }
                    r->pending_payload = NULL;
                    r->pending_len = 0;
                }
            } else if (n == 0) {
                r->ended = 1; return NULL;      /* peer closed */
            } else {
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                if (errno == EINTR) continue;
                r->ended = 1; return NULL;
            }
        }
    }
    return NULL;
}

static int link_reader_start(struct tb_link_reader *r, struct app *a, int fd) {
    memset(r, 0, sizeof(*r));
    r->app = a; r->fd = fd;
    tb_parser_init(&r->parser, reader_on_packet, r);
    if (pthread_create(&r->thread, NULL, link_reader_main, r) != 0) {
        fprintf(stderr, "[main] reader thread create failed: %s\n", strerror(errno));
        tb_parser_free(&r->parser);
        return -1;
    }
    r->active = 1;
    return 0;
}

static void link_reader_stop(struct tb_link_reader *r) {
    if (!r || !r->active) return;
    r->stop = 1;
    pthread_join(r->thread, NULL);
    tb_parser_free(&r->parser);
    r->active = 0;
}

/* Ship whatever stderr has produced since the last pass.
 *
 * On the main thread on purpose: the mic callback is already an off-thread
 * writer to this fd, and a second one would let two partial packets interleave
 * on the same socket. Bounded per call so a burst of logging cannot displace
 * the frame this loop exists to render — the rest waits for the next pass. */
/* Shipping the log must never cost a frame.
 *
 * The first version ran every main-loop pass and used the ordinary two-second
 * stall budget, which created a feedback loop that collapsed the stream to
 * 7 fps on fullscreen video: a saturated sender stops reading upstream, the
 * receiver's send buffer fills, the render loop blocks inside send_all(), so it
 * stops reading frames, so the sender's writes never complete, so its in-flight
 * budget pins (13/12 observed) and it drops nearly every frame (96 in one
 * window). The receiver looked 90% idle throughout because it was starved, not
 * busy.
 *
 * Three limits, all of them about never blocking the render loop:
 *   - at most one 8 KB packet every 200 ms, so ~40 KB/s, far too little to fill
 *     a socket buffer even when the link is busy;
 *   - trylock, so a mic write in progress defers us instead of queueing;
 *   - a 15 ms stall budget instead of 2000, so a full buffer costs at most part
 *     of one frame.
 * Anything not sent stays in the ring for the next pass, and the ring already
 * reports what it had to drop. */
static void pump_log_shipping(struct app *a) {
    if (!a || a->client_fd < 0) return;

    static uint64_t next_ship_ms = 0;
    const uint64_t now = now_ms();
    if (now < next_ship_ms) return;

    /* Take the lock BEFORE draining. Draining removes bytes from the ring, so
     * discovering afterwards that the socket is busy would throw them away. */
    if (pthread_mutex_trylock(&g_send_lock) != 0) return;

    uint8_t buf[8192];
    const size_t n = tb_logship_drain(buf, sizeof(buf));
    if (n > 0) {
        uint8_t header[TB_HDR_BYTES];
        write_be32(header, (uint32_t)(1 + n));
        header[4] = TB_PKT_LOG;
        /* Header and body share the budget. Giving up between them would leave
         * a partial packet and corrupt the stream, so the body is only attempted
         * once the header is fully out, and both use the same short budget. */
        if (send_all_within(a->client_fd, header, sizeof(header), 15) == 0) {
            (void)send_all_within(a->client_fd, buf, n, 15);
        }
    }

    pthread_mutex_unlock(&g_send_lock);
    next_ship_ms = now + 200;
}

/* Main thread: run queued control packets, then render at most one frame (the
 * newest). Returns non-zero if any work was done. */
static int pump_network(struct app *a) {
    int worked = 0;

    pump_log_shipping(a);

    for (;;) {
        struct tb_ctrl_msg msg;
        pthread_mutex_lock(&a->net_lock);
        if (a->ctrl_count == 0) { pthread_mutex_unlock(&a->net_lock); break; }
        msg = a->ctrl_q[a->ctrl_head];
        a->ctrl_head = (a->ctrl_head + 1) % TB_CTRL_QUEUE_MAX;
        a->ctrl_count--;
        pthread_mutex_unlock(&a->net_lock);

        g_pkt_recv_ms = msg.recv_ms;
        on_packet(msg.type, msg.payload, msg.len, a);
        g_pkt_recv_ms = 0.0;
        free(msg.payload);
        worked = 1;
    }

    pthread_mutex_lock(&a->net_lock);
    if (a->reader_recv_ms > a->last_recv_ms) a->last_recv_ms = a->reader_recv_ms;
    /* Snapshot the depth and drain exactly that many. Taking one per pass was
     * the other half of the stall: a frame is four bands, so one-per-iteration
     * capped the receiver at a quarter of the loop rate no matter how idle it
     * was. Bounding to the snapshot rather than looping until empty keeps a
     * flood from starving input and quit handling. */
    int pending = a->vq_count;
    pthread_mutex_unlock(&a->net_lock);

    while (pending-- > 0) {
        uint8_t       *owned = NULL;
        size_t         owned_cap = 0;
        const uint8_t *payload = NULL;
        size_t         plen = 0;
        uint8_t        ptype = TB_PKT_RAW_FRAME;

        /* Pacing gate: hold a frame's LAST band until its capture time comes
         * round. Earlier bands decode on arrival, so only the moment of
         * presentation moves and the GPU work still spreads across the frame.
         *
         * Everything here is guarded so it can only ever be a small
         * improvement, never a new stall -- a previous pacing attempt made
         * playback worse and had to be reverted:
         *   - a backed-up queue skips pacing entirely and catches up;
         *   - a frame held too long presents anyway, so a bad clock estimate
         *     costs one late frame rather than the stream;
         *   - TB_PACE=0 turns it off without a rebuild.
         */
        if (a->pace_enabled) {
            pthread_mutex_lock(&a->net_lock);
            const int depth = a->vq_count;
            const struct tb_video_slot *head = depth > 0 ? &a->vq[a->vq_head] : NULL;
            const int gate = 0;   /* slicing removed */
            uint64_t capture_ns = 0;
            int is_last = 0;
            if (gate) {
                const uint8_t *h = head->payload;
                capture_ns = ((uint64_t)be32(h) << 32) | be32(h + 4);
                const uint16_t index = (uint16_t)((h[24] << 8) | h[25]);
                const uint16_t count = (uint16_t)((h[26] << 8) | h[27]);
                is_last = (count > 0 && index + 1 == count);
            }
            pthread_mutex_unlock(&a->net_lock);

            if (gate && is_last && capture_ns > 0) {
                const uint64_t now_ns = now_ms() * 1000000ull;
                const uint64_t delta = (now_ns > capture_ns) ? now_ns - capture_ns : 0;
                if (a->pace_min_ns == 0 || delta < a->pace_min_ns) a->pace_min_ns = delta;
                if (now_ms() >= a->pace_win_end_ms) {
                    a->pace_offset_ns = a->pace_min_ns;
                    a->pace_min_ns = 0;
                    a->pace_win_end_ms = now_ms() + 2000;
                }
                if (a->pace_offset_ns > 0) {
                    const uint64_t due = capture_ns + a->pace_offset_ns + TB_PACE_LEAD_NS;
                    if (now_ns < due) {
                        if (a->pace_held_since == 0) a->pace_held_since = now_ms();
                        if (now_ms() - a->pace_held_since < TB_PACE_MAX_HOLD_MS) break;
                    }
                }
            }
            a->pace_held_since = 0;
        }

        pthread_mutex_lock(&a->net_lock);
        if (a->vq_count > 0) {
            struct tb_video_slot *slot = &a->vq[a->vq_head];
            g_pkt_recv_ms = slot->recv_ms;
            owned     = slot->buf;
            owned_cap = slot->cap;
            payload   = slot->payload;
            plen      = slot->len;
            ptype     = slot->type;
            slot->buf = NULL;
            a->vq_head = (a->vq_head + 1) % TB_VIDEO_QUEUE;
            a->vq_count--;
        }
        pthread_mutex_unlock(&a->net_lock);
        if (!owned) break;

        /* Frames bypass on_packet, so mark the session live here — otherwise
         * the fullscreen gate never opens. */
        a->session_active = 1;
        if (ptype == TB_PKT_RAW_DPCM)           handle_raw_dpcm(a, payload, plen);
        else                              handle_raw_frame(a, payload, plen);
        worked = 1;

        /* Return the buffer for a reader to reuse; only free if the pool is
         * full, so the steady state never allocates. */
        pthread_mutex_lock(&a->net_lock);
        if (a->pool_n < TB_VIDEO_POOL) {
            a->pool_buf[a->pool_n] = owned;
            a->pool_cap[a->pool_n] = owned_cap;
            a->pool_n++;
            owned = NULL;
        }
        pthread_mutex_unlock(&a->net_lock);
        free(owned);   /* no-op when pooled */
    }
    return worked;
}

static void drop_pending_network(struct app *a) {
    pthread_mutex_lock(&a->net_lock);
    while (a->ctrl_count > 0) {
        free(a->ctrl_q[a->ctrl_head].payload);
        a->ctrl_head = (a->ctrl_head + 1) % TB_CTRL_QUEUE_MAX;
        a->ctrl_count--;
    }
    while (a->vq_count > 0) {
        struct tb_video_slot *slot = &a->vq[a->vq_head];
        free(slot->buf);
        slot->buf = NULL;
        a->vq_head = (a->vq_head + 1) % TB_VIDEO_QUEUE;
        a->vq_count--;
    }
    a->vq_head = 0;
    for (int i = 0; i < a->pool_n; ++i) { free(a->pool_buf[i]); a->pool_buf[i] = NULL; }
    a->pool_n = 0;
    pthread_mutex_unlock(&a->net_lock);
}

static void close_client(struct app *a) {
    tb_health_session_end();
    tb_mic_capture_stop();
    g_mic_app = NULL;
    link_reader_stop(a->reader1);
    drop_pending_network(a);
    if (a->client_fd >= 0) close(a->client_fd);
    a->client_fd = -1;
    a->session_active = 0;
    a->close_requested = 0;
    a->have_video_frame = 0;
    snprintf(a->input_control_mode, sizeof(a->input_control_mode), "off");
    SDL_EnableScreenSaver();
    tb_receiver_refresh_input_capture(a);
    tb_disp_set_connection_state(a->disp, 0);
    /* Take the video layer down with the session.
     *
     * The Metal plane is layered OVER the SDL window and holds the last frame it
     * drew. Teardown left it visible, so the idle screen was rendered underneath
     * a stale frame that never went away: the receiver looked frozen, and the
     * only way out was killing it. Everything else here was already reset -- the
     * decoder, the parser, the audio ring -- but the thing actually on screen
     * was not.
     *
     * set_hidden(1) releases the plane outright (it calls
     * tb_metal_plane_shutdown), and the render path re-creates it lazily on the
     * next session's first frame -- display.c already guards every render with
     * `if (!tb_metal_plane_available()) tb_metal_plane_init(d->win)`. There is no
     * set_hidden(0) to pair with this, and none is needed. */
    tb_metal_plane_set_hidden(1);
    tb_disp_set_cursor(a->disp, 0, 0, 1, 1, 0, 0);
    tb_refresh_idle_localized_strings(a);
    a->last_clipboard_text[0] = '\0';
    tb_parser_free(&a->parser);
    tb_parser_init(&a->parser, on_packet, a);
    tb_dec_reset(a->dec);   /* fresh decoder for next session */
    /* Audio output only runs with a client attached: actually close the
     * device here rather than pausing it. SDL2's CoreAudio backend (checked
     * against SDL 2.32.10's src/audio/coreaudio/SDL_coreaudio.m) implements
     * output via AudioQueue and never assigns impl->PauseDevice, so
     * SDL_PauseAudioDevice() only flips an atomic the AudioQueue's own
     * callback checks before writing silence (outputCallback()) -- the
     * AudioQueue (and the CoreAudio IO underneath it) keeps running either
     * way. COREAUDIO_CloseDevice() is the only path that calls
     * AudioQueueStop()+AudioQueueDispose(), which is what actually stops the
     * IO and lets coreaudiod drop its PreventUserIdleSystemSleep assertion --
     * measured on the iMac holding that assertion for a receiver's entire
     * 49h+ idle runtime, with no client ever attached, because the device
     * was left open (just unpaused and silent). tb_audio_close() also resets
     * audio_device to 0, so TB_PKT_AUDIO_FRAME's `if (a->audio_device != 0)`
     * guard (on_packet()) safely no-ops for frames that arrive before the
     * next session opens it again; the ring-buffer reset that used to live
     * here is now redundant with tb_audio_open()'s own reset on next
     * connect. */
    tb_audio_close(a);
    a->audio_reopen_retry_ms = 0;   /* nothing to retry while idle */
    fprintf(stderr, "[main] client disconnected\n");
}

/* Build the display string for the host/IP line of the status screen.
 * have_ip: non-zero if ip_fallback is a real IP, zero if no IP is available.
 * Called once at startup (and when the IP changes) to cache the result in
 * a.display_host — do NOT call gethostname() in the render loop. */
static void build_display_host(char *buf, size_t bufsz, const char *ip_fallback, int have_ip) {
    if (!buf || bufsz == 0) return;
    char host[96] = {0};
    if (gethostname(host, sizeof(host)) == 0 && host[0] != '\0' && strcmp(host, "localhost") != 0) {
        char short_host[96] = {0};
        size_t i = 0;
        for (; host[i] != '\0' && host[i] != '.' && i + 1 < sizeof(short_host); i++) {
            short_host[i] = host[i];
        }
        short_host[i] = '\0';
        if (short_host[0] != '\0') {
            if (have_ip && ip_fallback && ip_fallback[0] != '\0') {
                /* ADDRESS FIRST. The person reading this screen is about to type
                 * the address into the sender; the Bonjour hostname is noise in
                 * front of it. It used to read "c188-149-147-188 (10.0.1.2)",
                 * which buries the only actionable string on the display. */
                snprintf(buf, bufsz, "%s", ip_fallback);
            } else {
                snprintf(buf, bufsz, "%s", short_host);
            }
            return;
        }
    }
    snprintf(buf, bufsz, "%s", (have_ip && ip_fallback && ip_fallback[0] != '\0')
             ? ip_fallback : tb_i18n_get("receiver.network.not_detected"));
}

/* ---- Main ------------------------------------------------------------ */

int main(int argc, char **argv) {
    int fullscreen = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--windowed") == 0) fullscreen = 0;
    }

    char startup_language_pref[8];
    tb_receiver_load_language_preference(startup_language_pref, sizeof(startup_language_pref));
    if (strcmp(startup_language_pref, "auto") != 0) {
        tb_i18n_set_runtime_language(startup_language_pref);
    }
    (void)tb_i18n_init();

    signal(SIGINT,  on_sigint);
    signal(SIGTERM, on_sigint);
    signal(SIGPIPE, SIG_IGN);

    /* Before anything worth logging happens. SIGPIPE is already ignored above,
     * which matters here: the reader thread writes to a pipe and this process
     * writes to a socket, and neither should be able to kill the receiver. */
    (void)tb_logship_start();


    char tb_ip[64] = {0};
    char net_ip[64] = {0};
    if (tb_net_get_tb_ip(tb_ip, sizeof(tb_ip)) == 0) {
        printf("TBReceiver: Thunderbolt Bridge IP = %s\n", tb_ip);
    } else {
        printf("TBReceiver: warning, no bridge IP detected (169.254.x.x)\n");
    }
    if (tb_net_get_lan_ip(net_ip, sizeof(net_ip)) == 0) {
        printf("TBReceiver: Local network IP = %s\n", net_ip);
    } else {
        printf("TBReceiver: warning, no LAN IP detected (RFC1918 IPv4)\n");
    }
    printf("TBReceiver: listening on TCP port %d\n", TB_PORT);

    struct app a;
    memset(&a, 0, sizeof(a));
    // Int16 until a hello says otherwise — zeroed would mean "float", which is
    // the wrong way to guess about a sender we have not heard from yet.
    a.audio_input_is_s16 = 1;
    a.server_fd = -1;
    a.client_fd = -1;
    pthread_mutex_init(&a.net_lock, NULL);

    /* Pacing defaults on but stays one env var from off: the last attempt at
     * this made playback worse, and a bad night should not need a rebuild. */
    /* Vitals for the machine nobody is sitting at. Its stderr is shipped to the
     * sender, so this lands next to the sender's own telemetry. */
    tb_health_start();
    /* Before anything renders: keeps the loop running when the user switches to
     * another app on this Mac. Without it the loop is suspended and the receiver
     * appears to freeze on return. */
    tb_health_hold_awake();

    {
        const char *pace = getenv("TB_PACE");
        a.pace_enabled = !(pace && pace[0] == '0');
        a.pace_win_end_ms = now_ms() + 2000;
        fprintf(stderr, "[pace] presentation pacing %s\n",
                a.pace_enabled ? "on (TB_PACE=0 disables)" : "off");
    }
    a.reader1 = (struct tb_link_reader *)calloc(1, sizeof(*a.reader1));
    a.ctrl_q  = (struct tb_ctrl_msg *)calloc(TB_CTRL_QUEUE_MAX, sizeof(*a.ctrl_q));
    if (!a.reader1 || !a.ctrl_q) {
        fprintf(stderr, "[main] reader allocation failed\n");
        return 1;
    }
    {
        char host[96] = {0};
        if (gethostname(host, sizeof(host)) != 0 || host[0] == '\0') {
            snprintf(host, sizeof(host), "%s", "Receiver");
        }
        snprintf(a.bonjour_name, sizeof(a.bonjour_name), "TargetBridge %s", host);
    }
    snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", tb_ip);
    snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", net_ip);
    snprintf(a.ip_text, sizeof(a.ip_text), "%s", tb_ip[0] ? tb_ip : (net_ip[0] ? net_ip : tb_i18n_get("receiver.network.not_detected")));
    snprintf(a.language_pref, sizeof(a.language_pref), "%s", startup_language_pref);
    snprintf(a.input_control_mode, sizeof(a.input_control_mode), "%s", "off");
    a.last_input_monitoring_trusted = -1;
    a.last_accessibility_trusted = -1;
    tb_refresh_idle_localized_strings(&a);
    build_display_host(a.display_host, sizeof(a.display_host), a.ip_text, tb_ip[0] || net_ip[0]);
    tb_receiver_apply_language_preference(&a);
    tb_gesture_bridge_install(tb_receiver_space_switch_callback, &a);
    tb_gesture_bridge_set_active(0);

    a.disp = tb_disp_create(fullscreen);
    if (!a.disp) { fprintf(stderr, "tb_disp_create failed\n"); return 1; }

    /* Audio output now opens per client session (see the accept branch below
     * and close_client()) instead of at startup. Measured on the iMac: a
     * receiver that opened the device here and left it open-but-silent with
     * no client attached held coreaudiod's PreventUserIdleSystemSleep
     * assertion for its entire 49h+ idle runtime -- CoreAudio IO keeps
     * running (and coreaudiod keeps the assertion) for as long as the
     * device is open, pause or no pause. Nothing to open at startup. */
    tb_wake_watch_start();
    a.audio_reopen_retry_ms = 0;

    struct tb_display_info boot_info;
    if (tb_disp_get_info(a.disp, &boot_info) == 0) {
        snprintf(a.panel_text, sizeof(a.panel_text), "%u x %u px (%s)",
                 boot_info.active_w, boot_info.active_h, boot_info.name);
    } else {
        tb_copy_i18n(a.panel_text, sizeof(a.panel_text), "receiver.panel.default");
    }
    bonjour_update(&a, TB_PORT);

    a.dec = tb_dec_create(on_frame, &a);
    if (!a.dec) { fprintf(stderr, "tb_dec_create failed\n"); tb_disp_destroy(a.disp); return 1; }

    tb_parser_init(&a.parser, on_packet, &a);

    a.server_fd = tb_net_listen(TB_PORT);
    if (a.server_fd < 0) { fprintf(stderr, "tb_net_listen failed\n"); return 1; }

    a.last_fps_tick_ms = now_ms();
    a.last_ip_check_ms = 0;
    a.last_idle_announce_ms = now_ms(); /* bonjour_update() already called once at line ~2881 */

    /* Wall-clock accounting: every millisecond of the loop lands in exactly one
     * bucket, so the bottleneck is read off rather than guessed at. Note the
     * render runs inside the packet callback, hence inside drain — so
     * recv+parse == drain - (upload+present) reported by [perf]. */
    double acc_drain_ms = 0.0, acc_wait_ms = 0.0, acc_other_ms = 0.0;
    double acc_since_ms = now_ms_f();
    while (!g_term) {
        double loop_mark_ms = now_ms_f();
        unsigned int disp_actions = tb_disp_poll_actions(a.disp);
        int socket_activity = 0;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
        if (disp_actions & TB_DISP_ACTION_QUIT) break;
        if ((disp_actions & TB_DISP_ACTION_CYCLE_LANGUAGE) && a.client_fd < 0) {
            tb_receiver_cycle_language_preference(&a);
        }

        uint64_t t = now_ms();

        if (t - a.last_ip_check_ms >= 1000) {
            char refreshed_tb_ip[64] = {0};
            char refreshed_net_ip[64] = {0};
            a.last_ip_check_ms = t;
            (void)tb_net_get_tb_ip(refreshed_tb_ip, sizeof(refreshed_tb_ip));
            (void)tb_net_get_lan_ip(refreshed_net_ip, sizeof(refreshed_net_ip));

            const int have_refreshed_ip = refreshed_tb_ip[0] || refreshed_net_ip[0];
            const char *preferred_ip = refreshed_tb_ip[0] ? refreshed_tb_ip
                                     : (refreshed_net_ip[0] ? refreshed_net_ip
                                     : tb_i18n_get("receiver.network.not_detected"));
            if (strcmp(a.tb_ip_text, refreshed_tb_ip) != 0 ||
                strcmp(a.net_ip_text, refreshed_net_ip) != 0 ||
                strcmp(a.ip_text, preferred_ip) != 0) {
                snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", refreshed_tb_ip);
                snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", refreshed_net_ip);
                snprintf(a.ip_text, sizeof(a.ip_text), "%s", preferred_ip);
                build_display_host(a.display_host, sizeof(a.display_host), preferred_ip, have_refreshed_ip);
                if (refreshed_tb_ip[0] != '\0') {
                    fprintf(stderr, "[main] Thunderbolt Bridge IP = %s\n", refreshed_tb_ip);
                }
                if (refreshed_net_ip[0] != '\0') {
                    fprintf(stderr, "[main] Local network IP = %s\n", refreshed_net_ip);
                }
                bonjour_update(&a, TB_PORT);
            }
        }

        /* Idle Bonjour re-announce: while no client is attached, re-publish on
         * a plain timer so a sender that lost this receiver -- sleep, cable
         * pull, crash, first boot, any reason, this loop does not need to
         * know which -- sees a fresh announcement to react to. Same call the
         * interface-change branch above already makes; deliberately not
         * gated on anything having changed, since bonjour_update() is cheap
         * (one deinit + one DNSServiceRegister) and simplicity here beats
         * tracking a dirty flag. Stops entirely once a client is attached,
         * so a busy link sees zero extra churn. */
        if (a.client_fd < 0 && t - a.last_idle_announce_ms >= TB_IDLE_ANNOUNCE_INTERVAL_MS) {
            a.last_idle_announce_ms = t;
            bonjour_update(&a, TB_PORT);
        }

        /* Audio output watchdog. This is a no-op while idle now -- output
         * only runs with a client attached (opened on accept just below,
         * closed in close_client()), so there is nothing live to stall or
         * reopen until a session exists; tb_audio_watchdog_tick() checks
         * a.client_fd itself and prints the idle diagnostic instead. See the
         * TB_AUDIO_WATCHDOG_* comment near the top of the file for the two
         * failure modes this still covers once a session is live, and why
         * the thresholds are what they are. */
        tb_audio_watchdog_tick(&a, t);

        /* Accept the client. One accept per iteration.
         *
         * This link is single-sender/single-receiver: a dial that arrives while
         * a session looks live is never a genuine second concurrent client. It
         * is either the same sender's auto-reconnect redialing after its old
         * link died (the old client_fd is stale, just not yet reaped by the
         * idle watchdog below) or a restart -- either way the old session is
         * dead and this dial is its replacement. Drain the whole backlog,
         * keeping only the newest dial (closing any earlier ones queued behind
         * it -- they are superseded before ever being used), then tear the old
         * session down through the normal close_client() path and let the
         * accept branch just below pick the surviving fd up as the new live
         * session, exactly like a fresh connect.
         *
         * Measured live tonight: that rule is too eager for one case. A brand
         * new session can start streaming, and a *second*, overlapping dial
         * from the sender's own reconnect logic (retrying against its own
         * fresh connection, not against a genuinely dead one) can land only
         * milliseconds later -- 13ms after the first frame in the incident
         * that found this. Treating that second dial as proof the just-started
         * session is dead kills a working link. The distinguishing signal is
         * recency of real data: a session that has delivered its first frame
         * within the last TB_NEW_SESSION_GRACE_MS is proven live, so the new
         * dial is superseded and dropped instead. A session with no frame yet,
         * or one that has gone quiet for longer than the grace window, has not
         * proven anything (or has stopped proving it) and is replaced exactly
         * as before -- this is what keeps a genuinely dead old session from
         * ever locking out reconnects. */
        int replacement_fd = -1;
        if (a.client_fd >= 0) {
            int stale;
            while ((stale = tb_net_accept(a.server_fd)) >= 0) {
                if (replacement_fd >= 0) {
                    fprintf(stderr, "[main] closing superseded dial (newer one already queued)\n");
                    close(replacement_fd);
                }
                replacement_fd = stale;
            }
            if (replacement_fd >= 0) {
                uint64_t since_last_recv_ms = t > a.last_recv_ms ? t - a.last_recv_ms : 0;
                /* NOT gated on a.have_video_frame.
                 *
                 * Measured live 2026-09-20: a session still in its handshake
                 * (accepted, hello/caps exchanged, no video frame decoded
                 * yet -- captureStartedWaitingFirstFrame and earlier on the
                 * sender) is exactly as real and exactly as worth protecting
                 * as one that has already decoded a frame, but the
                 * `have_video_frame` condition here left it completely
                 * unprotected: any dial landing during that handshake window
                 * -- even a stray one-shot control connection unrelated to
                 * streaming, like the sender's own periodic UI-language-push
                 * probe (TBDisplaySenderManager.sendLanguageUpdate(), which
                 * opens and closes a bare NWConnection to this same port) --
                 * read as "old link is dead, replacing session" and killed
                 * the real, live handshake outright. last_recv_ms is set to
                 * the accept time itself and only ever advances on real
                 * received bytes (see drain_socket()/pump_network()), so
                 * `since_last_recv_ms < GRACE` is already a correct, tight
                 * freshness signal on its own immediately after accept, with
                 * or without a decoded frame: a session that is genuinely
                 * dead (never sent anything, or has gone silent) ages past
                 * the grace window on this same clock exactly as before and
                 * becomes replaceable again, so this does not resurrect the
                 * original stale-socket lockout the grace period exists to
                 * avoid -- it only stops protection from silently switching
                 * off for the ~1s a real session spends connecting before
                 * its first frame. */
                if (since_last_recv_ms < TB_NEW_SESSION_GRACE_MS) {
                    fprintf(stderr,
                            "[main] new dial arrived %llu ms after current session's last data and it looks alive; "
                            "keeping current session, dropping new dial\n",
                            (unsigned long long)since_last_recv_ms);
                    close(replacement_fd);
                    replacement_fd = -1;
                } else {
                    fprintf(stderr, "[main] new dial while session live: old link is dead, replacing session\n");
                    close_client(&a);   /* also calls tb_health_session_end() for the old session */
                }
            }
        }

        if (a.client_fd < 0) {
            int c = replacement_fd >= 0 ? replacement_fd : tb_net_accept(a.server_fd);
            if (c >= 0) {
                a.client_fd = c;
                a.have_video_frame = 0;
                a.session_active = 0;
                a.connecting_since = SDL_GetTicks();
                a.audio_input_is_s16 = 1;   // re-learned from the next hello
                a.reported_night_shift = -1;   /* force one report per session */
                a.reported_true_tone = -1;
                a.last_recv_ms = t;
                SDL_DisableScreenSaver();
                fprintf(stderr, "[main] client connected\n");
                /* Audio output runs only while a client is attached (see
                 * close_client() and the "Audio output open/close/watchdog"
                 * comment above for why pausing the device isn't enough and
                 * it has to be actually closed/opened): open fresh for this
                 * session. tb_audio_open() already resets the ring buffer
                 * and rebaselines the watchdog counters, so the first frames
                 * of this session are neither lost nor misread as a stall. A
                 * failed open isn't fatal -- the watchdog retries every
                 * TB_AUDIO_REOPEN_RETRY_MS same as it always has. */
                if (tb_audio_open(&a) != 0) {
                    a.audio_reopen_retry_ms = t + TB_AUDIO_REOPEN_RETRY_MS;
                }
                /* System sleep is legitimate to block only while a client is
                 * actually presenting a picture; a live TCP accept is the
                 * start of that session, and close_client() -- the single
                 * teardown path for every disconnect reason below -- pairs
                 * this with tb_health_session_end(). */
                tb_health_session_begin();
                tb_parser_free(&a.parser);
                tb_parser_init(&a.parser, on_packet, &a);
                /* Threaded receive is OFF by default: measured on the 5K iMac
                 * it moved `upload` from 12.4 ms to 27.9 ms for no fps gain.
                 * The reader's memcpy into the frame mailbox adds ~118 MB/frame
                 * of DRAM traffic that competes with the GPU upload's DMA, and
                 * this machine is memory-bandwidth bound at 59 MB/frame. Worth
                 * revisiting once the render path stops being the constraint. */
                /* On by default: the drop rule is now type-aware, so damage
                 * updates are never discarded (see the publish path). Threading
                 * overlaps receive with the ~13 ms GPU upload, which is what
                 * full-frame content — video, scrolling — is bound by.
                 * TB_RECEIVER_THREADED_RX=0 forces the serial path. */
                const char *rx_env = getenv("TB_RECEIVER_THREADED_RX");
                int want_threaded = !(rx_env && (rx_env[0] == '0' || rx_env[0] == 'n'));
                a.threaded_rx = want_threaded && (link_reader_start(a.reader1, &a, c) == 0);
                if (want_threaded && !a.threaded_rx) {
                    fprintf(stderr, "[main] falling back to inline (single-threaded) receive\n");
                }
                tb_receiver_refresh_input_capture(&a);
                tb_mic_start_if_possible(&a);
                send_receiver_info(&a);
            }
        }

        acc_other_ms += now_ms_f() - loop_mark_ms;
        double drain_mark_ms = now_ms_f();
        if (a.client_fd >= 0) {
            int fatal = 0;
            if (a.threaded_rx) {
                /* Reader threads own the sockets; here we only consume what
                 * they produced and watch for a link that ended. */
                socket_activity = pump_network(&a);
                if (a.reader1 && a.reader1->ended) fatal = 1;
            } else {
                int drain_result = drain_socket(&a);   /* primary */
                if (drain_result < 0) {
                    fatal = 1;
                } else {
                    socket_activity = drain_result;
                    if (drain_result > 0) a.last_recv_ms = t;
                }
            }
            if (fatal) {
                close_client(&a);                   /* also drops the secondary */
            } else {

                if (a.close_requested) {
                    close_client(&a);
                } else if (a.last_recv_ms < t &&
                           t - a.last_recv_ms >= TB_SENDER_IDLE_TIMEOUT_MS) {
                    /* The sender streams frames continuously and heartbeats
                     * every 2s. Total silence means it died without a FIN
                     * (crash, pulled cable, force sleep). Without this reap,
                     * the dead fd is held forever and every future connect is
                     * locked out until the app is restarted. */
                    fprintf(stderr, "[main] no data from sender for %llu ms; closing stale session\n",
                            (unsigned long long)(t > a.last_recv_ms ? t - a.last_recv_ms : 0));
                    close_client(&a);
                }
            }
        }

        if (t - a.last_permissions_poll_ms >= 250) {
            a.last_permissions_poll_ms = t;
            tb_receiver_poll_permissions(&a);
        }

        /* Cheap enough to poll: two private-framework getters, twice a second. */
        if (t - a.last_tweak_poll_ms >= 500) {
            a.last_tweak_poll_ms = t;
            tb_receiver_send_display_tweaks_if_changed(&a);
        }

        /* Apply any cursor position that arrived since the last pass. Off the
         * packet path on purpose — see tb_metal_plane_flush_cursor. */
        tb_metal_plane_flush_cursor();

        if (a.client_fd < 0 || !a.session_active) {
            /* No client, or a connection that hasn't started a real streaming
             * session (e.g. a transient UI-language push during discovery):
             * stay on the windowed waiting screen, don't flash fullscreen. */
            tb_disp_render_status(a.disp, a.display_host, a.status_text, a.sender_text, a.panel_text, a.mode_text, a.language_text, a.permissions_text);
        } else if (!a.have_video_frame) {
            /* "Connecting..." is only honest while a first frame is plausibly on
             * its way. When the sender stops streaming it keeps the control
             * connection open, so client_fd and session_active both stay set and
             * this screen used to persist forever — the receiver looked stuck
             * when it was simply idle and perfectly ready to accept a new
             * session. After a few seconds, say so. */
            if (t - a.connecting_since > 4000) {
                tb_disp_render_status(a.disp, a.display_host, a.status_text, a.sender_text,
                                      a.panel_text, a.mode_text, a.language_text,
                                      a.permissions_text);
            } else {
                tb_disp_render_connecting(a.disp);
            }
        } else {
            /* Frames are arriving; the next quiet spell starts its clock now. */
            a.connecting_since = t;
        }

        if (strcmp(a.input_control_mode, "receiverMaster") == 0 && a.client_fd >= 0) {
            if (t - a.last_clipboard_poll_ms >= 100) {
                a.last_clipboard_poll_ms = t;
                tb_receiver_send_clipboard_if_changed(&a);
            }
            struct tb_input_event input_event;
            while (tb_disp_pop_input_event(a.disp, &input_event)) {
                switch (input_event.kind) {
                case TB_INPUT_EVENT_MOVE:
                    tb_receiver_send_input_event(&a, "move", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_DRAG:
                    tb_receiver_send_input_event(&a, "leftDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_DRAG:
                    tb_receiver_send_input_event(&a, "rightDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_DRAG:
                    tb_receiver_send_input_event(&a, "otherDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_SCROLL:
                    tb_receiver_send_input_event(&a, "scroll", 0, 0, 0, 0, 1, input_event.scroll_x, 1, input_event.scroll_y, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_DOWN:
                    tb_receiver_send_input_event(&a, "leftDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_UP:
                    tb_receiver_send_input_event(&a, "leftUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_DOWN:
                    tb_receiver_send_input_event(&a, "rightDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_UP:
                    tb_receiver_send_input_event(&a, "rightUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_DOWN:
                    tb_receiver_send_input_event(&a, "otherDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_UP:
                    tb_receiver_send_input_event(&a, "otherUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_KEY_DOWN:
                    tb_receiver_send_input_event(&a, "keyDown", 0, 0, 0, 0, 0, 0, 0, 0, 1, input_event.key_code);
                    break;
                case TB_INPUT_EVENT_KEY_UP:
                    tb_receiver_send_input_event(&a, "keyUp", 0, 0, 0, 0, 0, 0, 0, 0, 1, input_event.key_code);
                    break;
                case TB_INPUT_EVENT_SWITCH_PREV_TARGET:
                    tb_receiver_send_target_switch(&a, -1);
                    break;
                case TB_INPUT_EVENT_SWITCH_NEXT_TARGET:
                    tb_receiver_send_target_switch(&a, 1);
                    break;
                case TB_INPUT_EVENT_SWITCH_PREV_SPACE:
                    tb_receiver_send_space_switch(&a, -1);
                    break;
                case TB_INPUT_EVENT_SWITCH_NEXT_SPACE:
                    tb_receiver_send_space_switch(&a, 1);
                    break;
                case TB_INPUT_EVENT_DEACTIVATE_CONTROL:
                    tb_receiver_send_deactivate_control(&a);
                    break;
                case TB_INPUT_EVENT_NONE:
                default:
                    break;
                }
            }
        }

        /* FPS log */
        if (t - a.last_fps_tick_ms >= 1000) {
            uint64_t df = a.frames - a.last_fps_count;
            a.last_fps_count   = a.frames;
            a.last_fps_tick_ms = t;
            if (df > 0) fprintf(stderr, "[main] %llu fps\n", (unsigned long long)df);
        }

        /* Yield when idle or when a nonblocking active socket had no data,
         * otherwise the receiver can busy-spin between incoming frame packets.
         *
         * Wait on the sockets rather than sleeping blindly: a raw 5K frame is
         * far larger than the socket buffer, so mid-frame the receiver drains
         * it empty many times while the rest of the frame is still on the wire.
         * A fixed sleep costs 1-2 ms on each of those, which at ~15-20 per
         * frame burned ~20 ms — more than the GPU upload itself. poll() returns
         * the moment bytes land, and the timeout only applies when the sender
         * really has gone quiet. */
        acc_drain_ms += now_ms_f() - drain_mark_ms;
        double wait_mark_ms = now_ms_f();
        if (a.threaded_rx && a.client_fd >= 0) {
            /* Sockets belong to the reader threads; waiting on them here too
             * would just duplicate their wakeups. Yield only when idle. */
            if (socket_activity == 0) SDL_Delay(1);
        } else if (a.client_fd < 0 || !a.have_video_frame || socket_activity == 0) {
            struct pollfd pfds[2];
            nfds_t npfd = 0;
            if (a.client_fd >= 0) {
                pfds[npfd].fd = a.client_fd;
                pfds[npfd].events = POLLIN;
                pfds[npfd].revents = 0;
                npfd++;
            }
            if (npfd > 0) {
                /* Bounded so SDL events, the cursor overlay and the fps tick
                 * stay responsive if the stream stalls. */
                poll(pfds, npfd, 2);
            } else {
                SDL_Delay(1);
            }
        }
        acc_wait_ms += now_ms_f() - wait_mark_ms;

        {
            double span = now_ms_f() - acc_since_ms;
            if (span >= 1000.0 && a.client_fd >= 0) {
                fprintf(stderr,
                        "[loop] over %.0f ms: drain %.0f ms (%.0f%%) | wait %.0f ms (%.0f%%) | other %.0f ms (%.0f%%)\n",
                        span,
                        acc_drain_ms, acc_drain_ms * 100.0 / span,
                        acc_wait_ms,  acc_wait_ms  * 100.0 / span,
                        acc_other_ms, acc_other_ms * 100.0 / span);
                acc_drain_ms = acc_wait_ms = acc_other_ms = 0.0;
                acc_since_ms = now_ms_f();

                /* Phase feedback to the sender. Sent from here because this tick
                 * already runs once a second on the thread that owns the socket,
                 * so it needs no timer of its own and no cross-thread send. */
                double phase_mean = 0.0;
                long   phase_n = 0;
                if (tb_health_take_drawable_phase(&phase_mean, &phase_n)) {
                    uint8_t body[8];
                    double us = phase_mean * 1000.0;
                    if (us < 0.0) us = 0.0;
                    if (us > 4294967295.0) us = 4294967295.0;
                    write_be32(body, (uint32_t)us);
                    write_be32(body + 4, (uint32_t)phase_n);
                    (void)tb_send_packet(&a, TB_PKT_PHASE, body, sizeof body);
                }
            }
        }
    }

    fprintf(stderr, "[main] exiting: %s\n",
            g_term_signal == SIGTERM ? "SIGTERM (asked to stop)"
            : g_term_signal == SIGINT ? "SIGINT (interrupted)"
            : "loop ended without a signal");
    if (a.client_fd >= 0) close(a.client_fd);
    tb_receiver_stop_input_tap(&a);
    if (a.server_fd >= 0) close(a.server_fd);
    bonjour_deinit(&a);
    tb_parser_free(&a.parser);
    tb_dec_destroy(a.dec);
    tb_audio_close(&a);
    tb_disp_destroy(a.disp);
    fprintf(stderr, "[main] bye\n");
    return 0;
}
