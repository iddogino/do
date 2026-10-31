import Foundation
import MLX
import MLXNN

// Port of mlx-vlm `mlx_vlm/models/mage_vl/vision.py` (v0.7.11), itself isomorphic to
// Microsoft's `modeling_llava_onevision2.py`.
//
// Three deliberate reproductions of upstream behaviour that look like bugs. The weights were
// trained with them, so do not "fix" them:
//  1. The rotation is INTERLEAVED, (x1,x2,x3,x4) -> (-x2,x1,-x4,x3), not split-half.
//  2. The rope frequency table is concat([freqs, freqs]), so under an interleaved rotation the
//     cos/sin at lanes 2i and 2i+1 come from different frequencies.
//  3. The tap is the LAST encoder layer's output.

enum MageVLVision {

    /// (x1, x2, x3, x4, ...) -> (-x2, x1, -x4, x3, ...)
    static func rotateHalfEvenOdd(_ x: MLXArray) -> MLXArray {
        let last = x.dim(-1)
        let even = x[.ellipsis, stride(from: 0, to: last, by: 2)]
        let odd = x[.ellipsis, stride(from: 1, to: last, by: 2)]
        return MLX.stacked([-odd, even], axis: -1).reshaped(x.shape)
    }

    /// q, k: (B, H, L, D); freqs: (B, L, D). Computed in fp32 like upstream.
    static func applyRotary(_ q: MLXArray, _ k: MLXArray, freqs: MLXArray) -> (MLXArray, MLXArray) {
        let dtype = q.dtype
        let q32 = q.asType(.float32)
        let k32 = k.asType(.float32)
        let cosF = cos(freqs).expandedDimensions(axis: 1)
        let sinF = sin(freqs).expandedDimensions(axis: 1)
        let qOut = q32 * cosF + rotateHalfEvenOdd(q32) * sinF
        let kOut = k32 * cosF + rotateHalfEvenOdd(k32) * sinF
        return (qOut.asType(dtype), kOut.asType(dtype))
    }

    /// 3-D (T, H, W) rotary frequencies with a 4:6:6 split of head_dim / 2.
    final class RotaryEmbedding {
        let invFreqT: MLXArray
        let invFreqH: MLXArray
        let invFreqW: MLXArray

        init(_ config: MageVLConfiguration.VisionConfiguration) {
            let headDim = config.hiddenSize / config.numAttentionHeads
            precondition(headDim % 32 == 0, "Mage-ViT head_dim must split 4:6:6 over head_dim/2")
            let unit = (headDim / 2) / 16
            let base = config.ropeTheta

            // NOTE the exponent: arange(size)/size, not the conventional arange(0, d, 2)/d.
            func inverse(_ size: Int) -> MLXArray {
                let exponent = MLXArray(0 ..< size).asType(.float32) / Float(size)
                return 1.0 / MLX.pow(MLXArray(base), exponent)
            }
            invFreqT = inverse(4 * unit)
            invFreqH = inverse(6 * unit)
            invFreqW = inverse(6 * unit)
            eval(invFreqT, invFreqH, invFreqW)
        }

        /// positions: (L, 3) int32 of [t, h, w] -> (L, head_dim / 2) float32
        func callAsFunction(positions: MLXArray) -> MLXArray {
            let t = positions[0..., 0].asType(.float32).expandedDimensions(axis: 1)
            let h = positions[0..., 1].asType(.float32).expandedDimensions(axis: 1)
            let w = positions[0..., 2].asType(.float32).expandedDimensions(axis: 1)
            return concatenated(
                [t * invFreqT.expandedDimensions(axis: 0),
                 h * invFreqH.expandedDimensions(axis: 0),
                 w * invFreqW.expandedDimensions(axis: 0)],
                axis: -1)
        }
    }

    final class Embeddings: Module {
        let patchSize: Int
        let channels: Int
        let embedDim: Int
        @ModuleInfo(key: "patch_embedding") var patchEmbedding: Conv2d

