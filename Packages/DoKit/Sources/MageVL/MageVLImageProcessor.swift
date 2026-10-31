import CoreGraphics
import Foundation
import MLX

public enum MageVLImageProcessorError: Error, LocalizedError {
    case aspectRatioTooExtreme(Double)
    case bitmapContextUnavailable

    public var errorDescription: String? {
        switch self {
        case .aspectRatioTooExtreme(let r): "Image aspect ratio \(r) is too extreme (must be < 200)."
        case .bitmapContextUnavailable: "Could not allocate a bitmap context for image preprocessing."
        }
    }
}

/// A preprocessed image ready for the vision tower.
public struct MageVLProcessedImage: @unchecked Sendable {
    /// (grid.h * grid.w, C * P * P) normalized patches in 2x2 merge-block order.
    public let pixels: MLXArray
    public let grid: PatchGrid
    /// Number of `<|image_pad|>` tokens this image occupies in the prompt.
    public let tokenCount: Int
}

/// Swift port of the numpy `Qwen3VLImageProcessor` mlx-vlm uses for Mage-VL
/// (patch 16, merge 2, temporal patch 1, CLIP mean/std, bicubic-quality resampling).
public struct MageVLImageProcessor: Sendable {
    public let config: MageVLImageProcessorConfiguration

    public init(config: MageVLImageProcessorConfiguration) {
        self.config = config
    }

    public var factor: Int { config.patchSize * config.mergeSize }

    /// HF qwen2_vl `smart_resize`: dimensions divisible by `factor`, area within budget,
    /// aspect ratio preserved as closely as possible.
    public static func smartResize(
        height: Int, width: Int, factor: Int, minPixels: Int, maxPixels: Int
    ) throws -> (height: Int, width: Int) {
        let h = Double(height)
        let w = Double(width)
        let ratio = max(h, w) / min(h, w)
        guard ratio <= 200 else { throw MageVLImageProcessorError.aspectRatioTooExtreme(ratio) }
        let f = Double(factor)
        // Python's round() is banker's rounding; match it exactly.
        var hBar = Int((h / f).rounded(.toNearestOrEven)) * factor
        var wBar = Int((w / f).rounded(.toNearestOrEven)) * factor
        if hBar * wBar > maxPixels {
            let beta = ((h * w) / Double(maxPixels)).squareRoot()
            hBar = max(factor, Int((h / beta / f).rounded(.down)) * factor)
            wBar = max(factor, Int((w / beta / f).rounded(.down)) * factor)
        } else if hBar * wBar < minPixels {
            let beta = (Double(minPixels) / (h * w)).squareRoot()
            hBar = Int((h * beta / f).rounded(.up)) * factor
            wBar = Int((w * beta / f).rounded(.up)) * factor
        }
        return (hBar, wBar)
    }

    /// Target size for an image, honouring an optional caller pixel budget (never above the
    /// checkpoint's own `max_pixels`).
    public func targetSize(width: Int, height: Int, maxPixels: Int? = nil) throws -> (width: Int, height: Int) {
        let budget = min(maxPixels ?? config.maxPixels, config.maxPixels)
        let (h, w) = try Self.smartResize(
            height: height, width: width, factor: factor, minPixels: config.minPixels, maxPixels: budget)
        return (w, h)
    }

    public func tokenCount(width: Int, height: Int, maxPixels: Int? = nil) throws -> Int {
        let (w, h) = try targetSize(width: width, height: height, maxPixels: maxPixels)
        return (w / config.patchSize) * (h / config.patchSize) / (config.mergeSize * config.mergeSize)
    }

    public func process(_ image: CGImage, maxPixels: Int? = nil) throws -> MageVLProcessedImage {
        let (width, height) = try targetSize(width: image.width, height: image.height, maxPixels: maxPixels)
        let rgb = try Self.renderSRGB(image, width: width, height: height)
        return process(rgb: rgb, width: width, height: height)
    }

    /// - Parameter rgb: `height * width * 3` interleaved 8-bit sRGB values at the target size.
    public func process(rgb: [UInt8], width: Int, height: Int) -> MageVLProcessedImage {
        precondition(rgb.count == width * height * 3)
        let p = config.patchSize
        let m = config.mergeSize
        let gh = height / p
        let gw = width / p

        let mean = MLXArray(config.imageMean)
        let std = MLXArray(config.imageStd)
        var x = MLXArray(rgb, [height, width, 3]).asType(.float32) * config.rescaleFactor
        x = (x - mean) / std  // (H, W, C)

        // (H, W, C) -> (C, gh/m, m, P, gw/m, m, P) -> (gh/m, gw/m, m, m, C, P, P)
        x = x.transposed(2, 0, 1)
            .reshaped(3, gh / m, m, p, gw / m, m, p)
            .transposed(1, 4, 2, 5, 0, 3, 6)
            .reshaped(gh * gw, 3 * p * p)
        let grid = PatchGrid(t: 1, h: gh, w: gw)
        return MageVLProcessedImage(pixels: x, grid: grid, tokenCount: gh * gw / (m * m))
    }

    /// Resamples into an opaque 8-bit sRGB buffer (color-matched from the source's space,
    /// e.g. Display P3 screenshots) with high-quality interpolation.
    static func renderSRGB(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw MageVLImageProcessorError.bitmapContextUnavailable
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard
                let ctx = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw MageVLImageProcessorError.bitmapContextUnavailable }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgba.withUnsafeBufferPointer { src in
            rgb.withUnsafeMutableBufferPointer { dst in
                for i in 0 ..< (width * height) {
                    dst[3 * i] = src[4 * i]
                    dst[3 * i + 1] = src[4 * i + 1]
                    dst[3 * i + 2] = src[4 * i + 2]
                }
            }
        }
        return rgb
    }
}
