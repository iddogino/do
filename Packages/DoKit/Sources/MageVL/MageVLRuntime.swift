import DoCore
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Tokenizers
import os

public enum MageVLRuntimeError: Error, LocalizedError {
    case missingFile(String)
    case unsupportedModelType(String)
    case promptTooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let f): "The model folder is missing \(f)."
        case .unsupportedModelType(let t): "Unsupported model type \"\(t)\" (expected mage_vl)."
        case .promptTooLong(let n): "The prompt is too long (\(n) tokens)."
        }
    }
}

/// Owns a loaded Mage-VL model and serves agent turns.
///
/// Two caches make multi-step agent loops cheap:
/// * **Prompt cache** - the KV cache of the previous turn is kept. A new prompt reuses its
///   longest common prefix (compared token-by-token *and* image-by-image, so two different
///   screenshots of the same size never alias), trimming the rest.
/// * **Vision cache** - visual tokens are memoised per `ImageAttachment.id`, so a screenshot
///   that stays in the sliding window is encoded once.
public actor MageVLRuntime: AgentLanguageModel {

    public struct Options: Sendable {
        /// Shared budget across `<think>`, `Action:` and `<tool_call>` (reference: 4096).
        public var maxTokens = 4096
        /// Reference OSWorld configuration: temperature 0.7, top-p 0.8. 0 = greedy.
        public var temperature: Float = 0.7
        public var topP: Float = 0.8
        /// Upper bound on pixels per screenshot fed to the vision tower.
        public var maxImagePixels: Int? = nil
        /// Prefill chunk size (tokens per forward during prompt processing).
        public var prefillChunk = 1024
        /// Hard cap on prompt length (the model was trained with a 32K window).
        public var maxPromptTokens = 32_768

        public init() {}
    }

    /// One prompt position: a text token, or the i-th visual token of an image.
    private struct PromptKey: Equatable {
        var token: Int32
        var image: UUID?
    }

    private struct VisionEntry {
        var features: MLXArray
        var tokenCount: Int
    }

    private static let log = Logger(subsystem: "com.do.app", category: "MageVL")

    /// Inference is long, synchronous Metal work: run it on a dedicated serial queue instead of
    /// blocking a thread of Swift's cooperative pool.
    private let queue = DispatchSerialQueue(label: "com.do.mage-vl.inference", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public nonisolated let modelDirectory: URL
    public var options: Options

    private let model: MageVLModel
    private let tokenizer: any Tokenizers.Tokenizer
    private let processor: MageVLImageProcessor
    private let eosTokenIds: Set<Int>

    private var cache: [KVCache]?
    private var cachedKeys: [PromptKey] = []
    private var visionCache: [UUID: VisionEntry] = [:]
    private var visionCacheOrder: [UUID] = []
    private let visionCacheCapacity = 6

    // MARK: Loading

    public static func load(directory: URL, options: Options = .init()) async throws -> MageVLRuntime {
        for file in ["config.json", "tokenizer.json", "tokenizer_config.json", "preprocessor_config.json"] {
            guard FileManager.default.fileExists(atPath: directory.appending(path: file).path) else {
                throw MageVLRuntimeError.missingFile(file)
            }
        }
        let configData = try Data(contentsOf: directory.appending(path: "config.json"))
        let config = try JSONDecoder().decode(MageVLConfiguration.self, from: configData)
        guard config.modelType == "mage_vl" else { throw MageVLRuntimeError.unsupportedModelType(config.modelType) }
        let baseConfig = try JSONDecoder().decode(BaseConfiguration.self, from: configData)

        let preprocessorData = try Data(contentsOf: directory.appending(path: "preprocessor_config.json"))
        let processorConfig = try JSONDecoder().decode(MageVLImageProcessorConfiguration.self, from: preprocessorData)

        // Keep MLX's buffer cache bounded: screenshots create large transient activations.
        Memory.cacheLimit = 1 << 30

        let model = MageVLModel(config)
        try await loadWeights(
            modelDirectory: directory, model: model, perLayerQuantization: baseConfig.perLayerQuantization)

        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)

        var eos = baseConfig.effectiveEOSTokenIds
        for special in ["<|im_end|>", "<|endoftext|>"] {
            if let id = tokenizer.convertTokenToId(special) { eos.insert(id) }
        }

        return MageVLRuntime(
            directory: directory, model: model, tokenizer: tokenizer,
            processor: MageVLImageProcessor(config: processorConfig), eos: eos, options: options)
    }

    private init(
        directory: URL, model: MageVLModel, tokenizer: any Tokenizers.Tokenizer,
        processor: MageVLImageProcessor, eos: Set<Int>, options: Options
    ) {
        self.modelDirectory = directory
        self.model = model
        self.tokenizer = tokenizer
        self.processor = processor
        self.eosTokenIds = eos
        self.options = options
    }

    public func setOptions(_ options: Options) {
        self.options = options
    }

    /// Returns MLX's freed GPU buffers to the system (call after dropping a runtime).
    public static func releaseCachedMemory() {
        Memory.clearCache()
    }

    /// Drops all cached state (KV cache and vision features).
    public func reset() {
        cache = nil
        cachedKeys = []
        visionCache = [:]
        visionCacheOrder = []
        Memory.clearCache()
    }

    // MARK: Warm-up

    /// Runs a tiny forward pass so Metal kernels are compiled before the first real turn.
    public func warmUp() {
        let tokens = MLXArray(tokenizer.encode(text: "<|im_start|>user\nhi<|im_end|>\n").map { Int32($0) })
            .expandedDimensions(axis: 0)
        let warmCache = (try? model.newCache(parameters: nil)) ?? []
        eval(model(tokens, cache: warmCache))
    }

    // MARK: Generation

    public func generate(
        messages: [ChatMessage],
        onText: @Sendable @escaping (String) -> Void
    ) async throws -> GenerationOutput {
        let rendered = QwenChatTemplate.render(messages)
        return try generate(rendered: rendered, onText: onText)
    }

    /// Tokenizes `rendered`, expanding each image pad to its visual-token count.
    private func promptKeys(for rendered: QwenChatTemplate.Rendered) throws -> [PromptKey] {
        let base = tokenizer.encode(text: rendered.text, addSpecialTokens: false)
        let padId = Int32(model.config.imageTokenId)
        var keys: [PromptKey] = []
        keys.reserveCapacity(base.count + rendered.images.count * 1500)
        var imageIndex = 0
        for t in base {
            let token = Int32(t)
            if token == padId {
                precondition(imageIndex < rendered.images.count, "more image pads than images")
                let attachment = rendered.images[imageIndex]
                let count = try processor.tokenCount(
                    width: attachment.image.width, height: attachment.image.height,
                    maxPixels: options.maxImagePixels)
                keys.append(contentsOf: repeatElement(PromptKey(token: padId, image: attachment.id), count: count))
                imageIndex += 1
            } else {
                keys.append(PromptKey(token: token, image: nil))
            }
        }
        precondition(imageIndex == rendered.images.count, "fewer image pads than images")
        return keys
    }

    private func visionFeatures(for attachment: ImageAttachment) throws -> VisionEntry {
        if let hit = visionCache[attachment.id] { return hit }
        let processed = try processor.process(attachment.image, maxPixels: options.maxImagePixels)
        let features = model.encodeImage(processed.pixels, grid: processed.grid)
        eval(features)
        let entry = VisionEntry(features: features, tokenCount: processed.tokenCount)
        visionCache[attachment.id] = entry
        visionCacheOrder.append(attachment.id)
        while visionCacheOrder.count > visionCacheCapacity {
            visionCache.removeValue(forKey: visionCacheOrder.removeFirst())
        }
        return entry
    }

    private func generate(
        rendered: QwenChatTemplate.Rendered,
        onText: @Sendable @escaping (String) -> Void
    ) throws -> GenerationOutput {
        let started = Date()
        let keys = try promptKeys(for: rendered)
        guard keys.count < options.maxPromptTokens else { throw MageVLRuntimeError.promptTooLong(keys.count) }
        precondition(keys.count > 1 && keys[keys.count - 1].image == nil, "prompt must end with a text token")

        // 1. Reuse the longest cached prefix (at least one token must be fed fresh).
        var reuse = 0
        if let cache, !cache.isEmpty {
            let limit = min(cachedKeys.count, keys.count - 1, cache[0].offset)
            while reuse < limit, cachedKeys[reuse] == keys[reuse] { reuse += 1 }
            let excess = cache[0].offset - reuse
            if excess > 0 {
                if cache.allSatisfy({ $0.isTrimmable }) {
                    for layer in cache { _ = layer.trim(excess) }
                } else {
                    reuse = 0
                }
            }
        }
        if reuse == 0 {
            cache = try model.newCache(parameters: nil)
            cachedKeys = []
        }
        guard let cache else { preconditionFailure() }

        // 2. Visual tokens for every image pad in the fresh suffix [reuse, count - 1).
        let suffix = keys[reuse ..< (keys.count - 1)]
        var visualParts: [MLXArray] = []
        var imagesById: [UUID: ImageAttachment] = [:]
        for image in rendered.images { imagesById[image.id] = image }
        var cursor = suffix.startIndex
        while cursor < suffix.endIndex {
            guard let imageId = suffix[cursor].image else {
                cursor += 1
                continue
            }
            // The run of pads for this image inside the suffix, and where the image began.
            var runEnd = cursor
            while runEnd < suffix.endIndex, suffix[runEnd].image == imageId { runEnd += 1 }
            var imageStart = cursor
            while imageStart > 0, keys[imageStart - 1].image == imageId { imageStart -= 1 }
            guard let attachment = imagesById[imageId] else { preconditionFailure("unknown image") }
            let entry = try visionFeatures(for: attachment)
            let lo = cursor - imageStart
            let hi = runEnd - imageStart
            visualParts.append(lo == 0 && hi == entry.tokenCount ? entry.features : entry.features[lo ..< hi])
            cursor = runEnd
        }

        // 3. Prefill the suffix in chunks.
        let suffixTokens = MLXArray(suffix.map(\.token)).expandedDimensions(axis: 0)
        let visual = visualParts.isEmpty ? nil : concatenated(visualParts, axis: 0)
        if suffix.count > 0 {
            let embeddings = model.embed(tokens: suffixTokens, visual: visual)
            var start = 0
            while start < suffix.count {
                try Task.checkCancellation()
                let end = min(start + options.prefillChunk, suffix.count)
                _ = model.forward(embeddings: embeddings[0..., start ..< end, 0...], cache: cache)
                eval(cache)
                start = end
            }
        }
        visualParts.removeAll()
        let prefillSeconds = Date().timeIntervalSince(started)

        // 4. Decode from the final prompt token.
        let last = MLXArray([keys[keys.count - 1].token]).expandedDimensions(axis: 0)
        var parameters = GenerateParameters(
            maxTokens: options.maxTokens, temperature: options.temperature, topP: options.topP)
        parameters.prefill.stepSize = options.prefillChunk
        var iterator = try TokenIterator(
            input: LMInput(tokens: last), model: model, cache: cache, parameters: parameters)

        let decodeStarted = Date()
        var generated: [Int] = []
        var detokenizer = StreamingDetokenizer(tokenizer: tokenizer)
        var text = ""
        while let token = iterator.next() {
            if Task.isCancelled { break }
            if eosTokenIds.contains(token) { break }
            generated.append(token)
            detokenizer.append(token)
            if let delta = detokenizer.next(), !delta.isEmpty {
                text += delta
                onText(delta)
            }
            if generated.count >= options.maxTokens { break }
        }
        if let tail = detokenizer.flush(), !tail.isEmpty {
            text += tail
            onText(tail)
        }
        let decodeSeconds = Date().timeIntervalSince(decodeStarted)

        // 5. Remember what the KV cache now holds.
        let produced = keys + generated.map { PromptKey(token: Int32($0), image: nil) }
        let offset = cache[0].offset
        let valid = min(offset, produced.count)
        if offset > valid, cache.allSatisfy({ $0.isTrimmable }) {
            for layer in cache { _ = layer.trim(offset - valid) }
        }
        cachedKeys = Array(produced.prefix(valid))
        if Task.isCancelled {
            // A cancelled turn leaves the cache in an unknown state; start clean next time.
            self.cache = nil
            cachedKeys = []
        }
        Memory.clearCache()

        Self.log.info(
            "turn: prompt \(keys.count) (reused \(reuse)) prefill \(prefillSeconds, format: .fixed(precision: 2))s, generated \(generated.count) in \(decodeSeconds, format: .fixed(precision: 2))s"
        )
        try Task.checkCancellation()
        return GenerationOutput(
            text: text, promptTokens: keys.count, reusedPromptTokens: reuse, generatedTokens: generated.count,
            prefillSeconds: prefillSeconds, decodeSeconds: decodeSeconds)
    }
}