        init(_ config: MageVLConfiguration.VisionConfiguration) {
            patchSize = config.patchSize
            channels = config.numChannels
            embedDim = config.hiddenSize
            _patchEmbedding.wrappedValue = Conv2d(
                inputChannels: config.numChannels, outputChannels: config.hiddenSize,
                kernelSize: .init(config.patchSize), stride: .init(config.patchSize), bias: false)
        }

        /// pixels: (N, C * P * P) in channel-major patch layout -> (N, hidden)
        func callAsFunction(_ pixels: MLXArray) -> MLXArray {
            // Upstream views patches as (N, C, P, P); MLX convolutions are NHWC.
            let x = pixels.reshaped(-1, channels, patchSize, patchSize).transposed(0, 2, 3, 1)
            return patchEmbedding(x).reshaped(-1, embedDim)
        }
    }

    final class Attention: Module {
        let numHeads: Int
        let headDim: Int
        let scale: Float
        @ModuleInfo(key: "qkv") var qkv: Linear
        @ModuleInfo(key: "proj") var proj: Linear

        init(_ config: MageVLConfiguration.VisionConfiguration) {
            numHeads = config.numAttentionHeads
            headDim = config.hiddenSize / config.numAttentionHeads
            scale = pow(Float(headDim), -0.5)
            _qkv.wrappedValue = Linear(config.hiddenSize, config.hiddenSize * 3)
            _proj.wrappedValue = Linear(config.hiddenSize, config.hiddenSize)
        }

        func callAsFunction(_ x: MLXArray, freqs: MLXArray, mask: MLXArray?) -> MLXArray {
            let (B, L) = (x.dim(0), x.dim(1))
            // (B, L, 3*H*D) -> (B, L, 3, H, D) -> (3, B, H, L, D). The split is contiguous per
            // projection, not head-interleaved.
            let parts = qkv(x).reshaped(B, L, 3, numHeads, headDim).transposed(2, 0, 3, 1, 4)
            var q = parts[0]
            var k = parts[1]
            let v = parts[2]
            (q, k) = MageVLVision.applyRotary(q, k, freqs: freqs)

            let out = MLXFast.scaledDotProductAttention(
                queries: q, keys: k, values: v, scale: scale,
                mask: mask.map { .array($0) } ?? .none)
            return proj(out.transposed(0, 2, 1, 3).reshaped(B, L, -1))
        }
    }

    final class MLP: Module {
        @ModuleInfo(key: "fc1") var fc1: Linear
        @ModuleInfo(key: "fc2") var fc2: Linear
        // config.hidden_act == "gelu": the exact erf GELU, not the tanh approximation.
        let activation = GELU()

        init(_ config: MageVLConfiguration.VisionConfiguration) {
            _fc1.wrappedValue = Linear(config.hiddenSize, config.intermediateSize)
            _fc2.wrappedValue = Linear(config.intermediateSize, config.hiddenSize)
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray { fc2(activation(fc1(x))) }
    }

    final class EncoderLayer: Module {
        @ModuleInfo(key: "self_attn") var attention: Attention
        @ModuleInfo(key: "layer_norm1") var norm1: LayerNorm
        @ModuleInfo(key: "mlp") var mlp: MLP
        @ModuleInfo(key: "layer_norm2") var norm2: LayerNorm

        init(_ config: MageVLConfiguration.VisionConfiguration) {
            precondition(config.layerNormType == "layer_norm", "Only layer_norm Mage-ViT checkpoints are supported")
            _attention.wrappedValue = Attention(config)
            _norm1.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps)
            _mlp.wrappedValue = MLP(config)
            _norm2.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps)
        }

