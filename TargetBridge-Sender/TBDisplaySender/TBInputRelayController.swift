import AppKit
import Foundation

@MainActor
final class TBInputRelayController {
    typealias Handler = (TBMonitorInputEvent) -> Void
    typealias SwitchHandler = (_ direction: Int) -> Void
    typealias DeactivateHandler = () -> Void

    private static let escapeChordKeyCode: UInt16 = 40 // kVK_ANSI_K
    private static let keepAwakeReason = "TargetBridge Input Dockstation active"

    private var localMonitors: [Any] = []
    private var globalMonitors: [Any] = []
    private var handler: Handler?
    private var switchHandler: SwitchHandler?
    private var deactivateHandler: DeactivateHandler?
    private var gestureMode: TBInputGestureMode = .native
    private var lastEdgeSwitchTime: TimeInterval = 0
    private var activityToken: NSObjectProtocol?

    func start(
        gestureMode: TBInputGestureMode,
        handler: @escaping Handler,
        switchHandler: @escaping SwitchHandler,
        deactivateHandler: @escaping DeactivateHandler
    ) {
        stop()
        self.gestureMode = gestureMode
        self.handler = handler
        self.switchHandler = switchHandler
        self.deactivateHandler = deactivateHandler
        beginKeepAwakeActivity()

        installKeyboardMonitors()
        installMouseMonitors()
        installScrollMonitors()
    }

    func stop() {
        for token in localMonitors {
            NSEvent.removeMonitor(token)
        }
        for token in globalMonitors {
            NSEvent.removeMonitor(token)
        }
        localMonitors.removeAll()
        globalMonitors.removeAll()
        endKeepAwakeActivity()
        handler = nil
        switchHandler = nil
        deactivateHandler = nil
    }

