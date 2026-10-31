import CoreGraphics
import Foundation
import os

/// A screenshot together with the geometry needed to map Mage's normalized coordinates back
/// onto the real display.
public struct CapturedScreen: Sendable {
    public var attachment: ImageAttachment
    /// The captured display's bounds in global CoreGraphics points (top-left origin).
    public var displayBounds: CGRect
    public var displayID: CGDirectDisplayID

    public init(attachment: ImageAttachment, displayBounds: CGRect, displayID: CGDirectDisplayID) {
        self.attachment = attachment
        self.displayBounds = displayBounds
        self.displayID = displayID
    }

    /// Reference mapping: `x / 999 * (width - 1)`, in points on this display.
    public func point(for p: NormalizedPoint) -> CGPoint {
        CGPoint(
            x: displayBounds.minX + p.x / 999 * (displayBounds.width - 1),
            y: displayBounds.minY + p.y / 999 * (displayBounds.height - 1))
    }
}

/// The machine the agent acts on.
public protocol AgentEnvironment: Sendable {
    func captureScreen() async throws -> CapturedScreen
    /// Executes one GUI action. `screen` is the screenshot the model was looking at.
    func perform(_ action: ComputerAction, on screen: CapturedScreen) async throws
    func runShell(_ command: String) async throws -> ShellResult
    /// Called once when the session ends (for any reason) to release held keys/buttons.
    func finish() async
}

public struct ShellResult: Sendable, Equatable {
    public var output: String
    public var exitCode: Int32
    public var timedOut: Bool