        func callAsFunction(_ x: MLXArray, freqs: MLXArray, mask: MLXArray?) -> MLXArray {
            let h = x + attention(norm1(x), freqs: freqs, mask: mask)
            return h + mlp(norm2(h))
        }
    }

    final class Encoder: Module {
        @ModuleInfo(key: "layers") var layers: [EncoderLayer]

        init(_ config: MageVLConfiguration.VisionConfiguration) {
            _layers.wrappedValue = (0 ..< config.numHiddenLayers).map { _ in EncoderLayer(config) }
        }

        func callAsFunction(_ x: MLXArray, freqs: MLXArray, mask: MLXArray?) -> MLXArray {
            var h = x
            for layer in layers { h = layer(h, freqs: freqs, mask: mask) }
            return h
        }
    }

    /// Merges spatial_merge_size^2 neighbouring patches and projects to the LLM width.
    final class PatchMerger: Module {
        let mergedDim: Int
        @ModuleInfo(key: "ln_q") var lnQ: LayerNorm
        // nn.Sequential upstream -> tuple elements 0 and 2 carry the weights.
        @ModuleInfo var mlp: (Linear, GELU, Linear)

        init(_ config: MageVLConfiguration.VisionConfiguration) {
            mergedDim = config.hiddenSize * config.spatialMergeSize * config.spatialMergeSize
            _lnQ.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps)
            mlp = (
                Linear(mergedDim, mergedDim),
                GELU(),
                Linear(mergedDim, config.outHiddenSize)
            )
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            let h = lnQ(x).reshaped(-1, mergedDim)
            return mlp.2(mlp.1(mlp.0(h)))
        }
    }

    final class VisionModel: Module {
        let config: MageVLConfiguration.VisionConfiguration
        @ModuleInfo(key: "embeddings") var embeddings: Embeddings
        @ModuleInfo(key: "layernorm_pre") var layerNormPre: LayerNorm
        @ModuleInfo(key: "encoder") var encoder: Encoder
        @ModuleInfo(key: "merger") var merger: PatchMerger
        let rotary: RotaryEmbedding

        init(_ config: MageVLConfiguration.VisionConfiguration) {
            precondition(!config.useHead, "The standalone Mage-ViT pooling head is not supported")
            self.config = config
            _embeddings.wrappedValue = Embeddings(config)
            _layerNormPre.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps)
            _encoder.wrappedValue = Encoder(config)
            _merger.wrappedValue = PatchMerger(config)
            rotary = RotaryEmbedding(config)
        }

        /// Encodes ONE image.
        /// - Parameters:
        ///   - pixels: (grid_h * grid_w, C * P * P) patches in 2x2 merge-block order
        ///   - grid: the (t, h, w) patch grid of this image
        /// - Returns: (grid_h * grid_w / merge^2, out_hidden) visual tokens
        func callAsFunction(_ pixels: MLXArray, grid: PatchGrid) -> MLXArray {
            let positions = MageVLVision.patchPositions(grid: grid, mergeSize: config.spatialMergeSize)
            var freqs = rotary(positions: positions)
            freqs = concatenated([freqs, freqs], axis: -1).expandedDimensions(axis: 0)

            var h = embeddings(pixels).expandedDimensions(axis: 0)
            h = layerNormPre(h)
            // A single image has t == 1 <= frame_windows_size: one attention block, no mask.
            h = encoder(h, freqs: freqs, mask: nil)
            return merger(h[0])
        }
    }

    /// (L, 3) [t, h, w] patch positions in the processor's 2x2 merge-block order. The merger
    /// relies on consecutive runs of merge^2 patches belonging to one block, so the RoPE
    /// positions must follow that ordering too.
    static func patchPositions(grid: PatchGrid, mergeSize m: Int) -> MLXArray {
        var rows: [Int32] = []
        rows.reserveCapacity(grid.t * grid.h * grid.w * 3)
        for ti in 0 ..< grid.t {
            for hb in 0 ..< (grid.h / m) {
                for wb in 0 ..< (grid.w / m) {
                    for dh in 0 ..< m {
                        for dw in 0 ..< m {
                            rows.append(Int32(ti))
                            rows.append(Int32(hb * m + dh))
                            rows.append(Int32(wb * m + dw))
                        }
                    }
                }
            }
        }
        return MLXArray(rows, [rows.count / 3, 3])
    }
}

/// A (temporal, height, width) patch grid, in units of patches.
public struct PatchGrid: Hashable, Sendable {
    public var t: Int
    public var h: Int
    public var w: Int
    public init(t: Int, h: Int, w: Int) {
        self.t = t
        self.h = h
        self.w = w
    }
    public var patchCount: Int { t * h * w }
}
