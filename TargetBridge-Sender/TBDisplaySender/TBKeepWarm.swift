import AppKit
import CoreVideo
import Foundation

/// Keeps the virtual display compositing at its full rate by giving it
/// something that always changes.
///
/// WHY
///
/// A CGVirtualDisplay has no scanout forcing a rhythm, so WindowServer
/// composites it only when something changes. Read a still page and content
/// production sags to about 5.6 Hz — measured — and the next keystroke then
/// waits for whatever tick comes next. That wait is 173 ms on average and past
/// 1.4 s at worst, and it is the whole of what "it feels sluggish when I start
/// typing again" means. Nothing downstream can fix it: the pixels for that
/// keystroke do not exist yet, so there is nothing for the encoder or the link
/// to be faster about.
///
/// The display has no slow mode of its own, though. Whenever anything on it
/// animates — a video, a spinner — it holds a rock-solid 60 Hz indefinitely,
/// including for 37 seconds with no input at all. So the fix is not to make it
/// faster, it is to stop letting it go quiet: put one pixel on it that changes
/// every frame, and the compositor keeps producing. A keystroke then lands in a
/// frame that was going to be composited anyway.
///
/// WHAT IT COSTS
///
/// Every composited frame is a real frame to us — encoded, sent, decoded — so
/// this trades bandwidth and heat for latency, permanently rather than only
/// while it is needed. That is a deliberate choice for this setup: it runs on
/// mains power, and watching a video already pins both machines at exactly this
/// load, so the ceiling is one we know both ends survive.
///
/// `defaults write com.targetbridge.sender TBKeepWarm -bool false` turns it off.
///
/// HOW
///
/// A 1×1 borderless window in a corner of the virtual display, alternating
/// between two colours a single step apart. One pixel out of nearly fifteen
/// million, changing by 1/255 — invisible in practice, and enough damage that
/// WindowServer must composite the frame. Driven by a CVDisplayLink bound to
/// that display, so the beat is the display's own rather than a timer racing
/// it.
///
/// THE CHANGE MUST BE MADE ON A LAYER, NOT ON THE WINDOW
///
/// The first version set `window.backgroundColor` each tick, which segfaulted
/// the app roughly hourly:
///
///     objc_release
///     -[_NSWindowTransformAnimation dealloc]
///     CA::Transaction::commit()
///
/// Assigning that property runs AppKit's implicit-animation path and mints an
/// `_NSWindowTransformAnimation` per assignment. Sixty a second overlap, and
/// the Core Animation transaction ends up releasing one that is already gone.
/// Window properties are built for occasional, animated changes; this needs the
/// opposite, so it drives a CALayer directly with actions disabled and never
/// touches the window again after it is placed.
@MainActor
final class TBKeepWarm {
    private var window: NSWindow?
    private var layer: CALayer?
    private var link: CVDisplayLink?
    private var phase = false
    /// The display we are pinned to, so a screen-parameters change can tell
    /// whether it is still there. nil whenever we are stopped.
    private var displayID: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "TBKeepWarm") as? Bool) ?? true
    }

    /// `displayID` must be the virtual display: the point is to keep THAT
    /// compositor busy, and a window on any other screen would keep the wrong
    /// one awake while doing nothing for the link.
    func start(displayID: CGDirectDisplayID) {
        guard Self.isEnabled, window == nil else { return }

        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isEmpty else {
            TBLog.connection.warning("keep-warm: display \(displayID, privacy: .public) has no bounds; not starting")
            return
        }

        // Bottom-left corner in Cocoa coordinates. CGDisplayBounds is top-left
        // origin and NSWindow is bottom-left, so the y needs flipping against
        // the primary display's height.
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let origin = NSPoint(x: bounds.minX,
                             y: primaryHeight - bounds.maxY)

        let w = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 1, height: 1)),
                         styleMask: .borderless,
                         backing: .buffered,
                         defer: false)
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .normal
        // Nothing about this window should ever animate.
        w.animationBehavior = .none
        // MUST be false, and this line is load-bearing. An NSWindow built with
        // init(contentRect:…) defaults to releasing itself on close, which is a
        // manual-retain-counting convention ARC knows nothing about: `close()`
        // sends one release, and the strong `window` property sends another when
        // it is cleared. The object dies once too often.
        //
        // The symptom is not a crash in stop(). It is a segfault later, in
        // objc_release under -[NSAutoreleasePool drain] on the main thread, with
        // a stack that names nothing of ours — because the over-release is only
        // discovered when the pool gets round to the corpse. It cost most of a
        // day to find, twice, appearing as "crashes when I unplug the cable" and
        // "crashes when I unlock the Mac". Both are just teardown paths that
        // reach stop().
        w.isReleasedWhenClosed = false
        // Present on every Space and in every app, so switching desktops does
        // not silently take the beat away.
        //
        // `.fullScreenAuxiliary` is what covers fullscreen, and leaving it out
        // was a real gap: a fullscreen app gets its own Space, and without this
        // bit AppKit is free to leave the window out of it. Measured — with
        // nothing fullscreen, every report read `idle 0`; with a fullscreen
        // window on the virtual display, 27 of 40 reports had idle frames
        // again, because the one thing generating damage was no longer being
        // composited. The header is explicit: "Windows with this collection
        // behavior can be shown with the fullscreen window."
        //
        // At most one of FullScreenPrimary / FullScreenAuxiliary / FullScreenNone
        // may be set, so this is additive rather than a conflict.
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                .fullScreenAuxiliary]
        w.backgroundColor = .black
        w.alphaValue = 1.0

        // The layer is the only thing touched after this point.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.wantsLayer = true
        let l = CALayer()
        l.frame = view.bounds
        l.backgroundColor = CGColor(gray: 0.0, alpha: 1.0)
        view.layer = l
        w.contentView = view

        w.orderFrontRegardless()
        window = w
        layer = l

        var displayLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &displayLink) == kCVReturnSuccess,
              let displayLink else {
            TBLog.connection.warning("keep-warm: could not create a display link; not starting")
            w.close(); window = nil
            return
        }

        // The callback is C and runs on the link's own thread; hop to main
        // because the change it makes is to a window.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            let me = Unmanaged<TBKeepWarm>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.tick() } }
            return kCVReturnSuccess
        }, ctx)
        CVDisplayLinkStart(displayLink)
        link = displayLink
        self.displayID = displayID
        observeScreenChanges()

        TBLog.connection.notice("keep-warm: on (display \(displayID, privacy: .public)) — TBKeepWarm=false disables")
    }

    func stop() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        if let link {
            CVDisplayLinkStop(link)
            // Detach the callback before dropping the last reference.
            // CVDisplayLinkStop does not wait for a callback that is already
            // running, so releasing the link here can pull it out from under its
            // own thread. Clearing the callback first means the worst case is a
            // callback that returns without touching us.
            CVDisplayLinkSetOutputCallback(link, nil, nil)
            self.link = nil
        }
        // orderOut first: closing a window that still belongs to a display being
        // torn down invites AppKit to reposition it mid-teardown, which is the
        // same window of time the cable pull opens.
        window?.orderOut(nil)
        window?.close()
        window = nil
        layer = nil
        displayID = nil
    }

    /// Stop of our own accord if the display we are pinned to disappears.
    ///
    /// The teardown path already calls stop(), but not necessarily first: pulling
    /// the cable destroys the virtual display, and until the session notices we
    /// would be driving a CVDisplayLink bound to a display that no longer exists
    /// and holding a window positioned on it. Ending promptly and on the main
    /// thread is cheaper than being resilient to every way that can go wrong.
    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.displayID else { return }
                guard CGDisplayBounds(id).isEmpty else { return }
                TBLog.connection.notice("keep-warm: display \(id, privacy: .public) went away; stopping")
                self.stop()
            }
        }
    }

    /// One step of the alternation. Two greys one level apart: enough for
    /// WindowServer to treat the layer as dirty, not enough for an eye to see.
    ///
    /// Inside an explicit transaction with actions disabled. Without that, Core
    /// Animation would animate the colour change — which is both wrong (the
    /// point is one discrete change per refresh, not a fade) and the shape of
    /// the crash this replaced.
    private func tick() {
        guard let layer else { return }
        phase.toggle()
        let v: CGFloat = phase ? 0.0 : 1.0 / 255.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = CGColor(gray: v, alpha: 1.0)
        CATransaction.commit()
    }

    // No deinit: a nonisolated one cannot touch these main-actor properties
    // under Swift 6, and it would be redundant anyway — this object lives as
    // long as the service, and `stop()` runs on every teardown path.
}
