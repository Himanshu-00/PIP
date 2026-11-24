//
//  Qwen35Vision.swift
//
//  Qwen3.5's eyes: the vision encoder that turns a picture into tokens the
//  language model can read, and the image preparation in front of it.
//
//  Ported from mlx-swift-lm (`Libraries/MLXVLM/Models/Qwen3VL.swift` and
//  `QwenVL.swift`, MIT License), itself a port of Apple's/Blaizzy's mlx-vlm.
//  Kept to what Pip needs: one still image at a time, no video, no batching.
//

import CoreGraphics
import Foundation
import MLX
import MLXNN

// MARK: - Configuration

struct Qwen35VisionConfiguration: Sendable {
    var depth: Int
    var hiddenSize: Int
    var intermediateSize: Int
    var outHiddenSize: Int
    var numHeads: Int
    var patchSize: Int
    var spatialMergeSize: Int
    var temporalPatchSize: Int
    var numPositionEmbeddings: Int
    var inChannels: Int
    var hiddenAct: String

    /// Token ids around and inside the image in the prompt.
    var imageTokenId: Int
    var visionStartTokenId: Int
    var visionEndTokenId: Int

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vision = root["vision_config"] as? [String: Any] else {
            throw LocalBrain.Failure(message: "This brain has no eyes (no vision settings).")
        }
        func int(_ key: String, _ fallback: Int) -> Int { (vision[key] as? NSNumber)?.intValue ?? fallback }
        depth = int("depth", 27)
        hiddenSize = int("hidden_size", 1152)
        intermediateSize = int("intermediate_size", 4304)
        outHiddenSize = int("out_hidden_size", 4096)
        numHeads = int("num_heads", 16)
        patchSize = int("patch_size", 16)
        spatialMergeSize = int("spatial_merge_size", 2)
        temporalPatchSize = int("temporal_patch_size", 2)
        numPositionEmbeddings = int("num_position_embeddings", 2304)
        inChannels = int("in_channels", 3)
        hiddenAct = vision["hidden_act"] as? String ?? "gelu_pytorch_tanh"
        imageTokenId = (root["image_token_id"] as? NSNumber)?.intValue ?? 248_056
        visionStartTokenId = (root["vision_start_token_id"] as? NSNumber)?.intValue ?? 248_053
        visionEndTokenId = (root["vision_end_token_id"] as? NSNumber)?.intValue ?? 248_054
    }
}

/// An image's size in patches: frames (always 1 here), rows, columns.
struct Qwen35Grid: Sendable {
    let t: Int
    let h: Int
    let w: Int
}

// MARK: - Image preparation

enum Qwen35ImageInput {

    /// The picture, resized and normalised, cut into patches for the vision
    /// encoder: [patches, channels × 2 frames × 16 × 16], plus its grid.
    ///
    /// `maxTokens` caps how detailed the look is: each token is a 32×32
    /// pixel block after merging. ~1,000 is enough to read normal screen
    /// text and keeps a look to a few seconds.
    static func prepare(_ image: CGImage, config: Qwen35VisionConfiguration,
                        maxTokens: Int = 1_024) throws -> (pixels: MLXArray, grid: Qwen35Grid) {
        let factor = config.patchSize * config.spatialMergeSize
        let (height, width) = targetSize(height: image.height, width: image.width, factor: factor,
                                         minPixels: 64 * factor * factor,
                                         maxPixels: maxTokens * factor * factor)

        // Draw into an sRGB bitmap at the target size, high-quality scaling.
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw LocalBrain.Failure(message: "I couldn't prepare the picture.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // RGB planes, scaled to -1…1 (mean 0.5, std 0.5), as [1, 3, H, W].
        let plane = height * width
        var floats = [Float](repeating: 0, count: 3 * plane)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let source = y * bytesPerRow + x * 4
                let target = y * width + x
                floats[target] = Float(bytes[source]) / 127.5 - 1
                floats[plane + target] = Float(bytes[source + 1]) / 127.5 - 1
                floats[2 * plane + target] = Float(bytes[source + 2]) / 127.5 - 1
            }
        }
        let picture = MLXArray(floats).reshaped(1, 3, height, width)
        return patchify(picture, config: config)
    }

    /// Nearest size with both sides multiples of `factor`, within the pixel budget.
    static func targetSize(height: Int, width: Int, factor: Int, minPixels: Int, maxPixels: Int) -> (Int, Int) {
        let h = max(height, factor)
        let w = max(width, factor)
        var hBar = max(factor, Int((Float(h) / Float(factor)).rounded()) * factor)
        var wBar = max(factor, Int((Float(w) / Float(factor)).rounded()) * factor)
        if hBar * wBar > maxPixels {
            let beta = sqrt(Float(h * w) / Float(maxPixels))
            hBar = max(factor, Int(floor(Float(h) / beta / Float(factor))) * factor)
            wBar = max(factor, Int(floor(Float(w) / beta / Float(factor))) * factor)
        } else if hBar * wBar < minPixels {
            let beta = sqrt(Float(minPixels) / Float(h * w))
            hBar = Int(ceil(Float(h) * beta / Float(factor))) * factor
            wBar = Int(ceil(Float(w) * beta / Float(factor))) * factor
        }
        return (hBar, wBar)
    }

    /// QwenVL's patch layout: the still image is repeated to fill the two
    /// frames a patch spans, then cut so each 2×2 group of patches (one
    /// token after merging) sits together.
    private static func patchify(_ image: MLXArray, config: Qwen35VisionConfiguration) -> (MLXArray, Qwen35Grid) {
        let temporal = config.temporalPatchSize
        let patch = config.patchSize
        let merge = config.spatialMergeSize
        let (height, width) = (image.dim(-2), image.dim(-1))

        var frames = image
        if temporal > 1 { frames = tiled(image, repetitions: [temporal, 1, 1, 1]) }
        let channels = frames.dim(1)
        let gridT = frames.dim(0) / temporal
        let gridH = height / patch
        let gridW = width / patch

        var patches = frames.reshaped(gridT, temporal, channels,
                                      gridH / merge, merge, patch,
                                      gridW / merge, merge, patch)
        patches = patches.transposed(0, 3, 6, 4, 7, 2, 1, 5, 8)
        let flat = patches.reshaped(gridT * gridH * gridW, channels * temporal * patch * patch)
        return (flat, Qwen35Grid(t: gridT, h: gridH, w: gridW))
    }
}