    public init(output: String, exitCode: Int32, timedOut: Bool = false) {
        self.output = output
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

/// Decides whether a shell command may run. Returns false to refuse it.
public typealias CommandApprover = @Sendable (String) async -> Bool

public enum AgentOutcome: Sendable, Equatable {
    case completed(message: String?)
    case gaveUp(message: String?)
    case stopped
    case stepLimitReached
    case failed(String)
}

public enum AgentEvent: Sendable {
    case started(task: String)
    case stepStarted(step: Int)
    /// Streaming model text for the current step (deltas).
    case modelText(step: Int, delta: String)
    case thinking(step: Int, text: String)
    /// The one-line `Action:` summary for the step, as soon as it is known.
    case actionSummary(step: Int, sentence: String)
    case performing(step: Int, action: ComputerAction)
    case runningCommand(step: Int, command: String)
    case commandFinished(step: Int, command: String, result: ShellResult)
    case commandRefused(step: Int, command: String)
    case generationStats(step: Int, stats: GenerationOutput)
    case parseIssues(step: Int, issues: [String])
    case finished(AgentOutcome)
}

/// Runs one task end-to-end: observe → think → act, until the model terminates, the step budget
/// is exhausted, or the task is cancelled.
public final class AgentSession: Sendable {

    public struct Configuration: Sendable {
        public var history = AgentHistory.Configuration()
        public var maxSteps = 50
        /// Pause after GUI actions before the next screenshot, letting the UI settle.
        public var settleDelay: Duration = .milliseconds(700)
        /// Abort after this many consecutive responses without an executable call.
        public var maxConsecutiveInvalid = 3
        /// Appended to the task so a policy trained on Linux desktops adapts to macOS.
        public var environmentNote: String? =
            "This computer is a Mac running macOS. Use the Command (cmd) key for keyboard shortcuts, and note the shell is zsh with macOS (BSD) command-line tools."
        /// Truncation limit for shell output fed back to the model (reference: 5,000).
        public var shellOutputLimit = 5_000
        public init() {}
    }

    private static let log = Logger(subsystem: "com.do.app", category: "Agent")

    public let task: String
    let model: any AgentLanguageModel
    let environment: any AgentEnvironment
    let configuration: Configuration
    let approveCommand: CommandApprover
    let onEvent: @Sendable (AgentEvent) -> Void

    public init(
        task: String,
        model: any AgentLanguageModel,
        environment: any AgentEnvironment,
        configuration: Configuration = .init(),
        approveCommand: @escaping CommandApprover = { _ in true },
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) {
        self.task = task
        self.model = model
        self.environment = environment
        self.configuration = configuration
        self.approveCommand = approveCommand
        self.onEvent = onEvent
    }

    var instruction: String {
        guard let note = configuration.environmentNote, !note.isEmpty else { return task }
        return "\(task)\n\n(\(note))"
    }

    /// Runs until done. Cancel the calling task to stop.
    public func run() async -> AgentOutcome {
        onEvent(.started(task: task))
        let outcome = await loop()
        await environment.finish()
        onEvent(.finished(outcome))
        return outcome
    }

    private func loop() async -> AgentOutcome {
        var history = AgentHistory(instruction: instruction, configuration: configuration.history)
        var pendingShellOutput: String?
        var invalidStreak = 0

        for step in 1 ... configuration.maxSteps {
            do {
                try Task.checkCancellation()
                onEvent(.stepStarted(step: step))

                // Observe.
                let observation: AgentObservation
                var screen: CapturedScreen?
                if let output = pendingShellOutput {
                    observation = .toolOutput(output)
                    pendingShellOutput = nil
                } else {
                    let captured = try await environment.captureScreen()
                    screen = captured
                    observation = .screenshot(captured.attachment)
                }

                // Think.
                let messages = history.messages(current: observation)
                let streamer = SummaryStreamer(step: step, onEvent: onEvent)
                let output = try await model.generate(messages: messages) { delta in
                    streamer.feed(delta)
                }
                try Task.checkCancellation()
                onEvent(.generationStats(step: step, stats: output))

                let turn = ResponseParser.parse(output.text)
                if !turn.thinking.isEmpty { onEvent(.thinking(step: step, text: turn.thinking)) }
                onEvent(.actionSummary(step: step, sentence: turn.actionSentence))
                if !turn.issues.isEmpty {
                    Self.log.notice("step \(step) parse issues: \(turn.issues.joined(separator: "; "))")
                    onEvent(.parseIssues(step: step, issues: turn.issues))
                }
                history.record(input: observation, response: output.text, summary: turn.actionSentence)

                // Act.
                switch turn.invocation {
                case nil:
                    invalidStreak += 1
                    if invalidStreak >= configuration.maxConsecutiveInvalid {
                        return .failed("The model did not produce a valid action \(invalidStreak) times in a row.")
                    }
                case .bash(let commands):
                    invalidStreak = 0
                    pendingShellOutput = try await runCommands(commands, step: step)
                case .computer(let actions):
                    invalidStreak = 0
                    // After a shell step the model acted without a fresh screenshot; map its
                    // coordinates onto the current screen.
                    let target: CapturedScreen
                    if let screen {
                        target = screen
                    } else {
                        target = try await environment.captureScreen()
                    }
                    for action in actions {
                        try Task.checkCancellation()
                        if case .terminate(let success, let message) = action {
                            return success ? .completed(message: message) : .gaveUp(message: message)
                        }
                        onEvent(.performing(step: step, action: action))
                        try await environment.perform(action, on: target)
                    }
                    try await Task.sleep(for: configuration.settleDelay)
                }
            } catch is CancellationError {
                return .stopped
            } catch {
                if Task.isCancelled { return .stopped }
                Self.log.error("step \(step) failed: \(error.localizedDescription)")
                return .failed(error.localizedDescription)
            }
        }
        return .stepLimitReached
    }

    private func runCommands(_ commands: [String], step: Int) async throws -> String {
        var outputs: [String] = []
        for command in commands {
            try Task.checkCancellation()
            guard await approveCommand(command) else {
                onEvent(.commandRefused(step: step, command: command))
                outputs.append("The user declined to run this command.")
                continue
            }
            onEvent(.runningCommand(step: step, command: command))
            let result = try await environment.runShell(command)
            onEvent(.commandFinished(step: step, command: command, result: result))
            var text = Self.truncate(result.output, limit: configuration.shellOutputLimit)
            if result.timedOut {
                text += (text.isEmpty ? "" : "\n") + "[Command timed out.]"
            } else if text.isEmpty && result.exitCode != 0 {
                text = "[Command exited with status \(result.exitCode).]"
            }
            outputs.append(text)
        }
        // Reference `_merge_bash_outputs`.
        var merged = outputs.first ?? ""
        for output in outputs.dropFirst() {
            if !merged.isEmpty, !output.isEmpty, !merged.hasSuffix("\n") { merged += "\n" }
            merged += output
        }
        return merged
    }

    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
            + "\n\n[Output truncated: the content above is the first \(limit.formatted()) characters; the actual output contains \(text.count.formatted()) characters.]"
    }
}

/// Forwards streamed text and emits the `Action:` line as soon as it completes, so the UI can
/// show what the model is about to do before decoding finishes.
final class SummaryStreamer: @unchecked Sendable {
    private let step: Int
    private let onEvent: @Sendable (AgentEvent) -> Void
    private let lock = OSAllocatedUnfairLock(initialState: (buffer: "", announced: false))

    init(step: Int, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        self.step = step
        self.onEvent = onEvent
    }

    func feed(_ delta: String) {
        onEvent(.modelText(step: step, delta: delta))
        let sentence: String? = lock.withLock { state in
            guard !state.announced else { return nil }
            state.buffer += delta
            guard let close = state.buffer.range(of: "</think>") else { return nil }
            let tail = state.buffer[close.upperBound...]
            guard let actionRange = tail.range(of: "Action:") else { return nil }
            let rest = tail[actionRange.upperBound...]
            guard let newline = rest.firstIndex(of: "\n") else { return nil }
            state.announced = true
            return rest[..<newline].trimmingCharacters(in: .whitespaces)
        }
        if let sentence, !sentence.isEmpty { onEvent(.actionSummary(step: step, sentence: sentence)) }
    }
}
