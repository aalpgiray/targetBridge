/* tb_wake_watch.m — see tb_wake_watch.h for why this exists. */

#import <AppKit/AppKit.h>
#include <stdatomic.h>
#include <stdio.h>

#include "tb_wake_watch.h"

/* Set from the notification handler, cleared by tb_wake_watch_take_wake().
 * atomic rather than plain int: NSWorkspace's notification center delivers
 * on the thread that registered the observer -- which is the main thread
 * here, since tb_wake_watch_start() is called from main() before the event
 * loop starts -- routed through the distributed-notification machinery on
 * that thread's run loop. main.c's loop already pumps the run loop once a
 * frame via CFRunLoopRunInMode(kCFRunLoopDefaultMode, ...), which is the
 * same thread and the same default mode NSWorkspace posts into, so in
 * practice the block below and the poller in main.c are on one thread and
 * never overlap. The atomic is kept anyway rather than relying on that: it
 * costs nothing, and turns "which thread does AppKit actually deliver this
 * on" from a fact this file must stay correct about forever into a fact it
 * no longer needs to know. */
static atomic_int g_wake_flag = 0;

void tb_wake_watch_start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserverForName:NSWorkspaceDidWakeNotification
                        object:nil
                         queue:nil   /* nil: run the block on the thread that posted,
                                      * not on an NSOperationQueue worker -- see the
                                      * comment on g_wake_flag above for why that
                                      * thread is expected to be the main one. */
                    usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            atomic_store(&g_wake_flag, 1);
            fprintf(stderr, "[audio] NSWorkspaceDidWakeNotification observed\n");
        }];
    });
}

int tb_wake_watch_take_wake(void) {
    return atomic_exchange(&g_wake_flag, 0);
}