    private func installKeyboardMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]

        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            if self.shouldDeactivateFromEscapeChord(event) {
                self.deactivateHandler?()
                return
            }
            self.handle(event)
        }
        if let global { globalMonitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if self.shouldDeactivateFromEscapeChord(event) {
                self.deactivateHandler?()
                return nil
            }
            if self.shouldConsumeSwitchHotkey(event) {
                return nil
            }
            self.handle(event)
            return event
        }
        if let local { localMonitors.append(local) }
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp
        ]

        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        if let global { globalMonitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if self?.shouldSwitchSlaveOnEdge(for: event) == true {
                return nil
            }
            self?.handle(event)
            return event
        }
        if let local { localMonitors.append(local) }
    }

    private func installScrollMonitors() {
        let mask: NSEvent.EventTypeMask = [.scrollWheel]

        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        if let global { globalMonitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        if let local { localMonitors.append(local) }
    }

    private func handle(_ event: NSEvent) {
        guard let handler, let relayEvent = convert(event) else { return }
        handler(relayEvent)
    }

    private func convert(_ event: NSEvent) -> TBMonitorInputEvent? {
        switch event.type {
        case .mouseMoved:
            return TBMonitorInputEvent(
                kind: "move",
                dx: Int(event.deltaX.rounded()),
                dy: Int(event.deltaY.rounded()),
                scrollX: nil,
                scrollY: nil,
                keyCode: nil
            )
        case .leftMouseDragged:
            return TBMonitorInputEvent(
                kind: "leftDrag",
                dx: Int(event.deltaX.rounded()),
                dy: Int(event.deltaY.rounded()),
                scrollX: nil,
                scrollY: nil,
                keyCode: nil
            )
        case .rightMouseDragged:
            return TBMonitorInputEvent(
                kind: "rightDrag",
                dx: Int(event.deltaX.rounded()),
                dy: Int(event.deltaY.rounded()),
                scrollX: nil,
                scrollY: nil,
                keyCode: nil
            )
        case .otherMouseDragged:
            return TBMonitorInputEvent(
                kind: "otherDrag",
                dx: Int(event.deltaX.rounded()),
                dy: Int(event.deltaY.rounded()),
                scrollX: nil,
                scrollY: nil,
                keyCode: nil
            )
        case .leftMouseDown:
            return TBMonitorInputEvent(kind: "leftDown", dx: nil, dy: nil, scrollX: nil, scrollY: nil, keyCode: nil)
        case .leftMouseUp:
            return TBMonitorInputEvent(kind: "leftUp", dx: nil, dy: nil, scrollX: nil, scrollY: nil, keyCode: nil)
        case .rightMouseDown:
            return TBMonitorInputEvent(kind: "rightDown", dx: nil, dy: nil, scrollX: nil, scrollY: nil, keyCode: nil)
        case .rightMouseUp:
            return TBMonitorInputEvent(kind: "rightUp", dx: nil, dy: nil, scrollX: nil, scrollY: nil, keyCode: nil)
        case .otherMouseDown:
            return TBMonitorInputEvent(kind: "otherDown", dx: nil, dy: nil, scrollX: nil, scrollY: nil, keyCode: nil)
        case .otherMouseUp:
            return TBMonitorInputEvent(kind: "otherUp", dx: nil, dy: nil, scrollX: nil, scrollY: nil, keyCode: nil)
        case .scrollWheel:
            return TBMonitorInputEvent(
                kind: "scroll",
                dx: nil,
                dy: nil,
                scrollX: Int(event.scrollingDeltaX.rounded()),
                scrollY: Int(event.scrollingDeltaY.rounded()),
                keyCode: nil
            )
        case .keyDown:
            if gestureMode == .relayToSlave, shouldSwitchSlaveFromHotkey(event) {
                return nil
            }
            return TBMonitorInputEvent(kind: "keyDown", dx: nil, dy: nil, scrollX: nil, scrollY: nil, keyCode: event.keyCode)
        case .keyUp:
            if gestureMode == .relayToSlave, isHandledHotkeyRelease(event) {
                return nil
            }
            return TBMonitorInputEvent(kind: "keyUp", dx: nil, dy: nil, scrollX: nil, scrollY: nil, keyCode: event.keyCode)
        case .flagsChanged:
            let down = modifierIsDown(for: event)
            return TBMonitorInputEvent(kind: down ? "keyDown" : "keyUp", dx: nil, dy: nil, scrollX: nil, scrollY: nil, keyCode: event.keyCode)
        default:
            return nil
        }
    }

    private func shouldSwitchSlaveOnEdge(for event: NSEvent) -> Bool {
        guard gestureMode == .relayToSlave,
              event.type == .mouseMoved || event.type == .leftMouseDragged || event.type == .rightMouseDragged || event.type == .otherMouseDragged,
              let switchHandler,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
        else {
            return false
        }

        let location = NSEvent.mouseLocation
        let threshold: CGFloat = 2
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastEdgeSwitchTime > 0.45 else { return false }

        if location.x <= screen.frame.minX + threshold, event.deltaX < 0 {
            lastEdgeSwitchTime = now
            switchHandler(-1)
            return true
        }

        if location.x >= screen.frame.maxX - threshold, event.deltaX > 0 {
            lastEdgeSwitchTime = now
            switchHandler(1)
            return true
        }

        return false
    }

    private func shouldSwitchSlaveFromHotkey(_ event: NSEvent) -> Bool {
        guard let switchHandler,
              event.modifierFlags.contains(.control),
              event.modifierFlags.contains(.option)
        else {
            return false
        }

        switch Int(event.keyCode) {
        case 123:
            switchHandler(-1)
            return true
        case 124:
            switchHandler(1)
            return true
        default:
            return false
        }
    }

    private func isHandledHotkeyRelease(_ event: NSEvent) -> Bool {
        Int(event.keyCode) == 123 || Int(event.keyCode) == 124
    }

    private func shouldConsumeSwitchHotkey(_ event: NSEvent) -> Bool {
        gestureMode == .relayToSlave && (shouldSwitchSlaveFromHotkey(event) || isHandledHotkeyRelease(event))
    }

    private func shouldDeactivateFromEscapeChord(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.keyCode == Self.escapeChordKeyCode
        else {
            return false
        }

        let flags = event.modifierFlags.intersection([.control, .option, .command])
        return flags.contains(.control) && flags.contains(.option) && flags.contains(.command)
    }

    private func modifierIsDown(for event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 54, 55:
            return event.modifierFlags.contains(.command)
        case 56, 60:
            return event.modifierFlags.contains(.shift)
        case 58, 61:
            return event.modifierFlags.contains(.option)
        case 59, 62:
            return event.modifierFlags.contains(.control)
        case 57:
            return event.modifierFlags.contains(.capsLock)
        case 63:
            return event.modifierFlags.contains(.function)
        default:
            return false
        }
    }

    /// Keep this process responsive to input-relay events (keyboard/mouse
    /// pass-through to whichever Mac has focus) even when TargetBridge is not
    /// the frontmost app, without blocking system sleep.
    ///
    /// `.userInitiatedAllowingIdleSystemSleep` alone is the fix: mixing it with
    /// `.idleSystemSleepDisabled` (as this used to) put a system-sleep-BLOCKING
    /// flag in the same option set as the one flag whose entire purpose is to
    /// ALLOW idle system sleep — `IOPMAssertionCreate`/`ProcessInfo` OR the
    /// flags together, so the blocking flag always won and the "Allowing"
    /// half of the name was a lie in practice. `.idleDisplaySleepDisabled` is
    /// dropped for the same class of reason: nothing about relaying input
    /// requires the SCREEN to stay lit, only the process to stay scheduled.
    private func beginKeepAwakeActivity() {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: Self.keepAwakeReason
        )
    }

    private func endKeepAwakeActivity() {
        guard let activityToken else { return }
        ProcessInfo.processInfo.endActivity(activityToken)
        self.activityToken = nil
    }
}
