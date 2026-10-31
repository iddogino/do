import CoreGraphics
import CryptoKit
import Foundation
import Testing

@testable import DoCore

func blankImage(_ w: Int = 8, _ h: Int = 8) -> CGImage {
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return ctx.makeImage()!
}

@Suite("AgentHistory")
struct AgentHistoryTests {

    @Test func systemPromptIsVerbatim() {
        let digest = SHA256.hash(data: Data(MageSystemPrompt.hybrid.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == MageSystemPrompt.sha256)
        #expect(MageSystemPrompt.hybrid.hasPrefix("You are a multi-purpose intelligent assistant."))
        #expect(MageSystemPrompt.hybrid.hasSuffix("- If finishing, use action=terminate."))
    }

    @Test func firstStepMatchesReferenceLayout() {
        let history = AgentHistory(instruction: "Turn on dark mode.")
        let shot = ImageAttachment(image: blankImage())
        let messages = history.messages(current: .screenshot(shot))
        #expect(messages.count == 2)
        #expect(messages[0].role == .system)
        let rendered = QwenChatTemplate.render(messages)
        let expectedUser =
            "<|im_start|>user\n<|vision_start|><|image_pad|><|vision_end|>\nPlease generate the next move according to the UI screenshot, instruction and previous actions.\n\nInstruction: Turn on dark mode.\n\nPrevious actions:\nNone<|im_end|>\n<|im_start|>assistant\n<think>\n"
        #expect(rendered.text.hasPrefix("<|im_start|>system\nYou are a multi-purpose"))
        #expect(rendered.text.hasSuffix(expectedUser))
        #expect(rendered.images.map(\.id) == [shot.id])
    }

    @Test func slidingWindowKeepsThreeStepsAndThreeImages() {
        var history = AgentHistory(instruction: "Task")
        var shots: [ImageAttachment] = []
        for i in 1 ... 5 {
            let shot = ImageAttachment(image: blankImage())
            shots.append(shot)
            history.record(
                input: .screenshot(shot),
                response: "r\(i)</think>\n\nAction: Step \(i).\n\n<tool_call>{}</tool_call>",
                summary: "Step \(i).")
        }
        let current = ImageAttachment(image: blankImage())
        let messages = history.messages(current: .screenshot(current))
        // system + first user (step 3) + 3 × (assistant, user)
        #expect(messages.count == 2 + 2 * 3)
        let rendered = QwenChatTemplate.render(messages)
        #expect(rendered.text.contains("Previous actions:\nStep 1: Step 1.\nStep 2: Step 2."))
        // Window = steps 3,4,5 + current(6); keep the 3 most recent images: 4, 5, 6.
        #expect(rendered.images.map(\.id) == [shots[3].id, shots[4].id, current.id])
        #expect(rendered.text.contains("[This screenshot has been collapsed.]\nPlease generate"))
        // Assistant turns after the query keep their reasoning, re-wrapped in <think>.
        #expect(rendered.text.contains("<|im_start|>assistant\n<think>\nr3\n</think>\n\nAction: Step 3."))
    }

    @Test func shellObservationsUseToolOutputLead() {
        var history = AgentHistory(instruction: "Task")
        history.record(input: .screenshot(ImageAttachment(image: blankImage())), response: "a", summary: "A.")
        history.record(input: .toolOutput("out1"), response: "b", summary: "B.")
        history.record(input: .toolOutput("out2"), response: "c", summary: "C.")
        history.record(input: .toolOutput("out3"), response: "d", summary: "D.")
        let messages = history.messages(current: .toolOutput("out4"))
        let first = messages[1].renderedContent(imagePlaceholder: "<img>")
        #expect(first.hasPrefix("Please generate the next move according to the tool output"))
        #expect(first.hasSuffix("<tool_response>\nout1\n</tool_response>"))
        #expect(first.contains("Previous actions:\nStep 1: A."))
        let last = messages.last!.renderedContent(imagePlaceholder: "<img>")
        #expect(last == "<tool_response>\nout4\n</tool_response>")
    }

    @Test func foldingMergesPairsOnceHistoryIsLong() {
        let summaries = (1 ... 48).map { "Do thing \($0)." }
        // cap = 49 - 3 - 1 = 45 -> 47 folded => 2 merges
        let lines = AgentHistory.previousActionLines(
            summaries: summaries, folded: 47, historyN: 3, doubleFoldedMaxStep: 49, triggerOffset: 1)
        #expect(lines.count == 45)
        #expect(lines[0] == "Step 1: Do thing 1 and Do thing 2.")
        #expect(lines[1] == "Step 2: Do thing 3 and Do thing 4.")
        #expect(lines[2] == "Step 3: Do thing 5.")
    }

    @Test func mergeTwoNormalizesPunctuation() {
        #expect(AgentHistory.mergeTwo("Open  Finder...", "click File") == "Open Finder and click File.")
        #expect(AgentHistory.mergeTwo("", "") == "Performing action")
        #expect(AgentHistory.mergeTwo("Ask?", "") == "Ask?")
    }
}

@Suite("QwenChatTemplate")
struct QwenChatTemplateTests {
    @Test func olderAssistantTurnsBeforeQueryDropReasoning() {
        let messages = [
            ChatMessage(role: .system, text: "S"),
            ChatMessage(role: .user, text: "first"),
            ChatMessage(role: .assistant, text: "thinking</think>\n\nanswer"),
            ChatMessage(role: .user, text: "second"),
        ]
        let text = QwenChatTemplate.render(messages).text
        #expect(
            text
                == "<|im_start|>system\nS<|im_end|>\n<|im_start|>user\nfirst<|im_end|>\n<|im_start|>assistant\nanswer<|im_end|>\n<|im_start|>user\nsecond<|im_end|>\n<|im_start|>assistant\n<think>\n"
        )
    }

    @Test func stripHelpersMatchPython() {
        #expect("\n\nabc\n".lstrip("\n") == "abc\n")
        #expect("\nabc\n\n".rstrip("\n") == "\nabc")
        #expect("\n abc \n".strip("\n") == " abc ")
    }
}
