import CoreGraphics
import Foundation

/// An image attached to a chat message. Identity matters: the inference runtime caches vision
/// features and KV state per attachment `id`, so the same screenshot must keep the same id
/// across agent steps.
public struct ImageAttachment: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let image: CGImage

    public init(id: UUID = UUID(), image: CGImage) {
        self.id = id
        self.image = image
    }
}

public enum ChatPart: Sendable {
    case text(String)
    case image(ImageAttachment)
}

public struct ChatMessage: Sendable {
    public enum Role: String, Sendable {
        case system, user, assistant
    }

    public var role: Role
    public var parts: [ChatPart]

    public init(role: Role, parts: [ChatPart]) {
        self.role = role
        self.parts = parts
    }

    public init(role: Role, text: String) {
        self.init(role: role, parts: [.text(text)])
    }

    /// The message's text with image placeholders, as the chat template renders it.
    public func renderedContent(imagePlaceholder: String) -> String {
        parts.map {
            switch $0 {
            case .text(let s): s
            case .image: imagePlaceholder
            }
        }.joined()
    }

    public var images: [ImageAttachment] {
        parts.compactMap {
            if case .image(let a) = $0 { return a }
            return nil
        }
    }
}

/// Anything that can turn a conversation into the next assistant message.
public protocol AgentLanguageModel: Sendable {
    /// Generates the next assistant turn, streaming text deltas to `onText`.
    func generate(
        messages: [ChatMessage],
        onText: @Sendable @escaping (String) -> Void
    ) async throws -> GenerationOutput
}

public struct GenerationOutput: Sendable {
    public var text: String
    public var promptTokens: Int
    public var reusedPromptTokens: Int
    public var generatedTokens: Int
    public var prefillSeconds: Double
    public var decodeSeconds: Double

    public init(
        text: String, promptTokens: Int = 0, reusedPromptTokens: Int = 0, generatedTokens: Int = 0,
        prefillSeconds: Double = 0, decodeSeconds: Double = 0
    ) {
        self.text = text
        self.promptTokens = promptTokens
        self.reusedPromptTokens = reusedPromptTokens
        self.generatedTokens = generatedTokens
        self.prefillSeconds = prefillSeconds
        self.decodeSeconds = decodeSeconds
    }

    public var decodeTokensPerSecond: Double {
        decodeSeconds > 0 ? Double(generatedTokens) / decodeSeconds : 0
    }
}