// MARK: - Vision encoder

private func qwen35VisionRotateHalf(_ x: MLXArray) -> MLXArray {
    let half = x.dim(-1) / 2
    return concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
}

final class Qwen35VisionPatchEmbed: Module {
    @ModuleInfo(key: "proj") var proj: Conv3d
    let patchSize: Int
    let temporalPatchSize: Int
    let inChannels: Int
    let hiddenSize: Int

    init(_ config: Qwen35VisionConfiguration) {
        patchSize = config.patchSize
        temporalPatchSize = config.temporalPatchSize
        inChannels = config.inChannels
        hiddenSize = config.hiddenSize
        let kernel = IntOrTriple([temporalPatchSize, patchSize, patchSize])
        _proj.wrappedValue = Conv3d(inputChannels: inChannels, outputChannels: hiddenSize,
                                    kernelSize: kernel, stride: kernel, bias: true)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let states = x.reshaped(-1, inChannels, temporalPatchSize, patchSize, patchSize)
            .movedAxis(source: 1, destination: 4)
        return proj(states).reshaped(-1, hiddenSize)
    }
}

final class Qwen35VisionAttention: Module {
    let numHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "qkv") var qkv: Linear
    @ModuleInfo(key: "proj") var proj: Linear

    init(dim: Int, numHeads: Int) {
        self.numHeads = numHeads
        headDim = dim / numHeads
        scale = pow(Float(headDim), -0.5)
        _qkv.wrappedValue = Linear(dim, 3 * dim, bias: true)
        _proj.wrappedValue = Linear(dim, dim)
    }

    func callAsFunction(_ x: MLXArray, rotary: MLXArray) -> MLXArray {
        let length = x.dim(0)
        let parts = split(qkv(x).reshaped(length, 3, numHeads, headDim).transposed(1, 0, 2, 3),
                          parts: 3, axis: 0)
        var queries = parts[0][0]
        var keys = parts[1][0]
        let values = parts[2][0]

        queries = applyRotary(queries, freqs: rotary)
        keys = applyRotary(keys, freqs: rotary)

        let q = queries.reshaped(1, length, numHeads, headDim).transposed(0, 2, 1, 3)
        let k = keys.reshaped(1, length, numHeads, headDim).transposed(0, 2, 1, 3)
        let v = values.reshaped(1, length, numHeads, headDim).transposed(0, 2, 1, 3)

        // One image, so attention is over all of it. The fused kernel wants a
        // head size of 64/80/128; the vision heads are 72, so pad to 80 —
        // zeros add nothing to the dot products.
        let target = [64, 80, 128].first { headDim <= $0 } ?? headDim
        let attended: MLXArray
        if target == headDim {
            attended = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: .none)
        } else {
            let widths: [IntOrPair] = [0, 0, 0, IntOrPair((0, target - headDim))]
            attended = MLXFast.scaledDotProductAttention(
                queries: padded(q, widths: widths), keys: padded(k, widths: widths),
                values: padded(v, widths: widths), scale: scale, mask: .none)[.ellipsis, ..<headDim]
        }
        return proj(attended.transposed(0, 2, 1, 3).reshaped(length, -1))
    }

    private func applyRotary(_ tensor: MLXArray, freqs: MLXArray) -> MLXArray {
        let cosines = expandedDimensions(tiled(expandedDimensions(cos(freqs), axis: 1), repetitions: [1, 1, 2]), axis: 0)
        let sines = expandedDimensions(tiled(expandedDimensions(sin(freqs), axis: 1), repetitions: [1, 1, 2]), axis: 0)
        let rotated = tensor * cosines[0] + qwen35VisionRotateHalf(tensor) * sines[0]
        return rotated.asType(tensor.dtype)
    }
}

