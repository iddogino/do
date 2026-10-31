import Foundation

/// What the agent observes at the start of a step: a screenshot after GUI actions, or the text
/// output after shell commands.
public enum AgentObservation: Sendable {
    case screenshot(ImageAttachment)
    case toolOutput(String)

    var isImage: Bool {
        if case .screenshot = self { return true }
        return false
    }
}

/// Mage-VL-Cowork's asymmetric working memory, ported from the reference `MAGEHybridAgent`:
///
/// * Steps older than the window (`1 … t-historyN-1`) are folded into single-line `Action:`
///   summaries under "Previous actions", pairwise-merged once the list grows long.
/// * The last `historyN` steps keep their full assistant responses, and up to `imagesToKeep`
///   of the most recent screenshots stay visible; older ones are replaced by a
///   "collapsed" placeholder.
public struct AgentHistory: Sendable {
    public struct Configuration: Sendable {
        public var historyN = 3
        public var imagesToKeep = 3
        public var maxSteps: Int? = 50
        public var doubleFoldedMaxStep = 49
        public var doubleFoldTriggerOffset = 1
        public init() {}
    }

    public let instruction: String
    public let configuration: Configuration
    public private(set) var inputs: [AgentObservation] = []
    public private(set) var responses: [String] = []
    public private(set) var summaries: [String] = []

    public init(instruction: String, configuration: Configuration = .init()) {
        self.instruction = instruction
        self.configuration = configuration
    }

    public var completedSteps: Int { responses.count }

    /// Records a finished step: the observation it was given, the raw response, and its
    /// one-line summary.
    public mutating func record(input: AgentObservation, response: String, summary: String) {
        inputs.append(input)
        responses.append(response)
        summaries.append(summary)
    }

    /// Builds the prompt for the next step given its observation.
    public func messages(current: AgentObservation) -> [ChatMessage] {
        let currentStep = responses.count + 1
        let all = inputs + [current]
        let historyN = configuration.historyN
        let startStep = max(1, currentStep - historyN)

        let capBonus = (configuration.maxSteps.map { currentStep == $0 } ?? false) && configuration.doubleFoldedMaxStep > 0
        let previous = Self.previousActionLines(
            summaries: summaries, folded: startStep - 1, historyN: historyN,
            doubleFoldedMaxStep: configuration.doubleFoldedMaxStep,
            triggerOffset: configuration.doubleFoldTriggerOffset - (capBonus ? 1 : 0))
        let previousText = previous.isEmpty ? "None" : previous.joined(separator: "\n")

        let imageSteps = (startStep ... currentStep).filter { all[$0 - 1].isImage }
        let kept = Set(configuration.imagesToKeep > 0 ? imageSteps.suffix(configuration.imagesToKeep) : [])

        var messages = [ChatMessage(role: .system, text: MageSystemPrompt.hybrid)]
        messages.append(
            ChatMessage(
                role: .user,
                parts: firstUserParts(all[startStep - 1], keepImage: kept.contains(startStep), previous: previousText)))
        for step in startStep ..< currentStep {
            messages.append(ChatMessage(role: .assistant, text: responses[step - 1]))
            messages.append(
                ChatMessage(role: .user, parts: toolResponseParts(all[step], keepImage: kept.contains(step + 1))))
        }
        return messages
    }

    // MARK: Message pieces (verbatim formats from the reference harness)

    func instructionContext(previous: String, afterShell: Bool) -> String {
        let lead =
            afterShell
            ? "Please generate the next move according to the tool output, instruction and previous actions."
            : "Please generate the next move according to the UI screenshot, instruction and previous actions."
        return "\(lead)\n\nInstruction: \(instruction)\n\nPrevious actions:\n\(previous)"
    }

    func firstUserParts(_ input: AgentObservation, keepImage: Bool, previous: String) -> [ChatPart] {
        switch input {
        case .toolOutput(let output):
            let context = instructionContext(previous: previous, afterShell: true)
            return [.text("\(context)\n\n<tool_response>\n\(output)\n</tool_response>")]
        case .screenshot(let image):
            let text = "\n" + instructionContext(previous: previous, afterShell: false)
            return keepImage ? [.image(image), .text(text)] : [.text("[This screenshot has been collapsed.]" + text)]
        }
    }

    func toolResponseParts(_ input: AgentObservation, keepImage: Bool) -> [ChatPart] {
        switch input {
        case .toolOutput(let output):
            return [.text("<tool_response>\n\(output)\n</tool_response>")]
        case .screenshot(let image):
            return keepImage
                ? [.text("<tool_response>\n"), .image(image), .text("\n</tool_response>")]
                : [.text("<tool_response>\n[This screenshot has been collapsed.]\n</tool_response>")]
        }
    }

    // MARK: Folding

    static func previousActionLines(
        summaries: [String], folded: Int, historyN: Int, doubleFoldedMaxStep: Int, triggerOffset: Int
    ) -> [String] {
        guard folded > 0 else { return [] }
        precondition(folded <= summaries.count, "action-summary history out of sync")
        guard doubleFoldedMaxStep > 0 else {
            return (0 ..< folded).map { "Step \($0 + 1): \(summaries[$0])" }
        }
        let cap = max(1, doubleFoldedMaxStep - historyN - triggerOffset)
        var merges = max(0, folded - cap)
        if 2 * merges > folded { merges = folded / 2 }
        var descriptions: [String] = (0 ..< merges).map { mergeTwo(summaries[2 * $0], summaries[2 * $0 + 1]) }
        descriptions += summaries[(2 * merges) ..< folded]
        return descriptions.enumerated().map { "Step \($0.offset + 1): \($0.element)" }
    }

    static func mergeTwo(_ first: String, _ second: String) -> String {
        func squash(_ s: String) -> String {
            s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let a = squash(first)
        let b = squash(second)
        if a.isEmpty && b.isEmpty { return "Performing action" }
        var head = a
        while head.hasSuffix(".") || head.hasSuffix(" ") { head.removeLast() }
        var merged = (!head.isEmpty && !b.isEmpty) ? "\(head) and \(b)" : (head.isEmpty ? b : head)
        merged = merged.trimmingCharacters(in: .whitespaces)
        if merged.isEmpty { return "Performing action" }
        if let last = merged.last, !".!?".contains(last) { merged += "." }
        return merged
    }
}
