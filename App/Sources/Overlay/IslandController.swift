import AppKit
import DoCore
import SwiftUI

/// Borderless, non-activating panel hosting the island at the top-center of a screen.
final class OverlayPanel: NSPanel {
    init(level: NSWindow.Level) {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the island window: placement on the active screen, click-through outside the island's
/// shape, and the lifetime of a presentation.
@MainActor
final class IslandController {
    let model = IslandModel()
    private var panel: OverlayPanel?
    private var islandFrameInView: CGRect = .zero
    private var hitTestTimer: Timer?
    private var dismissTask: Task<Void, Never>?
    private var screen: NSScreen?

    /// Large enough for the expanded island and the approval card.
    private let panelSize = CGSize(width: 640, height: 420)

    func present(task: String, on screen: NSScreen, preference: IslandStylePreference) {
        dismissTask?.cancel()
        self.screen = screen
        model.reset(task: task)
        model.style = DisplayCutout.style(for: screen, preference: preference)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let topInset: CGFloat = model.style == .floating ? DisplayCutout.menuBarHeight(screen) + 6 : 0
        panel.contentView = NSHostingView(
            rootView: IslandView(model: model, topInset: topInset) { [weak self] frame in
                self?.islandFrameInView = frame
            })
        let frame = CGRect(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height,
            width: panelSize.width, height: panelSize.height)
        panel.setFrame(frame, display: true)
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        startHitTesting()

        // Appear on the next runloop turn so the emerge animation runs.
        DispatchQueue.main.async { [model] in
            if model.phase == .hidden { model.phase = .preparing(message: "Getting ready…", progress: nil) }
        }
    }

    func finish(_ outcome: AgentOutcome) {
        model.approval = nil
        model.escapeArmed = false
        model.stopping = false
        model.agentActing = false
        model.phase = .finished(outcome)
        let long = IslandModel.describe(outcome).count > 44
        if long { model.expanded = true }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(long ? 7 : 3.5))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        model.expanded = false
        model.phase = .hidden
        stopHitTesting()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.model.phase == .hidden else { return }
            self.panel?.orderOut(nil)
        }
    }

    // MARK: Click-through

    private func makePanel() -> OverlayPanel {
        // Above the menu bar (so it can sit in the notch area), below context menus and popovers
        // the agent may open.
        OverlayPanel(level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3))
    }

    private func startHitTesting() {
        hitTestTimer?.invalidate()
        hitTestTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassthrough() }
        }
    }

    private func stopHitTesting() {
        hitTestTimer?.invalidate()
        hitTestTimer = nil
        panel?.ignoresMouseEvents = true
    }

    /// The island is interactive only under the pointer, and never while the agent is
    /// performing input (its synthetic clicks must reach the app underneath).
    private func updateMousePassthrough() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let interactive = !model.agentActing && model.phase != .hidden && islandFrameInView.insetBy(dx: -2, dy: -2).contains(local)
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
    }
}