final class Qwen35VisionMLP: Module {
    @ModuleInfo(key: "linear_fc1") var linear1: Linear
    @ModuleInfo(key: "linear_fc2") var linear2: Linear
    @ModuleInfo(key: "act") var activation: GELU

    init(dim: Int, hiddenDim: Int, hiddenAct: String) {
        _linear1.wrappedValue = Linear(dim, hiddenDim, bias: true)
        _linear2.wrappedValue = Linear(hiddenDim, dim, bias: true)
        let approximation: GELU.Approximation
        switch hiddenAct {
        case "gelu_pytorch_tanh", "gelu_new": approximation = .tanh
        case "gelu_fast": approximation = .fast
        default: approximation = .none
        }
        _activation.wrappedValue = GELU(approximation: approximation)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear2(activation(linear1(x)))
    }
}

final class Qwen35VisionBlock: Module {
    @ModuleInfo(key: "norm1") var norm1: LayerNorm
    @ModuleInfo(key: "norm2") var norm2: LayerNorm
    @ModuleInfo(key: "attn") var attention: Qwen35VisionAttention
    @ModuleInfo(key: "mlp") var mlp: Qwen35VisionMLP

    init(_ config: Qwen35VisionConfiguration) {
        _norm1.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: 1e-6)
        _norm2.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: 1e-6)
        _attention.wrappedValue = Qwen35VisionAttention(dim: config.hiddenSize, numHeads: config.numHeads)
        _mlp.wrappedValue = Qwen35VisionMLP(dim: config.hiddenSize, hiddenDim: config.intermediateSize,
                                            hiddenAct: config.hiddenAct)
    }

    func callAsFunction(_ x: MLXArray, rotary: MLXArray) -> MLXArray {
        let h = x + attention(norm1(x), rotary: rotary)
        return h + mlp(norm2(h))
    }
}

/// Merges each 2×2 group of patches into one token the size of the
/// language model's embeddings.
final class Qwen35VisionMerger: Module {
    let mergedSize: Int
    @ModuleInfo(key: "norm") var norm: LayerNorm
    @ModuleInfo(key: "linear_fc1") var linear1: Linear
    @ModuleInfo(key: "linear_fc2") var linear2: Linear
    @ModuleInfo(key: "act") var activation: GELU

    init(_ config: Qwen35VisionConfiguration) {
        mergedSize = config.hiddenSize * config.spatialMergeSize * config.spatialMergeSize
        _norm.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: 1e-6)
        _linear1.wrappedValue = Linear(mergedSize, mergedSize)
        _linear2.wrappedValue = Linear(mergedSize, config.outHiddenSize)
        _activation.wrappedValue = GELU()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear2(activation(linear1(norm(x).reshaped(-1, mergedSize))))
    }
}

final class Qwen35VisionModel: Module {
    let config: Qwen35VisionConfiguration
    let gridPerSide: Int

    @ModuleInfo(key: "patch_embed") var patchEmbed: Qwen35VisionPatchEmbed
    @ModuleInfo(key: "pos_embed") var posEmbed: Embedding
    @ModuleInfo(key: "blocks") var blocks: [Qwen35VisionBlock]
    @ModuleInfo(key: "merger") var merger: Qwen35VisionMerger

    init(_ config: Qwen35VisionConfiguration) {
        self.config = config
        gridPerSide = Int(sqrt(Double(config.numPositionEmbeddings)))
        _patchEmbed.wrappedValue = Qwen35VisionPatchEmbed(config)
        _posEmbed.wrappedValue = Embedding(embeddingCount: config.numPositionEmbeddings,
                                           dimensions: config.hiddenSize)
        _blocks.wrappedValue = (0 ..< config.depth).map { _ in Qwen35VisionBlock(config) }
        _merger.wrappedValue = Qwen35VisionMerger(config)
    }

    /// Patches → tokens for the language model: [grid.h·grid.w / 4, 4096].
    func callAsFunction(_ pixels: MLXArray, grid: Qwen35Grid) -> MLXArray {
        var h = patchEmbed(pixels)
        h = h + positionalEmbeddings(grid)
        let rotary = rotaryEmbedding(grid)
        for block in blocks { h = block(h, rotary: rotary) }
        return merger(h)
    }

