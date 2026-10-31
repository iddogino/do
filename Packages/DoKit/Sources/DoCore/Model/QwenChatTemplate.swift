import Foundation

/// Exact Swift rendering of the Qwen3 chat template shipped with Mage-VL-Cowork
/// (`chat_template.jinja`), for the subset of features the agent uses: no `tools` argument
/// (the tool schema lives in the system prompt), `enable_thinking` left at its default (on),
/// `add_generation_prompt = true`, and no `add_vision_id`.
///
/// Rendering in Swift instead of evaluating Jinja keeps the hot path deterministic and lets the
/// output be unit-tested byte-for-byte against the Python reference.
public enum QwenChatTemplate {
    public static let imageStart = "<|vision_start|>"
    public static let imagePad = "<|image_pad|>"
    public static let imageEnd = "<|vision_end|>"
    public static let imagePlaceholder = imageStart + imagePad + imageEnd

    public struct Rendered: Sendable {
        /// Prompt text with exactly one `<|image_pad|>` per image.
        public var text: String
        /// Images in prompt order.
        public var images: [ImageAttachment]
    }

    public static func render(_ messages: [ChatMessage], addGenerationPrompt: Bool = true) -> Rendered {
        var out = ""
        var images: [ImageAttachment] = []
        let contents = messages.map { $0.renderedContent(imagePlaceholder: imagePlaceholder) }

        // Leading system message.
        var startIndex = 0
        if let first = messages.first, first.role == .system {
            out += "<|im_start|>system\n" + contents[0] + "<|im_end|>\n"
            images += first.images
            startIndex = 1
        }

        // The last "real" user query: the latest user message that is not a pure
        // <tool_response> wrapper. Assistant turns after it keep their reasoning.
        var lastQueryIndex = messages.count - 1
        for index in stride(from: messages.count - 1, through: 0, by: -1) where messages[index].role == .user {
            let c = contents[index]
            if !(c.hasPrefix("<tool_response>") && c.hasSuffix("</tool_response>")) {
                lastQueryIndex = index
                break
            }
        }

        for index in startIndex ..< messages.count {
            let message = messages[index]
            var content = contents[index]
            images += message.images
            switch message.role {
            case .user, .system:
                out += "<|im_start|>\(message.role.rawValue)\n" + content + "<|im_end|>\n"
            case .assistant:
                var reasoning = ""
                if content.contains("</think>") {
                    let beforeClose = content.components(separatedBy: "</think>")[0]
                    reasoning = beforeClose.rstrip("\n").components(separatedBy: "<think>").last ?? ""
                    reasoning = reasoning.lstrip("\n")
                    content = (content.components(separatedBy: "</think>").last ?? "").lstrip("\n")
                }
                let isLast = index == messages.count - 1
                if index > lastQueryIndex, isLast || !reasoning.isEmpty {
                    out += "<|im_start|>assistant\n<think>\n" + reasoning.strip("\n") + "\n</think>\n\n"
                        + content.lstrip("\n")
                } else {
                    out += "<|im_start|>assistant\n" + content
                }
                out += "<|im_end|>\n"
            }
        }

        if addGenerationPrompt {
            out += "<|im_start|>assistant\n<think>\n"
        }
        return Rendered(text: out, images: images)
    }
}

extension String {
    /// Python `str.rstrip(chars)`.
    public func rstrip(_ chars: String) -> String {
        let set = Set(chars)
        var s = Substring(self)
        while let last = s.last, set.contains(last) { s = s.dropLast() }
        return String(s)
    }

    /// Python `str.lstrip(chars)`.
    public func lstrip(_ chars: String) -> String {
        let set = Set(chars)
        var s = Substring(self)
        while let first = s.first, set.contains(first) { s = s.dropFirst() }
        return String(s)
    }

    /// Python `str.strip(chars)`.
    public func strip(_ chars: String) -> String { lstrip(chars).rstrip(chars) }
}
