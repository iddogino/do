import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Posts synthetic mouse and keyboard events through the HID event tap.
///
/// Every event carries `InputSynthesizer.eventTag` in `eventSourceUserData`, so event taps
/// (e.g. the Escape-to-stop monitor) can tell Do's own events from the user's.
public final class InputSynthesizer: @unchecked Sendable {
    /// Marker stamped on every synthetic event ("DOAI").
    public static let eventTag: Int64 = 0x444F_4149

    private let source: CGEventSource?
    private var buttonsDown: Set<CGMouseButton> = []
    private var modifiersDown: [CGKeyCode] = []
    private let lock = NSLock()

    public init() {
        // A private state table keeps our modifier state independent of keys the user holds.
        source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cghidEventTap)
    }

    // MARK: Mouse

    public func move(to point: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
    }

    /// Glides the real pointer to `point` over `duration` (used so apps see hover/motion).
    public func glide(from start: CGPoint, to end: CGPoint, duration: Duration, steps: Int = 18) async throws {
        let n = max(1, steps)
        let pause = duration / n
        for i in 1 ... n {
            try Task.checkCancellation()
            let t = Double(i) / Double(n)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2  // ease-in-out
            move(to: CGPoint(x: start.x + (end.x - start.x) * e, y: start.y + (end.y - start.y) * e))
            try await Task.sleep(for: pause)
        }
    }

    private func types(for button: MouseButton) -> (down: CGEventType, up: CGEventType, drag: CGEventType, cg: CGMouseButton) {
        switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
        }
    }

    public func click(at point: CGPoint, button: MouseButton = .left, count: Int = 1) async throws {
        let t = types(for: button)
        for n in 1 ... max(1, count) {
            try Task.checkCancellation()
            let down = CGEvent(mouseEventSource: source, mouseType: t.down, mouseCursorPosition: point, mouseButton: t.cg)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            post(down)
            setButton(t.cg, down: true)
            try? await Task.sleep(for: .milliseconds(25))
            let up = CGEvent(mouseEventSource: source, mouseType: t.up, mouseCursorPosition: point, mouseButton: t.cg)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            post(up)
            setButton(t.cg, down: false)
            if n < count { try? await Task.sleep(for: .milliseconds(60)) }
        }
    }

    public func drag(from start: CGPoint, to end: CGPoint, duration: Duration = .milliseconds(500), steps: Int = 24) async throws {
        let t = types(for: .left)
        move(to: start)
        try await Task.sleep(for: .milliseconds(40))
        post(CGEvent(mouseEventSource: source, mouseType: t.down, mouseCursorPosition: start, mouseButton: t.cg))
        setButton(t.cg, down: true)
        defer {
            post(CGEvent(mouseEventSource: source, mouseType: t.up, mouseCursorPosition: end, mouseButton: t.cg))
            setButton(t.cg, down: false)
        }
        try await Task.sleep(for: .milliseconds(60))
        let pause = duration / max(1, steps)
        for i in 1 ... max(1, steps) {
            try Task.checkCancellation()
            let f = Double(i) / Double(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f)
            post(CGEvent(mouseEventSource: source, mouseType: t.drag, mouseCursorPosition: p, mouseButton: t.cg))
            try await Task.sleep(for: pause)
        }
        try await Task.sleep(for: .milliseconds(60))
    }

    /// Scrolls by pixel deltas (positive dy = content moves down, i.e. scroll up), split into
    /// `steps` events over `duration`.
    public func scroll(at point: CGPoint, dx: Double, dy: Double, duration: Duration, steps: Int = 12) async throws {
        move(to: point)
        let n = max(1, steps)
        let pause = duration / n
        var sentX = 0.0
        var sentY = 0.0
        for i in 1 ... n {
            try Task.checkCancellation()
            let targetX = dx * Double(i) / Double(n)
            let targetY = dy * Double(i) / Double(n)
            let stepX = Int32((targetX - sentX).rounded())
            let stepY = Int32((targetY - sentY).rounded())
            sentX += Double(stepX)
            sentY += Double(stepY)
            if stepX != 0 || stepY != 0 {
                post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: stepY, wheel2: stepX, wheel3: 0))
            }
            try await Task.sleep(for: pause)
        }
    }

    // MARK: Keyboard

    public func press(_ chord: KeyChord) async throws {
        var flags: CGEventFlags = []
        let modifierFlags: [CGKeyCode: CGEventFlags] = [
            CGKeyCode(kVK_Command): .maskCommand, CGKeyCode(kVK_Control): .maskControl,
            CGKeyCode(kVK_Option): .maskAlternate, CGKeyCode(kVK_Shift): .maskShift,
            CGKeyCode(kVK_Function): .maskSecondaryFn,
        ]
        for code in chord.modifiers {
            flags.insert(modifierFlags[code] ?? [])
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
            e?.flags = flags
            post(e)
            lock.withLock { modifiersDown.append(code) }
            try? await Task.sleep(for: .milliseconds(12))
        }
        if let key = chord.key {
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
            down?.flags = flags
            post(down)
            try? await Task.sleep(for: .milliseconds(30))
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            up?.flags = flags
            post(up)
        }
        for code in chord.modifiers.reversed() {
            flags.remove(modifierFlags[code] ?? [])
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            e?.flags = flags
            post(e)
            lock.withLock { modifiersDown.removeAll { $0 == code } }
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    /// Types arbitrary Unicode text. Newlines and tabs become Return / Tab key presses.
    public func type(_ text: String, perCharacterDelay: Duration = .milliseconds(6)) async throws {
        for ch in text {
            try Task.checkCancellation()
            switch ch {
            case "\n", "\r\n", "\r":
                try await press(KeyChord(key: CGKeyCode(kVK_Return)))
            case "\t":
                try await press(KeyChord(key: CGKeyCode(kVK_Tab)))
            default:
                let units = Array(String(ch).utf16)
                for keyDown in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                    e?.flags = []
                    units.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                    post(e)
                }
            }
            try await Task.sleep(for: perCharacterDelay)
        }
    }

    // MARK: Safety

    private func setButton(_ b: CGMouseButton, down: Bool) {
        lock.withLock {
            if down { buttonsDown.insert(b) } else { buttonsDown.remove(b) }
        }
    }

    /// Releases anything still held (after cancellation mid-drag or mid-chord).
    public func releaseAll(at point: CGPoint? = nil) {
        let (buttons, modifiers) = lock.withLock { () -> (Set<CGMouseButton>, [CGKeyCode]) in
            defer {
                buttonsDown.removeAll()
                modifiersDown.removeAll()
            }
            return (buttonsDown, modifiersDown)
        }
        let location = point ?? CGEvent(source: nil)?.location ?? .zero
        for b in buttons {
            let type: CGEventType = b == .left ? .leftMouseUp : (b == .right ? .rightMouseUp : .otherMouseUp)
            post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: b))
        }
        for code in modifiers.reversed() {
            post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false))
        }
    }

    /// The pointer's current location in global CoreGraphics coordinates.
    public static var pointerLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