    /// 2-D rotary angles for every patch: half the head follows the row,
    /// half the column, in the merged-block order the patches arrive in.
    private func rotaryEmbedding(_ grid: Qwen35Grid) -> MLXArray {
        let headDim = config.hiddenSize / config.numHeads
        let dimension = headDim / 2
        let theta: Float = 10_000
        let invFreq = 1.0 / pow(MLXArray(theta),
                                MLXArray(stride(from: 0, to: dimension, by: 2)).asType(.float32) / Float(dimension))
        let longest = max(grid.h, grid.w)
        let table = outer(MLXArray(0 ..< longest).asType(.float32), invFreq)   // [longest, dimension/2]

        let merge = config.spatialMergeSize
        let (mergedH, mergedW) = (grid.h / merge, grid.w / merge)
        let blockRows = MLXArray(0 ..< mergedH).asType(.int32).reshaped(mergedH, 1, 1, 1)
        let blockCols = MLXArray(0 ..< mergedW).asType(.int32).reshaped(1, mergedW, 1, 1)
        let intra = MLXArray(0 ..< merge).asType(.int32)
        let mergeScalar = MLXArray(Int32(merge))
        let rows = broadcast(blockRows * mergeScalar + intra.reshaped(1, 1, merge, 1),
                             to: [mergedH, mergedW, merge, merge]).flattened()
        let cols = broadcast(blockCols * mergeScalar + intra.reshaped(1, 1, 1, merge),
                             to: [mergedH, mergedW, merge, merge]).flattened()
        var angles = concatenated([table[rows, 0...], table[cols, 0...]], axis: -1)
        if grid.t > 1 { angles = tiled(angles, repetitions: [grid.t, 1]) }
        return angles
    }

    /// The learned 48×48 position table, interpolated to this image's grid
    /// and laid out in merged-block order.
    private func positionalEmbeddings(_ grid: Qwen35Grid) -> MLXArray {
        let (h, w) = (grid.h, grid.w)
        let maxIndex = gridPerSide - 1

        let hLine = MLXArray(0 ..< h).asType(.float32) * Float(maxIndex) / Float(max(1, h - 1))
        let wLine = MLXArray(0 ..< w).asType(.float32) * Float(maxIndex) / Float(max(1, w - 1))
        let hFloor = hLine.asType(.int32)
        let wFloor = wLine.asType(.int32)
        let hCeil = minimum(hFloor + 1, maxIndex)
        let wCeil = minimum(wFloor + 1, maxIndex)
        let dh = expandedDimensions(hLine - hFloor.asType(.float32), axis: 1)
        let dw = expandedDimensions(wLine - wFloor.asType(.float32), axis: 0)

        let side = gridPerSide
        let baseFloor = expandedDimensions(hFloor, axis: 1) * side
        let baseCeil = expandedDimensions(hCeil, axis: 1) * side
        let wf = expandedDimensions(wFloor, axis: 0)
        let wc = expandedDimensions(wCeil, axis: 0)

        let corners: [(MLXArray, MLXArray)] = [
            ((baseFloor + wf).flattened(), ((1 - dh) * (1 - dw)).flattened()),
            ((baseFloor + wc).flattened(), ((1 - dh) * dw).flattened()),
            ((baseCeil + wf).flattened(), (dh * (1 - dw)).flattened()),
            ((baseCeil + wc).flattened(), (dh * dw).flattened()),
        ]
        // (The table may be stored quantised; its looked-up rows aren't.)
        let lookups = corners.map { posEmbed($0.0.asType(.int32)) }
        let dtype = lookups[0].dtype
        var embeds = MLXArray.zeros([h * w, config.hiddenSize], dtype: dtype)
        for (lookup, corner) in zip(lookups, corners) {
            embeds = embeds + lookup * expandedDimensions(corner.1.asType(dtype), axis: -1)
        }

        let merge = config.spatialMergeSize
        let feature = embeds.dim(-1)
        var laidOut = tiled(embeds, repetitions: [grid.t, 1])
        laidOut = laidOut.reshaped(grid.t, h / merge, merge, w / merge, merge, feature)
            .transposed(0, 1, 3, 2, 4, 5)
            .reshaped(-1, feature)
        return laidOut
    }

    /// Weights under `vision_tower.` (prefix already removed), with the patch
    /// convolution in MLX's channels-last layout.
    func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var out: [String: MLXArray] = [:]
        for (key, value) in weights {
            if key.contains("position_ids") { continue }
            if key.contains("patch_embed.proj.weight"), value.ndim == 5, value.dim(-1) != config.inChannels {
                out[key] = value.transposed(0, 2, 3, 4, 1)
            } else {
                out[key] = value
            }
        }
        return out
    }
}
