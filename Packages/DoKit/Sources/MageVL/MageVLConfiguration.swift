import Foundation

/// `config.json` of a Mage-VL checkpoint converted to the mlx-vlm `mage_vl` layout
/// (e.g. `pratikgx/Mage-VL-Cowork-MLX-4bit`).
public struct MageVLConfiguration: Codable, Sendable {

    /// Stock Qwen3-4B-Instruct-2507 decoder. Plain 1-D RoPE (not M-RoPE).
    public struct TextConfiguration: Codable, Sendable {
        public var hiddenSize: Int = 2560
        public var numHiddenLayers: Int = 36
        public var intermediateSize: Int = 9728
        public var numAttentionHeads: Int = 32
        public var numKeyValueHeads: Int = 8
        public var headDim: Int = 128
        public var rmsNormEps: Float = 1e-6
        public var vocabSize: Int = 151_936
        public var maxPositionEmbeddings: Int = 262_144
        public var ropeTheta: Float = 5_000_000
        public var tieWordEmbeddings: Bool = false

        enum CodingKeys: String, CodingKey {
            case hiddenSize = "hidden_size"
            case numHiddenLayers = "num_hidden_layers"
            case intermediateSize = "intermediate_size"
            case numAttentionHeads = "num_attention_heads"
            case numKeyValueHeads = "num_key_value_heads"
            case headDim = "head_dim"
            case rmsNormEps = "rms_norm_eps"
            case vocabSize = "vocab_size"
            case maxPositionEmbeddings = "max_position_embeddings"
            case ropeTheta = "rope_theta"
            case ropeParameters = "rope_parameters"
            case tieWordEmbeddings = "tie_word_embeddings"
        }

        private struct RopeParameters: Codable {
            var ropeTheta: Float?
            enum CodingKeys: String, CodingKey { case ropeTheta = "rope_theta" }
        }

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hiddenSize = try c.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? hiddenSize
            numHiddenLayers = try c.decodeIfPresent(Int.self, forKey: .numHiddenLayers) ?? numHiddenLayers
            intermediateSize = try c.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? intermediateSize
            numAttentionHeads = try c.decodeIfPresent(Int.self, forKey: .numAttentionHeads) ?? numAttentionHeads
            numKeyValueHeads = try c.decodeIfPresent(Int.self, forKey: .numKeyValueHeads) ?? numKeyValueHeads
            headDim = try c.decodeIfPresent(Int.self, forKey: .headDim) ?? headDim
            rmsNormEps = try c.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? rmsNormEps
            vocabSize = try c.decodeIfPresent(Int.self, forKey: .vocabSize) ?? vocabSize
            maxPositionEmbeddings =
                try c.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? maxPositionEmbeddings
            tieWordEmbeddings = try c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? false
            // transformers 5.x nests rope under `rope_parameters`; older configs keep it flat.
            // A silently-defaulted theta passes short-context parity and diverges on long
            // prompts, so honour whichever one is present.
            if let flat = try c.decodeIfPresent(Float.self, forKey: .ropeTheta) {
                ropeTheta = flat
            } else if let nested = try c.decodeIfPresent(RopeParameters.self, forKey: .ropeParameters),
                let theta = nested.ropeTheta
            {
                ropeTheta = theta
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(hiddenSize, forKey: .hiddenSize)
            try c.encode(numHiddenLayers, forKey: .numHiddenLayers)
            try c.encode(intermediateSize, forKey: .intermediateSize)
            try c.encode(numAttentionHeads, forKey: .numAttentionHeads)
            try c.encode(numKeyValueHeads, forKey: .numKeyValueHeads)
            try c.encode(headDim, forKey: .headDim)
            try c.encode(rmsNormEps, forKey: .rmsNormEps)
            try c.encode(vocabSize, forKey: .vocabSize)
            try c.encode(maxPositionEmbeddings, forKey: .maxPositionEmbeddings)
            try c.encode(ropeTheta, forKey: .ropeTheta)
            try c.encode(tieWordEmbeddings, forKey: .tieWordEmbeddings)
        }
    }

    /// Mage-ViT: 24-layer pre-norm ViT with a 4:6:6 split 3-D RoPE and a 2x2 patch merger.
    public struct VisionConfiguration: Codable, Sendable {
        public var hiddenSize: Int = 1024
        public var numHiddenLayers: Int = 24
        public var numAttentionHeads: Int = 16
        public var intermediateSize: Int = 4096
        public var patchSize: Int = 16
        public var numChannels: Int = 3
        public var layerNormEps: Float = 1e-6
        public var layerNormType: String = "layer_norm"
        public var ropeTheta: Float = 10_000
        public var spatialMergeSize: Int = 2
        public var temporalPatchSize: Int = 1
        public var outHiddenSize: Int = 2560
        public var frameWindowsSize: Int = 4
        public var useHead: Bool = false

