import CoreGraphics
import DoCore
import Foundation
import ImageIO
import MLX
import MLXLMCommon
import Tokenizers

/// Numerical parity checks against the Python mlx-vlm reference
/// (`scripts/parity/export_reference.py`).
public enum MageVLDiagnostics {

    public struct Report: Sendable, CustomStringConvertible {
        public var lines: [String] = []
        public var passed = true

        mutating func check(_ name: String, _ ok: Bool, _ detail: String) {
            lines.append("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
            if !ok { passed = false }
        }

        public var description: String { lines.joined(separator: "\n") }
    }

    /// - Parameters:
    ///   - modelDirectory: the converted checkpoint
    ///   - referenceDirectory: folder written by `export_reference.py` (reference.safetensors,
    ///     prompt.txt, screenshot.png, task.txt)
    public static func parity(modelDirectory: URL, referenceDirectory: URL) async throws -> Report {
        var report = Report()
        let ref = try loadArrays(url: referenceDirectory.appending(path: "reference.safetensors"))
        let refPrompt = try String(contentsOf: referenceDirectory.appending(path: "prompt.txt"), encoding: .utf8)
        let task = try String(contentsOf: referenceDirectory.appending(path: "task.txt"), encoding: .utf8)
        guard let png = CGImageSourceCreateWithURL(referenceDirectory.appending(path: "screenshot.png") as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(png, 0, nil)
        else { throw MageVLRuntimeError.missingFile("screenshot.png") }

        // 1. Prompt text: AgentHistory + QwenChatTemplate vs HF apply_chat_template.
        let history = AgentHistory(instruction: task)
        let messages = history.messages(current: .screenshot(ImageAttachment(image: image)))
        let rendered = QwenChatTemplate.render(messages)
        let samePrompt = rendered.text == refPrompt
        report.check(
            "prompt text", samePrompt,
            samePrompt ? "\(rendered.text.count) chars identical" : firstDifference(rendered.text, refPrompt))

        // 2. Tokenization (+ image pad expansion).
        let configData = try Data(contentsOf: modelDirectory.appending(path: "config.json"))
        let config = try JSONDecoder().decode(MageVLConfiguration.self, from: configData)
        let baseConfig = try JSONDecoder().decode(BaseConfiguration.self, from: configData)
        let processorConfig = try JSONDecoder().decode(
            MageVLImageProcessorConfiguration.self,
            from: Data(contentsOf: modelDirectory.appending(path: "preprocessor_config.json")))
        let processor = MageVLImageProcessor(config: processorConfig)
        let tokenizer = try await AutoTokenizer.from(modelFolder: modelDirectory)

        let refIds = ref["input_ids"]!.reshaped(-1).asArray(Int32.self)
        let processed = try processor.process(image)
        var swiftIds: [Int32] = []
        for t in tokenizer.encode(text: rendered.text, addSpecialTokens: false) {
            if t == config.imageTokenId {
                swiftIds += Array(repeating: Int32(t), count: processed.tokenCount)
            } else {
                swiftIds.append(Int32(t))
            }
        }
        let sameIds = swiftIds == refIds
        report.check(
            "token ids", sameIds,
            sameIds ? "\(refIds.count) tokens identical" : "swift \(swiftIds.count) vs ref \(refIds.count), first diff at \((0 ..< min(swiftIds.count, refIds.count)).first { swiftIds[$0] != refIds[$0] } ?? min(swiftIds.count, refIds.count))")

        // 3. Image preprocessing (resampler differs: CoreGraphics vs PIL bicubic).
        let refPixels = ref["pixel_values"]!.asType(.float32)
        let refGrid = ref["image_grid_thw"]!.reshaped(-1).asArray(Int32.self)
        let grid = PatchGrid(t: Int(refGrid[0]), h: Int(refGrid[1]), w: Int(refGrid[2]))
        let sameGrid = grid == processed.grid
        report.check("patch grid", sameGrid, "swift \(processed.grid) vs ref \(grid)")
        if sameGrid {
            let diff = abs(processed.pixels - refPixels)
            let mae = diff.mean().item(Float.self)
            let p99 = sortedQuantile(diff, 0.99)
            report.check(
                "pixel values", mae < 0.05,
                "mean |Δ| \(fmt(mae)), p99 |Δ| \(fmt(p99)) (normalized units; resampler differences expected)")
        }

        // 4. Model math, fed the reference's exact inputs.
        let model = MageVLModel(config)
        try await loadWeights(
            modelDirectory: modelDirectory, model: model, perLayerQuantization: baseConfig.perLayerQuantization)

        let features = model.encodeImage(ref["pixel_values"]!, grid: grid).asType(.float32)
        let refFeatures = ref["vision_features"]!.asType(.float32)
        let cosine = cosineSimilarity(features, refFeatures)
        let relErr = (abs(features - refFeatures).mean() / abs(refFeatures).mean()).item(Float.self)
        // Mage-ViT in bf16 amplifies rounding differences across its 24 layers: in Python, a 0.1%
        // input perturbation alone moves the encoder output to cosine ~0.98. Swift and Python use
        // different (equally valid) kernel schedules, so demand agreement well inside that band.
        report.check(
            "vision features", cosine > 0.995,
            "shape \(features.shape) vs \(refFeatures.shape), cosine \(fmt(cosine, 6)), rel |Δ| \(fmt(relErr))")

        let ids = ref["input_ids"]!.reshaped(1, -1)
        let embeddings = model.embed(tokens: ids, visual: model.encodeImage(ref["pixel_values"]!, grid: grid))
        let cache = try model.newCache(parameters: nil)
        var logits: MLXArray?
        let chunk = 1024
        var start = 0
        let total = ids.dim(1)
        while start < total {
            let end = min(start + chunk, total)
            logits = model.forward(embeddings: embeddings[0..., start ..< end, 0...], cache: cache)
            eval(logits!)
            start = end
        }
        let last = logits![0, -1].asType(.float32)
        let refLast = ref["logits_last"]!.asType(.float32)
        let logitCos = cosineSimilarity(last, refLast)
        let swiftTop = argSort(-last).asArray(Int32.self).prefix(5)
        let refTop = argSort(-refLast).asArray(Int32.self).prefix(5)
        let sameTop1 = swiftTop.first == refTop.first
        report.check(
            "final logits", logitCos > 0.995 && sameTop1,
            "cosine \(fmt(logitCos, 6)); top-5 swift \(Array(swiftTop)) ref \(Array(refTop))")
        return report
    }

    static func cosineSimilarity(_ a: MLXArray, _ b: MLXArray) -> Float {
        let x = a.reshaped(-1)
        let y = b.reshaped(-1)
        return ((x * y).sum() / (sqrt((x * x).sum()) * sqrt((y * y).sum()))).item(Float.self)
    }

    static func sortedQuantile(_ a: MLXArray, _ q: Float) -> Float {
        let flat = sorted(a.reshaped(-1))
        let index = Int(Float(flat.dim(0) - 1) * q)
        return flat[index].item(Float.self)
    }

    static func fmt(_ v: Float, _ digits: Int = 4) -> String {
        String(format: "%.\(digits)f", v)
    }

    static func firstDifference(_ a: String, _ b: String) -> String {
        let aa = Array(a)
        let bb = Array(b)
        let i = (0 ..< min(aa.count, bb.count)).first { aa[$0] != bb[$0] } ?? min(aa.count, bb.count)
        let context = { (s: [Character]) in String(s[max(0, i - 40) ..< min(s.count, i + 40)]).debugDescription }
        return "differ at char \(i) (swift \(aa.count) chars, ref \(bb.count)): swift …\(context(aa))… ref …\(context(bb))…"
    }
}

extension MageVLDiagnostics {
    /// Stage-by-stage comparison of the vision tower against `vision_steps.safetensors`.
    public static func visionBisect(modelDirectory: URL, referenceDirectory: URL) async throws -> String {
        let ref = try loadArrays(url: referenceDirectory.appending(path: "reference.safetensors"))
        let steps = try loadArrays(url: referenceDirectory.appending(path: "vision_steps.safetensors"))
        let configData = try Data(contentsOf: modelDirectory.appending(path: "config.json"))
        let config = try JSONDecoder().decode(MageVLConfiguration.self, from: configData)
        let baseConfig = try JSONDecoder().decode(BaseConfiguration.self, from: configData)
        let model = MageVLModel(config)
        try await loadWeights(
            modelDirectory: modelDirectory, model: model, perLayerQuantization: baseConfig.perLayerQuantization)
        let vt = model.visionTower
        let g = ref["image_grid_thw"]!.reshaped(-1).asArray(Int32.self)
        let grid = PatchGrid(t: Int(g[0]), h: Int(g[1]), w: Int(g[2]))
        var lines: [String] = []
        func compare(_ name: String, _ a: MLXArray) {
            let b = steps[name]!
            let c = cosineSimilarity(a.asType(.float32), b)
            let rel = (abs(a.asType(.float32) - b).mean() / abs(b).mean()).item(Float.self)
            lines.append("\(name): cos \(fmt(c, 7)) rel \(fmt(rel, 5)) shape \(a.shape)")
        }
        let x = ref["pixel_values"]!.asType(.bfloat16)
        var h = vt.embeddings(x).expandedDimensions(axis: 0)
        compare("emb", h)
        let positions = MageVLVision.patchPositions(grid: grid, mergeSize: config.visionConfiguration.spatialMergeSize)
        var freqs = vt.rotary(positions: positions)
        freqs = concatenated([freqs, freqs], axis: -1).expandedDimensions(axis: 0)
        compare("freqs", freqs)
        h = vt.layerNormPre(h)
        compare("pre", h)
        let refPre = steps["pre"]!.asType(.bfloat16)
        let l0 = vt.encoder.layers[0](refPre, freqs: steps["freqs"]!, mask: nil)
        compare("l0", l0)
        var hh = vt.encoder.layers[0](h, freqs: freqs, mask: nil)
        for layer in vt.encoder.layers.dropFirst() { hh = layer(hh, freqs: freqs, mask: nil) }
        compare("enc", hh)
        compare("merged", vt.merger(hh[0]))
        return lines.joined(separator: "\n")
    }
}
