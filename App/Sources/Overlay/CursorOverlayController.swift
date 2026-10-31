import AppKit
import DoCore
import SwiftUI

/// Full-screen, click-through overlay that draws Do's agent cursor and its action feedback.
/// Implements `ActionVisualizer` so `MacEnvironment` can animate before each real event.
@MainActor
final class CursorOverlayController: ActionVisualizer {
    let model = CursorModel()
    private var panel: OverlayPanel?
    private var displayBounds: CGRect = .zero
    private var badgeReset: Task<Void, Never>?
    private var modeReset: Task<Void, Never>?

    /// Shows the overlay on the display with the given CoreGraphics bounds, starting the agent
    /// cursor at the real pointer.
    func show(on screen: NSScreen) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: true)
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        } else {
            displayBounds = CGRect(origin: .zero, size: screen.frame.size)
        }
        model.position = local(InputSynthesizer.pointerLocation)
        model.mode = .pointer
        model.badge = .none
        model.ripples = []
        model.dragStart = nil
        panel.orderFrontRegardless()
        withAnimation(.easeOut(duration: 0.25)) { model.visible = true }
    }

    func hide() {
        badgeReset?.cancel()
        modeReset?.cancel()
        withAnimation(.easeIn(duration: 0.2)) {
            model.visible = false
            model.badge = .none
            model.dragStart = nil
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard let self, !self.model.visible else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(level: .screenSaver)
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: CursorOverlayView(model: model))
        return panel
    }

    /// Global CG point (top-left origin) → overlay-local SwiftUI point.
    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - displayBounds.minX, y: p.y - displayBounds.minY)
    }

    private func setBadge(_ badge: CursorModel.Badge, clearAfter seconds: Double? = nil) {
        badgeReset?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.badge = badge }
        if let seconds {
            badgeReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.model.badge = .none }
            }
        }
    }

    // MARK: ActionVisualizer

    func moveCursor(to point: CGPoint) async {
        let target = local(point)
        let distance = hypot(target.x - model.position.x, target.y - model.position.y)
        let duration = min(0.75, max(0.18, distance / 2200 + 0.12))
        if model.mode == .thinking { model.mode = .pointer }
        if case .thinking = model.badge { setBadge(.none) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            withAnimation(.timingCurve(0.3, 0.0, 0.2, 1.0, duration: duration)) {
                model.position = target
            } completion: {
                c.resume()
            }
        }
    }

    func showClick(at point: CGPoint, button: MouseButton, count: Int) {
        let p = local(point)
        let tint: Color = button == .right ? Theme.warning : (button == .middle ? Theme.success : Theme.brand[1])
        for i in 0 ..< max(1, count) {
            model.ripples.append(.init(point: p, tint: tint, delay: Double(i) * 0.12))
        }
        model.pressed = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140 + 110 * max(0, count - 1)))
            self?.model.pressed = false
            try? await Task.sleep(for: .milliseconds(700))
            self?.model.ripples.removeAll { $0.point == p }
        }
        let label = switch (button, count) {
        case (.right, _): "Right-click"
        case (_, 2): "Double-click"
        case (_, 3): "Triple-click"
        default: "Click"
        }
        setBadge(.text(icon: "cursorarrow.click", text: label), clearAfter: 1.1)
    }

    func beginDrag(at point: CGPoint) {
        model.dragStart = local(point)
        model.mode = .dragging
        model.pressed = true
        setBadge(.text(icon: "hand.draw", text: "Dragging"))
    }

    func updateDrag(to point: CGPoint) {
        model.position = local(point)
    }

    func endDrag(at point: CGPoint) {
        model.position = local(point)
        model.pressed = false
        model.mode = .pointer
        withAnimation(.easeOut(duration: 0.3)) { model.dragStart = nil }
        setBadge(.none)
    }

    func showScroll(at point: CGPoint, dx: Double, dy: Double, duration: Duration) {
        modeReset?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            model.position = local(point)
            model.mode = .scrolling(dx: dx, dy: dy)
        }
        let direction = dy != 0 ? (dy < 0 ? "down" : "up") : (dx < 0 ? "left" : "right")
        setBadge(.text(icon: "scroll", text: "Scrolling \(direction)"))
        modeReset = Task { [weak self] in
            try? await Task.sleep(for: duration + .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { self.model.mode = .pointer }
            self.setBadge(.none)
        }
    }

    func showTyping(_ text: String) {
        setBadge(.typing(text), clearAfter: min(6, 0.8 + Double(text.count) * 0.012))
    }

    func showKeys(_ keys: [String]) {
        setBadge(.keys(keys), clearAfter: 1.2)
    }

    func showWaiting(seconds: Double) {
        setBadge(.waiting(seconds: seconds), clearAfter: seconds)
    }

    func showShell(_ command: String) {
        let firstLine = command.split(separator: "\n").first.map(String.init) ?? command
        setBadge(.text(icon: "terminal", text: firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine))
    }

    func showThinking() {
        modeReset?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) { model.mode = .thinking }
        setBadge(.thinking)
    }

    func settle() {
        model.pressed = false
        model.dragStart = nil
        model.mode = .pointer
        setBadge(.none)
    }
}
