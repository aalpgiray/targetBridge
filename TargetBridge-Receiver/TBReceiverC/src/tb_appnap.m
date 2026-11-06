#import "tb_appnap.h"

#import <Foundation/Foundation.h>

#include <stdio.h>

void tb_appnap_hold_awake(void) {
    static id<NSObject> activity = nil;
    if (activity) return;

    /* userInitiatedAllowingIdleSystemSleep keeps App Nap off this process.
     * The plain NSActivityUserInitiated flag also sets
     * NSActivityIdleSystemSleepDisabled, which would pin the Mac awake with
     * no client connected. latencyCritical keeps the frame timer from being
     * coalesced. NSAppSleepDisabled in the bundle covers the window before
     * this call. */
    activity = [[NSProcessInfo processInfo]
        beginActivityWithOptions:(NSActivityUserInitiatedAllowingIdleSystemSleep |
                                  NSActivityLatencyCritical)
                          reason:@"TargetBridge is presenting a live display"];
    fprintf(stderr,
            "[appnap] holding off App Nap (userInitiatedAllowingIdleSystemSleep|latencyCritical)\n");
}
