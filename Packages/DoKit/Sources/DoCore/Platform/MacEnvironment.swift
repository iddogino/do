import AppKit
import CoreGraphics
import Foundation

/// Visual feedback for what the agent is doing. Implemented by the app's cursor overlay.
/// Methods that return after an animation are awaited so the on-screen cursor arrives before
/// the real event fires.
@MainActor
public protocol ActionVisualizer: AnyObject {
    /// Glide the agent cursor to `point` (global CG coordinates). Returns on arrival.
    func moveCursor(to point: CGPoint) async
    func showClick(at point: CGPoint, button: MouseButton, count: Int)
    func beginDrag(at point: CGPoint)
    func updateDrag(to point: CGPoint)
    func endDrag(at point: CGPoint)
    /// Morph into the scroll indicator for `duration`.
    func showScroll(at point: CGPoint, dx: Double, dy: Double, duration: Duration)
    func showTyping(_ text: String)
    func showKeys(_ keys: [String])
    func showWaiting(seconds: Double)
    func showShell(_ command: String)
    func showThinking()
    func settle()
}

/// The real Mac: ScreenCaptureKit for observation, CGEvent for input, zsh for shell commands.
public final class MacEnvironment: AgentEnvironment, @unchecked Sendable {

    public struct Configuration: Sendable {
        /// Swap Ctrl for Cmd on standard shortcuts when the frontmost app isn't a terminal.
        public var translateLinuxShortcuts = true
        /// Cursor travel speed for the visible glide, in points per second.
        public var cursorSpeed: Double = 2200
        public var typingDelay: Duration = .milliseconds(6)
        public var scrollDuration: Duration = .milliseconds(650)
        public init() {}
    }

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
    ]

    public let configuration: Configuration
    let capturer = ScreenCapturer()
    let input = InputSynthesizer()
    let shell: ShellRunner
    weak var visualizer: (any ActionVisualizer)?
    private let displayLock = NSLock()
    private var pinnedDisplay: CGDirectDisplayID?

    @MainActor
    public init(
        shell: ShellRunner = ShellRunner(workingDirectory: ShellRunner.defaultWorkspace),
        visualizer: (any ActionVisualizer)?,
        configuration: Configuration = .init()
    ) {
        self.shell = shell
        self.visualizer = visualizer
        self.configuration = configuration
    }

    // MARK: AgentEnvironment

    public func captureScreen() async throws -> CapturedScreen {
        // Stick to one display for the whole task (the one active when it started).
        let display: CGDirectDisplayID = displayLock.withLock {
            if pinnedDisplay == nil { pinnedDisplay = ScreenCapturer.activeDisplayID() }
            return pinnedDisplay!
        }
        return try await capturer.capture(displayID: display)
    }

    public func perform(_ action: ComputerAction, on screen: CapturedScreen) async throws {
        switch action {
        case .click(let p, let button):
            let pt = screen.point(for: p)
            try await glide(to: pt)
            await visualize { $0.showClick(at: pt, button: button, count: 1) }
            try await input.click(at: pt, button: button, count: 1)

        case .doubleClick(let p):
            let pt = screen.point(for: p)
            try await glide(to: pt)
            await visualize { $0.showClick(at: pt, button: .left, count: 2) }
            try await input.click(at: pt, count: 2)

        case .tripleClick(let p):
            let pt = screen.point(for: p)
            try await glide(to: pt)
            await visualize { $0.showClick(at: pt, button: .left, count: 3) }
            try await input.click(at: pt, count: 3)

        case .move(let p):
            try await glide(to: screen.point(for: p))

        case .drag(let from, let to):
            let a = screen.point(for: from)
            let b = screen.point(for: to)
            try await glide(to: a)
            await visualize { $0.beginDrag(at: a) }
            let duration = travelTime(from: a, to: b, minimum: 0.45)
            let animate = Task { @MainActor [weak visualizer] in
                let steps = 24
                for i in 1 ... steps {
                    let f = Double(i) / Double(steps)
                    visualizer?.updateDrag(to: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                    try? await Task.sleep(for: duration / steps)
                }
            }
            defer { animate.cancel() }
            try await input.drag(from: a, to: b, duration: duration)
            await visualize { $0.endDrag(at: b) }

        case .type(let text):
            await visualize { $0.showTyping(text) }
            try await input.type(text, perCharacterDelay: configuration.typingDelay)

        case .keypress(let keys):
            var names = keys
            if configuration.translateLinuxShortcuts, !(await frontmostIsTerminal()) {
                names = KeyMapping.translatingLinuxShortcuts(keys)
            }
            await visualize { $0.showKeys(names) }
            let chord = try KeyMapping.chord(for: names)
            try await input.press(chord)

        case .scroll(let at, let dx, let dy):
            let pt = at.map { screen.point(for: $0) } ?? CGPoint(x: screen.displayBounds.midX, y: screen.displayBounds.midY)
            if at != nil { try await glide(to: pt) }
            let pixelsY = dy / 999 * screen.displayBounds.height
            let pixelsX = dx / 999 * screen.displayBounds.width
            let duration = configuration.scrollDuration
            await visualize { $0.showScroll(at: pt, dx: dx, dy: dy, duration: duration) }
            // Model: negative scroll_y = down. CG: positive wheel1 scrolls up (content down).
            try await input.scroll(at: pt, dx: pixelsX, dy: pixelsY, duration: duration)

        case .wait(let seconds):
            await visualize { $0.showWaiting(seconds: seconds) }
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))

        case .screenshot, .terminate:
            break
        }
    }

    public func runShell(_ command: String) async throws -> ShellResult {
        await visualize { $0.showShell(command) }
        return try await shell.run(command)
    }

    public func finish() async {
        input.releaseAll()
        await visualize { $0.settle() }
    }

    // MARK: Helpers

    private func visualize(_ body: @MainActor @escaping (any ActionVisualizer) -> Void) async {
        await MainActor.run {
            if let visualizer { body(visualizer) }
        }
    }

    private func travelTime(from a: CGPoint, to b: CGPoint, minimum: Double = 0.18) -> Duration {
        let distance = hypot(b.x - a.x, b.y - a.y)
        let seconds = min(0.75, max(minimum, distance / configuration.cursorSpeed + 0.12))
        return .milliseconds(Int(seconds * 1000))
    }

    /// Animates the agent cursor and the real pointer to `point`.
    private func glide(to point: CGPoint) async throws {
        let start = InputSynthesizer.pointerLocation
        let duration = travelTime(from: start, to: point)
        let visual = Task { @MainActor [weak self] in
            await self?.visualizer?.moveCursor(to: point)
        }
        try await input.glide(from: start, to: point, duration: duration)
        await visual.value
        input.move(to: point)
        try await Task.sleep(for: .milliseconds(40))
    }

    @MainActor
    private func frontmostIsTerminal() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.terminalBundleIDs.contains(id)
    }
}
