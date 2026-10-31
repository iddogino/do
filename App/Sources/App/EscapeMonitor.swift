import AppKit
import Carbon.HIToolbox
import DoCore

/// Watches for Escape while Do is working, system-wide.
///
/// First press arms ("Stop now — press Escape again"); a second press within the window stops
/// the run. The user's Escape presses are swallowed while active so they don't also hit the
/// app Do is driving; Do's own synthetic events (tagged by `InputSynthesizer`) pass through.
/// Requires Accessibility permission, which Do needs anyway to post input.
@MainActor
final class EscapeMonitor {
    var onArm: () -> Void = {}
    var onDisarm: () -> Void = {}
    var onStop: () -> Void = {}

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var armedUntil: Date?
    private var disarmTask: Task<Void, Never>?
    let window: Duration = .seconds(3)

    var isActive: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask), callback: escapeTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        disarm()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func escapePressed() {
        if let until = armedUntil, until > Date() {
            disarm()
            onStop()
            return
        }
        armedUntil = Date().addingTimeInterval(TimeInterval(window.components.seconds))
        onArm()
        disarmTask?.cancel()
        disarmTask = Task { [weak self, window] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.disarm()
        }
    }

    private func disarm() {
        disarmTask?.cancel()
        disarmTask = nil
        if armedUntil != nil {
            armedUntil = nil
            onDisarm()
        }
    }
}

private func escapeTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<EscapeMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { monitor.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp,
        event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape),
        event.getIntegerValueField(.eventSourceUserData) != InputSynthesizer.eventTag
    else { return Unmanaged.passUnretained(event) }

    if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        MainActor.assumeIsolated { monitor.escapePressed() }
    }
    return nil  // swallow the user's Escape while Do is working
}
