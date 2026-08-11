/* tb_menubar.m — see tb_menubar.h for why this exists. */

#import <Cocoa/Cocoa.h>

#include "tb_menubar.h"
#include "tb_i18n.h"

#include <stdatomic.h>
#include <string.h>

/* Set from the menu handler on the main thread, read by the run loop on its own.
 * Atomic rather than a plain int because those are different threads and the
 * whole point is that the loop notices. */
static atomic_int g_quit_requested = 0;

@interface TBMenuBarController : NSObject
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) NSMenuItem *detailItem;
@end

@implementation TBMenuBarController

- (void)quitSelected:(id)sender {
    (void)sender;
    /* Deliberately not calling exit() or [NSApp terminate:]. The run loop owns
     * teardown — the socket, the Metal ring, the audio device — and tearing that
     * down from a menu handler races whatever the render thread is mid-way
     * through. Ask, and let the loop finish its frame. */
    atomic_store(&g_quit_requested, 1);
}

@end

static TBMenuBarController *g_controller = nil;

void tb_menubar_start(void) {
    if (g_controller) return;

    /* SDL_Init has already created the NSApplication. Without one there is
     * nothing to attach a status item to — which is the case under a plain
     * `ssh` session or a launchd job with no GUI access. */
    if (!NSApp) {
        fprintf(stderr, "[menubar] no NSApplication; status item not installed\n");
        return;
    }

    g_controller = [[TBMenuBarController alloc] init];

    NSStatusItem *item = [[NSStatusBar systemStatusBar]
                          statusItemWithLength:NSVariableStatusItemLength];
    /* A template image so macOS tints it for light and dark menu bars, rather
     * than us shipping two assets and picking wrong. */
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"display"
                             accessibilityDescription:@"TargetBridge Receiver"];
    icon.template = YES;
    item.button.image = icon;

    NSMenu *menu = [[NSMenu alloc] init];

    NSMenuItem *detail = [[NSMenuItem alloc] initWithTitle:@""
                                                   action:nil
                                            keyEquivalent:@""];
    detail.enabled = NO;
    [menu addItem:detail];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc]
                        initWithTitle:[NSString stringWithUTF8String:
                                       tb_i18n_get("receiver.menu.quit")]
                        action:@selector(quitSelected:)
                        keyEquivalent:@"q"];
    quit.target = g_controller;
    [menu addItem:quit];

    item.menu = menu;
    g_controller.item = item;
    g_controller.detailItem = detail;

    tb_menubar_set_state(0, NULL);
    fprintf(stderr, "[menubar] status item installed\n");
}

void tb_menubar_set_state(int casting, const char *detail) {
    if (!g_controller) return;

    /* Called from the render loop, so it must be cheap when nothing changed:
     * assigning a status item's title or image redraws the menu bar. */
    static int last_casting = -1;
    static char last_detail[256] = {0};
    const char *text = detail ? detail : "";
    if (casting == last_casting && strncmp(text, last_detail, sizeof(last_detail) - 1) == 0) {
        return;
    }
    last_casting = casting;
    snprintf(last_detail, sizeof(last_detail), "%s", text);

    NSString *title = [NSString stringWithUTF8String:text];
    NSString *symbol = casting ? @"display.and.arrow.down" : @"display";

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_controller) return;
        NSImage *icon = [NSImage imageWithSystemSymbolName:symbol
                                 accessibilityDescription:@"TargetBridge Receiver"];
        icon.template = YES;
        g_controller.item.button.image = icon;
        g_controller.detailItem.title = title.length ? title
            : [NSString stringWithUTF8String:tb_i18n_get("receiver.menu.idle")];
    });
}

int tb_menubar_quit_requested(void) {
    return atomic_load(&g_quit_requested);
}
