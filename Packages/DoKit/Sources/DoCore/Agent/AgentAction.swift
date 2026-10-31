import Foundation

/// A point in Mage's normalized screen space: both axes span [0, 999] regardless of the real
/// display size or aspect ratio.
public struct NormalizedPoint: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 999)
        self.y = min(max(y, 0), 999)
    }

    public var description: String { "(\(Int(x.rounded())), \(Int(y.rounded())))" }
}

public enum MouseButton: String, Sendable, Equatable {
    case left, right, middle
}

/// One `computer_use` primitive, exactly as the model's tool schema defines it.
public enum ComputerAction: Equatable, Sendable {
    case click(NormalizedPoint, button: MouseButton)
    case doubleClick(NormalizedPoint)
    case tripleClick(NormalizedPoint)
    case move(NormalizedPoint)
    case drag(from: NormalizedPoint, to: NormalizedPoint)
    case type(String)
    /// Key names as the model emits them, e.g. `["ctrl", "c"]` or `["enter"]`.
    case keypress([String])
    /// `dx`/`dy` are normalized to [-999, 999] where |999| is one full screen. Negative dy scrolls
    /// down, negative dx scrolls left.
    case scroll(at: NormalizedPoint?, dx: Double, dy: Double)
    case wait(seconds: Double)
    case screenshot
    case terminate(success: Bool, message: String?)

    /// Short human-readable label for UI.
    public var label: String {
        switch self {
        case .click(let p, let b): b == .left ? "Click \(p)" : "\(b.rawValue.capitalized)-click \(p)"
        case .doubleClick(let p): "Double-click \(p)"
        case .tripleClick(let p): "Triple-click \(p)"
        case .move(let p): "Move to \(p)"
        case .drag(let a, let b): "Drag \(a) → \(b)"
        case .type(let t): "Type “\(t.count > 40 ? String(t.prefix(40)) + "…" : t)”"
        case .keypress(let keys): "Press \(keys.joined(separator: "+"))"
        case .scroll(_, let dx, let dy):
            dy != 0 ? (dy < 0 ? "Scroll down" : "Scroll up") : (dx < 0 ? "Scroll left" : "Scroll right")
        case .wait(let s): "Wait \(s.formatted(.number.precision(.fractionLength(0...1))))s"
        case .screenshot: "Look at the screen"
        case .terminate(let ok, _): ok ? "Done" : "Gave up"
        }
    }
}

/// What a single model response asks the harness to do. One response uses one tool family.
public enum ToolInvocation: Equatable, Sendable {
    case computer([ComputerAction])
    case bash([String])

    public var toolName: String {
        switch self {
        case .computer: "computer_use"
        case .bash: "bash"
        }
    }
}

/// A parsed model turn.
public struct AgentTurn: Equatable, Sendable {
    /// The full raw response text (stored verbatim in history, as the reference harness does).
    public var raw: String
    /// Reasoning from the `<think>` block, if any.
    public var thinking: String
    /// The one-line `Action:` summary (or a synthesized one).
    public var actionSentence: String
    /// Nil when the response contained no executable call.
    public var invocation: ToolInvocation?
    /// Non-fatal problems found while parsing, for logging.
    public var issues: [String]

    public var isTerminal: Bool {
        if case .computer(let actions) = invocation {
            return actions.contains { if case .terminate = $0 { true } else { false } }
        }
        return false
    }
}
