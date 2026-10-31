import Foundation
import MLX
import MLXLMCommon
import MLXNN

// Port of mlx-vlm `mlx_vlm/models/mage_vl/{mage_vl,language}.py` (v0.7.11).
// The decoder is stock Qwen3-4B-Instruct-2507 with plain 1-D RoPE, so visual tokens simply
// occupy sequential positions and a warm KV cache needs no extra positional state.

enum MageVLLanguage {

    final class Attention: Module {
        let heads: Int
        let kvHeads: Int
        let scale: Float
        @ModuleInfo(key: "q_proj") var wq: Linear
        @ModuleInfo(key: "k_proj") var wk: Linear
        @ModuleInfo(key: "v_proj") var wv: Linear
        @ModuleInfo(key: "o_proj") var wo: Linear
        @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
        @ModuleInfo(key: "k_norm") var kNorm: RMSNorm
        let rope: RoPELayer

        init(_ c: MageVLConfiguration.TextConfiguration) {
            heads = c.numAttentionHeads
            kvHeads = c.numKeyValueHeads
            scale = pow(Float(c.headDim), -0.5)
            _wq.wrappedValue = Linear(c.hiddenSize, heads * c.headDim, bias: false)
            _wk.wrappedValue = Linear(c.hiddenSize, kvHeads * c.headDim, bias: false)
            _wv.wrappedValue = Linear(c.hiddenSize, kvHeads * c.headDim, bias: false)
            _wo.wrappedValue = Linear(heads * c.headDim, c.hiddenSize, bias: false)
            _qNorm.wrappedValue = RMSNorm(dimensions: c.headDim, eps: c.rmsNormEps)
            _kNorm.wrappedValue = RMSNorm(dimensions: c.headDim, eps: c.rmsNormEps)
            rope = initializeRope(
                dims: c.headDim, base: c.ropeTheta, traditional: false, scalingConfig: nil,
                maxPositionEmbeddings: c.maxPositionEmbeddings)
        }

        func callAsFunction(
            _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
        ) -> MLXArray {
            let (B, L) = (x.dim(0), x.dim(1))
            var q = qNorm(wq(x).reshaped(B, L, heads, -1)).transposed(0, 2, 1, 3)
            var k = kNorm(wk(x).reshaped(B, L, kvHeads, -1)).transposed(0, 2, 1, 3)
            let v = wv(x).reshaped(B, L, kvHeads, -1).transposed(0, 2, 1, 3)

            let offset = cache?.ropeOffset
            q = applyRotaryPosition(rope, to: q, offset: offset)
            k = applyRotaryPosition(rope, to: k, offset: offset)

            let out = attentionWithCacheUpdate(
                queries: q, keys: k, values: v, cache: cache, scale: scale, mask: mask)
            return wo(out.transposed(0, 2, 1, 3).reshaped(B, L, -1))
        }
    }

    final class MLP: Module, UnaryLayer {
        @ModuleInfo(key: "gate_proj") var gate: Linear
        @ModuleInfo(key: "down_proj") var down: Linear
        @ModuleInfo(key: "up_proj") var up: Linear

        init(_ c: MageVLConfiguration.TextConfiguration) {
            _gate.wrappedValue = Linear(c.hiddenSize, c.intermediateSize, bias: false)
            _down.wrappedValue = Linear(c.intermediateSize, c.hiddenSize, bias: false)
            _up.wrappedValue = Linear(c.hiddenSize, c.intermediateSize, bias: false)
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray { down(silu(gate(x)) * up(x)) }
    }

    final class Block: Module {
        @ModuleInfo(key: "self_attn") var attention: Attention
        @ModuleInfo(key: "mlp") var mlp: MLP
        @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
        @ModuleInfo(key: "post_attention_layernorm") var postNorm: RMSNorm

        init(_ c: MageVLConfiguration.TextConfiguration) {
            _attention.wrappedValue = Attention(c)
            _mlp.wrappedValue = MLP(c)
            _inputNorm.wrappedValue = RMSNorm(dimensions: c.hiddenSize, eps: c.rmsNormEps)
            _postNorm.wrappedValue = RMSNorm(dimensions: c.hiddenSize, eps: c.rmsNormEps)
        }

        func callAsFunction(
            _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
        ) -> MLXArray {
            let h = x + attention(inputNorm(x), mask: mask, cache: cache)
            return h + mlp(postNorm(h))
        }
    }

    final class Inner: Module {
        @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
        @ModuleInfo(key: "layers") var layers: [Block]
        @ModuleInfo(key: "norm") var norm: RMSNorm

        init(_ c: MageVLConfiguration.TextConfiguration) {
            _embedTokens.wrappedValue = Embedding(embeddingCount: c.vocabSize, dimensions: c.hiddenSize)
            _layers.wrappedValue = (0 ..< c.numHiddenLayers).map { _ in Block(c) }
            _norm.wrappedValue = RMSNorm(dimensions: c.hiddenSize, eps: c.rmsNormEps)
        }

        func callAsFunction(
            _ tokens: MLXArray?, embeddings: MLXArray?, cache: [KVCache]?
        ) -> MLXArray {
            guard var h = embeddings ?? tokens.map({ embedTokens($0) }) else {
                preconditionFailure("tokens or embeddings are required")
            }
            let mask = createAttentionMask(h: h, cache: cache?.first)
            for (i, layer) in layers.enumerated() {
                h = layer(h, mask: mask, cache: cache?[i])
            }
            return norm(h)
        }
    }

    final class LanguageModel: Module {
        @ModuleInfo(key: "model") var model: Inner
        @ModuleInfo(key: "lm_head") var lmHead: Linear?

