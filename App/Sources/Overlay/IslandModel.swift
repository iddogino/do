import DoCore
import Foundation
import Observation

/// A shell command waiting for the user's go-ahead.
struct ApprovalRequest: Identifiable, Equatable {
    let id = UUID()
    let command: String
    let reasons: [String]
}

/// Everything the island displays. Mutated only on the main actor by `AppController`.
@MainActor
@Observable
final class IslandModel {
    enum Phase: Equatable {
        case hidden
        case preparing(message: String, progress: Double?)
        case working
        case finished(AgentOutcome)
    }

    var style: IslandStyle = .floating
    var phase: Phase = .hidden
    var task = ""
    var step = 0
    /// The rotating one-line status (current action sentence or activity).
    var status = ""
    /// Latest reasoning, for the expanded view.
    var thinking = ""
    /// Recent `Action:` summaries, newest last.
    var history: [String] = []
    var expanded = false
    /// First Escape press: the next one stops the run.
    var escapeArmed = false
    var stopping = false
    var approval: ApprovalRequest?
    /// True while the agent is executing input, so the island lets clicks pass through.
    var agentActing = false

    /// Called by the X button / Stop button.
    var onStop: () -> Void = {}
    var onApprovalDecision: (Bool) -> Void = { _ in }

    var isRunning: Bool {
        switch phase {
        case .preparing, .working: true
        default: false
        }
    }

    /// What the status line should show right now.
    var displayStatus: String {
        if stopping { return "Stopping…" }
        if escapeArmed { return "Stop now — press Escape again" }
        if approval != nil { return "Waiting for your approval" }
        switch phase {
        case .hidden: return ""
        case .preparing(let message, _): return message
        case .working: return status.isEmpty ? "Looking at the screen…" : status
        case .finished(let outcome): return Self.describe(outcome)
        }
    }

    static func describe(_ outcome: AgentOutcome) -> String {
        switch outcome {
        case .completed(let message): message?.isEmpty == false ? message! : "Done"
        case .gaveUp(let message): message?.isEmpty == false ? message! : "Couldn’t finish the task"
        case .stopped: "Stopped"
        case .stepLimitReached: "Stopped after reaching the step limit"
        case .failed(let message): message
        }
    }

    func reset(task: String) {
        self.task = task
        step = 0
        status = ""
        thinking = ""
        history = []
        expanded = false
        escapeArmed = false
        stopping = false
        approval = nil
        agentActing = false
    }

    func pushHistory(_ sentence: String) {
        guard !sentence.isEmpty, history.last != sentence else { return }
        history.append(sentence)
        if history.count > 6 { history.removeFirst(history.count - 6) }
    }
}