/// Incremental detokenizer that only emits complete UTF-8 and is robust to BPE merges that
/// rewrite the tail of the decoded string.
struct StreamingDetokenizer {
    let tokenizer: any Tokenizers.Tokenizer
    private var segment: [Int] = []
    private var emitted = ""

    init(tokenizer: any Tokenizers.Tokenizer) {
        self.tokenizer = tokenizer
    }

    mutating func append(_ token: Int) {
        segment.append(token)
    }

    mutating func next() -> String? {
        let decoded = tokenizer.decode(tokens: segment, skipSpecialTokens: false)
        if decoded.hasSuffix("\u{FFFD}") { return nil }
        let common = zip(decoded.unicodeScalars, emitted.unicodeScalars).prefix { $0 == $1 }.count
        let delta = String(String.UnicodeScalarView(decoded.unicodeScalars.dropFirst(common)))
        emitted = decoded
        if decoded.hasSuffix("\n") {
            segment.removeAll()
            emitted = ""
        }
        return delta
    }

    mutating func flush() -> String? {
        guard !segment.isEmpty else { return nil }
        let decoded = tokenizer.decode(tokens: segment, skipSpecialTokens: false)
        let common = zip(decoded.unicodeScalars, emitted.unicodeScalars).prefix { $0 == $1 }.count
        segment.removeAll()
        defer { emitted = "" }
        let delta = String(String.UnicodeScalarView(decoded.unicodeScalars.dropFirst(common)))
        return delta.replacingOccurrences(of: "\u{FFFD}", with: "")
    }
}