        init(_ c: MageVLConfiguration.TextConfiguration) {
            _model.wrappedValue = Inner(c)
            if !c.tieWordEmbeddings {
                _lmHead.wrappedValue = Linear(c.hiddenSize, c.vocabSize, bias: false)
            }
        }

        func callAsFunction(
            _ tokens: MLXArray?, embeddings: MLXArray?, cache: [KVCache]?
        ) -> MLXArray {
            let h = model(tokens, embeddings: embeddings, cache: cache)
            if let lmHead { return lmHead(h) }
            return model.embedTokens.asLinear(h)
        }
    }
}

/// Mage-VL: a Mage-ViT tower feeding a Qwen3-4B decoder.
///
/// Conforms to `LanguageModel` so the stock `TokenIterator` can drive decoding. Multimodal
/// prefill is performed by `MageVLRuntime`, which embeds the prompt (scattering vision
/// features over the `<|image_pad|>` positions) and fills the KV cache before handing the final
/// token to the iterator. `prepare` therefore only ever sees text.
public final class MageVLModel: Module, LanguageModel, KVCacheDimensionProvider {

    public let config: MageVLConfiguration
    @ModuleInfo(key: "vision_tower") var visionTower: MageVLVision.VisionModel
    @ModuleInfo(key: "language_model") var languageModel: MageVLLanguage.LanguageModel

    public init(_ config: MageVLConfiguration) {
        self.config = config
        _visionTower.wrappedValue = MageVLVision.VisionModel(config.visionConfiguration)
        _languageModel.wrappedValue = MageVLLanguage.LanguageModel(config.textConfiguration)
    }

    public var kvHeads: [Int] {
        Array(repeating: config.textConfiguration.numKeyValueHeads, count: config.textConfiguration.numHiddenLayers)
    }

    public var vocabularySize: Int { config.textConfiguration.vocabSize }

    // MARK: Multimodal building blocks used by the runtime

    /// Encodes one image's patches into LLM-width visual tokens.
    func encodeImage(_ pixels: MLXArray, grid: PatchGrid) -> MLXArray {
        let dtype = visionTower.embeddings.patchEmbedding.weight.dtype
        return visionTower(pixels.asType(dtype), grid: grid)
    }

    /// Token embeddings with visual tokens scattered over every `<|image_pad|>` position.
    /// - Parameters:
    ///   - tokens: (1, L) prompt tokens
    ///   - visual: visual-token features for the image pads in `tokens`, in order, (N, hidden)
    func embed(tokens: MLXArray, visual: MLXArray?) -> MLXArray {
        let embeddings = languageModel.model.embedTokens(tokens)
        guard let visual else { return embeddings }
        let flat = tokens.reshaped(-1).asArray(Int32.self)
        let imageToken = Int32(config.imageTokenId)
        let videoToken = Int32(config.videoTokenId)
        let indices = flat.indices.filter { flat[$0] == imageToken || flat[$0] == videoToken }
        precondition(
            indices.count == visual.dim(0),
            "Mage-VL prompt has \(indices.count) image pads but \(visual.dim(0)) visual tokens")
        guard !indices.isEmpty else { return embeddings }
        let hidden = embeddings.dim(-1)
        let rows = embeddings.reshaped(-1, hidden)
        rows[MLXArray(indices.map { Int32($0) }), 0...] = visual.asType(embeddings.dtype)
        return rows.reshaped(embeddings.shape)
    }

    /// Runs the decoder over precomputed input embeddings (prefill).
    func forward(embeddings: MLXArray, cache: [KVCache]?) -> MLXArray {
        languageModel(nil, embeddings: embeddings, cache: cache)
    }

    // MARK: LanguageModel

    public func prepare(
        _ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters
    ) throws -> PrepareResult {
        precondition(input.image == nil && input.video == nil, "MageVLRuntime performs multimodal prefill")
        var tokens = input.text.tokens
        if tokens.ndim == 1 { tokens = tokens.expandedDimensions(axis: 0) }
        let total = tokens.dim(-1)
        var start = 0
        let step = max(1, prefill.resolvedStepSize())
        while total - start > step {
            _ = languageModel(tokens[0..., start ..< (start + step)], embeddings: nil, cache: cache)
            eval(cache)
            start += step
        }
        let logits = languageModel(tokens[0..., start...], embeddings: nil, cache: cache)
        return .logits(LMOutput(logits: logits))
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        languageModel(inputs, embeddings: nil, cache: cache)
    }

    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var out: [String: MLXArray] = [:]
        out.reserveCapacity(weights.count)
        for (key, value) in weights {
            var k = key
            // Accept both the hub (transformers) and the mlx-vlm key namespaces.
            if k.hasPrefix("model.language_model.") {
                k = "language_model.model." + k.dropFirst("model.language_model.".count)
            } else if k.hasPrefix("model.visual.") {
                k = "vision_tower." + k.dropFirst("model.visual.".count)
            } else if k.hasPrefix("lm_head.") {
                k = "language_model." + k
            } else if k.hasPrefix("model.") {
                k = "language_model." + k
            }
            var v = value
            // PyTorch Conv2d (O, I, kH, kW) -> MLX (O, kH, kW, I); a no-op on converted weights.
            if k.hasSuffix("patch_embedding.weight"), v.ndim == 4,
                v.dim(1) == config.visionConfiguration.numChannels
            {
                v = v.transposed(0, 2, 3, 1)
            }
            if config.textConfiguration.tieWordEmbeddings, k.hasPrefix("language_model.lm_head.") {
                continue
            }
            out[k] = v
        }
        return out
    }
}