        enum CodingKeys: String, CodingKey {
            case hiddenSize = "hidden_size"
            case numHiddenLayers = "num_hidden_layers"
            case numAttentionHeads = "num_attention_heads"
            case intermediateSize = "intermediate_size"
            case patchSize = "patch_size"
            case numChannels = "num_channels"
            case layerNormEps = "layer_norm_eps"
            case layerNormType = "layer_norm_type"
            case ropeTheta = "rope_theta"
            case spatialMergeSize = "spatial_merge_size"
            case temporalPatchSize = "temporal_patch_size"
            case outHiddenSize = "out_hidden_size"
            case frameWindowsSize = "frame_windows_size"
            case useHead = "use_head"
        }

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hiddenSize = try c.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? hiddenSize
            numHiddenLayers = try c.decodeIfPresent(Int.self, forKey: .numHiddenLayers) ?? numHiddenLayers
            numAttentionHeads = try c.decodeIfPresent(Int.self, forKey: .numAttentionHeads) ?? numAttentionHeads
            intermediateSize = try c.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? intermediateSize
            patchSize = try c.decodeIfPresent(Int.self, forKey: .patchSize) ?? patchSize
            numChannels = try c.decodeIfPresent(Int.self, forKey: .numChannels) ?? numChannels
            layerNormEps = try c.decodeIfPresent(Float.self, forKey: .layerNormEps) ?? layerNormEps
            layerNormType = try c.decodeIfPresent(String.self, forKey: .layerNormType) ?? layerNormType
            ropeTheta = try c.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? ropeTheta
            spatialMergeSize = try c.decodeIfPresent(Int.self, forKey: .spatialMergeSize) ?? spatialMergeSize
            temporalPatchSize = try c.decodeIfPresent(Int.self, forKey: .temporalPatchSize) ?? temporalPatchSize
            outHiddenSize = try c.decodeIfPresent(Int.self, forKey: .outHiddenSize) ?? outHiddenSize
            frameWindowsSize = try c.decodeIfPresent(Int.self, forKey: .frameWindowsSize) ?? frameWindowsSize
            useHead = try c.decodeIfPresent(Bool.self, forKey: .useHead) ?? useHead
        }
    }

    public var modelType: String
    public var textConfiguration: TextConfiguration
    public var visionConfiguration: VisionConfiguration
    public var imageTokenId: Int = 151_655
    public var videoTokenId: Int = 151_656
    public var visionStartTokenId: Int = 151_652
    public var visionEndTokenId: Int = 151_653

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case textConfiguration = "text_config"
        case visionConfiguration = "vision_config"
        case imageTokenId = "image_token_id"
        case videoTokenId = "video_token_id"
        case visionStartTokenId = "vision_start_token_id"
        case visionEndTokenId = "vision_end_token_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try c.decode(String.self, forKey: .modelType)
        textConfiguration = try c.decodeIfPresent(TextConfiguration.self, forKey: .textConfiguration) ?? .init()
        visionConfiguration =
            try c.decodeIfPresent(VisionConfiguration.self, forKey: .visionConfiguration) ?? .init()
        imageTokenId = try c.decodeIfPresent(Int.self, forKey: .imageTokenId) ?? imageTokenId
        videoTokenId = try c.decodeIfPresent(Int.self, forKey: .videoTokenId) ?? videoTokenId
        visionStartTokenId = try c.decodeIfPresent(Int.self, forKey: .visionStartTokenId) ?? visionStartTokenId
        visionEndTokenId = try c.decodeIfPresent(Int.self, forKey: .visionEndTokenId) ?? visionEndTokenId
    }
}

/// `preprocessor_config.json` (Qwen2-VL style image processor, CLIP statistics).
public struct MageVLImageProcessorConfiguration: Codable, Sendable {
    public var patchSize: Int = 16
    public var mergeSize: Int = 2
    public var temporalPatchSize: Int = 1
    public var minPixels: Int = 3136
    public var maxPixels: Int = 4_000_000
    public var imageMean: [Float] = [0.48145466, 0.4578275, 0.40821073]
    public var imageStd: [Float] = [0.26862954, 0.26130258, 0.27577711]
    public var rescaleFactor: Float = 1.0 / 255.0

    enum CodingKeys: String, CodingKey {
        case patchSize = "patch_size"
        case mergeSize = "merge_size"
        case temporalPatchSize = "temporal_patch_size"
        case minPixels = "min_pixels"
        case maxPixels = "max_pixels"
        case imageMean = "image_mean"
        case imageStd = "image_std"
        case rescaleFactor = "rescale_factor"
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        patchSize = try c.decodeIfPresent(Int.self, forKey: .patchSize) ?? patchSize
        mergeSize = try c.decodeIfPresent(Int.self, forKey: .mergeSize) ?? mergeSize
        temporalPatchSize = try c.decodeIfPresent(Int.self, forKey: .temporalPatchSize) ?? temporalPatchSize
        minPixels = try c.decodeIfPresent(Int.self, forKey: .minPixels) ?? minPixels
        maxPixels = try c.decodeIfPresent(Int.self, forKey: .maxPixels) ?? maxPixels
        imageMean = try c.decodeIfPresent([Float].self, forKey: .imageMean) ?? imageMean
        imageStd = try c.decodeIfPresent([Float].self, forKey: .imageStd) ?? imageStd
        rescaleFactor = try c.decodeIfPresent(Float.self, forKey: .rescaleFactor) ?? rescaleFactor
    }
}
