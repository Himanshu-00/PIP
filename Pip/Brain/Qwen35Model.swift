//
//  Qwen35Model.swift
//
//  Qwen3.5 (text part) for MLX, written for this app.
//
//  Ported from Apple's mlx-lm (`mlx_lm/models/qwen3_5.py`, `qwen3_next.py`,
//  `gated_delta.py`, MIT License, Copyright © 2025–2026 Apple Inc.), with the
//  fused Metal kernel for the gated delta rule from mlx-swift-lm
//  (`Libraries/MLXLMCommon/GatedDelta.swift`, MIT License). Only what one
//  conversation on one Mac needs is kept: no batching, padding masks,
//  training paths, mixture-of-experts, speculative decoding or vision.
//

import Foundation
import MLX
import MLXNN

/*
 How Qwen3.5 differs from Qwen3

 Three out of every four layers don't use attention at all. They use a
 "gated delta net": a fixed-size memory matrix per head that every new
 token updates (forget a little, write what's new) and then reads from.
 Reading a long prompt costs the same per token no matter how long it gets,
 and the cache for those layers is a few small matrices instead of keys and
 values for every token so far. Every fourth layer is ordinary attention —
 with a gate on its output — so the model can still look back precisely.
*/

// MARK: - Configuration

struct Qwen35Configuration: Sendable {
    var hiddenSize: Int
    var hiddenLayers: Int
    var intermediateSize: Int
    var attentionHeads: Int
    var kvHeads: Int
    var headDim: Int
    var linearNumValueHeads: Int
    var linearNumKeyHeads: Int
    var linearKeyHeadDim: Int
    var linearValueHeadDim: Int
    var linearConvKernelDim: Int
    var rmsNormEps: Float
    var vocabularySize: Int
    var ropeTheta: Float
    var partialRotaryFactor: Float
    var fullAttentionInterval: Int
    var mropeSection: [Int]
    var tieWordEmbeddings: Bool
    var quantization: WeightQuantization?

    /// Reads `config.json`: the language model's settings sit under
    /// `text_config`, quantisation at the top level.
    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalBrain.Failure(message: "My brain's settings file is unreadable.")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        func int(_ key: String, _ fallback: Int) -> Int { (text[key] as? NSNumber)?.intValue ?? fallback }
        func float(_ key: String, _ fallback: Float) -> Float { (text[key] as? NSNumber)?.floatValue ?? fallback }

        hiddenSize = int("hidden_size", 4096)
        hiddenLayers = int("num_hidden_layers", 32)
        intermediateSize = int("intermediate_size", 12288)
        attentionHeads = int("num_attention_heads", 16)
        kvHeads = int("num_key_value_heads", 4)
        headDim = int("head_dim", hiddenSize / attentionHeads)
        linearNumValueHeads = int("linear_num_value_heads", 32)
        linearNumKeyHeads = int("linear_num_key_heads", 16)
        linearKeyHeadDim = int("linear_key_head_dim", 128)
        linearValueHeadDim = int("linear_value_head_dim", 128)
        linearConvKernelDim = int("linear_conv_kernel_dim", 4)
        rmsNormEps = float("rms_norm_eps", 1e-6)
        vocabularySize = int("vocab_size", 248_320)
        fullAttentionInterval = int("full_attention_interval", 4)

        let rope = text["rope_parameters"] as? [String: Any] ?? text
        ropeTheta = (rope["rope_theta"] as? NSNumber)?.floatValue ?? 10_000_000
        partialRotaryFactor = (rope["partial_rotary_factor"] as? NSNumber)?.floatValue ?? 0.25
        mropeSection = (rope["mrope_section"] as? [NSNumber])?.map(\.intValue) ?? [11, 11, 10]

        tieWordEmbeddings = (root["tie_word_embeddings"] as? Bool)
            ?? (text["tie_word_embeddings"] as? Bool) ?? false

        if let q = (root["quantization"] ?? root["quantization_config"]) as? [String: Any],
           let groupSize = (q["group_size"] as? NSNumber)?.intValue,
           let bits = (q["bits"] as? NSNumber)?.intValue {
            let json = try JSONSerialization.data(withJSONObject: ["group_size": groupSize, "bits": bits])
            quantization = try JSONDecoder().decode(WeightQuantization.self, from: json)
        } else {
            quantization = nil
        }
    }
}

// MARK: - Small pieces

/// RMS norm whose output is then gated: `silu(gate) * norm(x)`, in float32.
final class Qwen35RMSNormGated: Module {
    let weight: MLXArray
    let eps: Float

    init(dimensions: Int, eps: Float) {
        weight = MLXArray.ones([dimensions])
        self.eps = eps
    }

    func callAsFunction(_ x: MLXArray, gate: MLXArray) -> MLXArray {
        let normed = MLXFast.rmsNorm(x, weight: weight, eps: eps)
        return (silu(gate.asType(.float32)) * normed.asType(.float32)).asType(x.dtype)
    }
}

final class Qwen35MLP: Module {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    init(dimensions: Int, hiddenDimensions: Int) {
        _gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        _down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        _up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

// MARK: - Positions for images

/// Rotary position embedding over (time, row, column) positions — Qwen3.5's
/// "interleaved M-RoPE". Each rotated frequency follows one of the three
/// coordinates (mostly time, every third one row or column), so image tokens
/// carry where they sit in the picture. With all three positions equal
/// (plain text) it is ordinary rotary embedding.
/// From mlx-swift-lm's MLXVLM/Models/Qwen35.swift (MIT).
final class Qwen35MRoPE {
    private let invFreq: MLXArray
    private let sectionIndices: MLXArray
    private let dimensions: Int

    init(dimensions: Int, base: Float, sections: [Int]) {
        self.dimensions = dimensions
        let half = max(1, dimensions / 2)
        let exponents = MLXArray(stride(from: 0, to: half * 2, by: 2)).asType(.float32) / Float(dimensions)
        invFreq = 1.0 / pow(MLXArray(base), exponents)

        let s = sections.count >= 3 ? sections : [11, 11, 10]
        var indices = [Int32](repeating: 0, count: half)
        for (coordinate, start) in [(1, 1), (2, 2)] {
            let end = min(s[coordinate] * 3, half)
            for index in stride(from: start, to: end, by: 3) { indices[index] = Int32(coordinate) }
        }
        sectionIndices = MLXArray(indices)
    }

    /// `positions`: [3, L]. Rotates the first `dimensions` of each head.
    func callAsFunction(queries: MLXArray, keys: MLXArray, positions: MLXArray) -> (MLXArray, MLXArray) {
        // [3, L, half] angles; pick the coordinate each frequency follows.
        let angles = positions.asType(.float32)[0..., 0..., .newAxis] * invFreq[.newAxis, .newAxis, 0...]
        let half = invFreq.dim(0)
        let chosen = takeAlong(angles, broadcast(sectionIndices.reshaped(1, 1, half),
                                                  to: [1, angles.dim(1), half]), axis: 0)
            .squeezed(axis: 0)                                   // [L, half]
        let emb = concatenated([chosen, chosen], axis: -1)       // [L, dimensions]
        let cosines = cos(emb).asType(queries.dtype)[.newAxis, .newAxis, 0..., 0...]
        let sines = sin(emb).asType(queries.dtype)[.newAxis, .newAxis, 0..., 0...]
        return (rotate(queries, cosines, sines), rotate(keys, cosines, sines))
    }

    private func rotate(_ x: MLXArray, _ cosines: MLXArray, _ sines: MLXArray) -> MLXArray {
        let part = x[.ellipsis, ..<dimensions]
        let halfWidth = dimensions / 2
        let rotatedHalf = concatenated([-part[.ellipsis, halfWidth...], part[.ellipsis, ..<halfWidth]], axis: -1)
        let turned = part * cosines + rotatedHalf * sines
        guard dimensions < x.dim(-1) else { return turned }
        return concatenated([turned, x[.ellipsis, dimensions...]], axis: -1)
    }
}

// MARK: - Full attention (every fourth layer)

final class Qwen35Attention: Module {
    let heads: Int
    let kvHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let rope: RoPE
    /// Rotation for explicit (time, row, column) positions — used when an
    /// image is in the input. Text alone uses `rope`, which gives the same
    /// result when all three positions are equal.
    let multimodalRope: Qwen35MRoPE

    init(_ args: Qwen35Configuration) {
        heads = args.attentionHeads
        kvHeads = args.kvHeads
        headDim = args.headDim
        scale = pow(Float(headDim), -0.5)

        // The query projection is twice as wide: half queries, half an output gate.
        _wq.wrappedValue = Linear(args.hiddenSize, heads * headDim * 2, bias: false)
        _wk.wrappedValue = Linear(args.hiddenSize, kvHeads * headDim, bias: false)
        _wv.wrappedValue = Linear(args.hiddenSize, kvHeads * headDim, bias: false)
        _wo.wrappedValue = Linear(heads * headDim, args.hiddenSize, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)

        // Only the first quarter of each head is rotated by position.
        rope = RoPE(dimensions: Int(Float(headDim) * args.partialRotaryFactor),
                    traditional: false, base: args.ropeTheta)
        multimodalRope = Qwen35MRoPE(dimensions: Int(Float(headDim) * args.partialRotaryFactor),
                                     base: args.ropeTheta, sections: args.mropeSection)
    }

    func callAsFunction(_ x: MLXArray,
                        mask: MLXFast.ScaledDotProductAttentionMaskMode,
                        cache: KVCache?,
                        positions: MLXArray? = nil) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))

        let both = wq(x).reshaped(B, L, heads, headDim * 2)
        let halves = split(both, parts: 2, axis: -1)
        var queries = halves[0]
        let gate = halves[1].reshaped(B, L, -1)

        var keys = wk(x).reshaped(B, L, kvHeads, headDim)
        var values = wv(x).reshaped(B, L, kvHeads, headDim)

        queries = qNorm(queries).transposed(0, 2, 1, 3)
        keys = kNorm(keys).transposed(0, 2, 1, 3)
        values = values.transposed(0, 2, 1, 3)

        if let positions {
            (queries, keys) = multimodalRope(queries: queries, keys: keys, positions: positions)
        } else {
            let offset = (cache?.offset ?? 0) + (cache?.positionDelta ?? 0)
            queries = rope(queries, offset: offset)
            keys = rope(keys, offset: offset)
        }
        if let cache {
            (keys, values) = cache.update(keys: keys, values: values)
        }

        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: scale, mask: mask)
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)
        return wo(output * sigmoid(gate))
    }
}

// MARK: - Gated delta net (three layers in four)

final class Qwen35GatedDeltaNet: Module {
    let numVHeads: Int
    let numKHeads: Int
    let headKDim: Int
    let headVDim: Int
    let keyDim: Int
    let valueDim: Int
    let convKernelSize: Int
    let convDim: Int

    @ModuleInfo(key: "conv1d") var conv1d: Conv1d
    @ModuleInfo(key: "in_proj_qkv") var inProjQKV: Linear
    @ModuleInfo(key: "in_proj_z") var inProjZ: Linear
    @ModuleInfo(key: "in_proj_b") var inProjB: Linear
    @ModuleInfo(key: "in_proj_a") var inProjA: Linear
    @ParameterInfo(key: "dt_bias") var dtBias: MLXArray
    @ParameterInfo(key: "A_log") var aLog: MLXArray
    @ModuleInfo(key: "norm") var norm: Qwen35RMSNormGated
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(_ args: Qwen35Configuration) {
        numVHeads = args.linearNumValueHeads
        numKHeads = args.linearNumKeyHeads
        headKDim = args.linearKeyHeadDim
        headVDim = args.linearValueHeadDim
        keyDim = headKDim * numKHeads
        valueDim = headVDim * numVHeads
        convKernelSize = args.linearConvKernelDim
        convDim = keyDim * 2 + valueDim

        _conv1d.wrappedValue = Conv1d(inputChannels: convDim, outputChannels: convDim,
                                      kernelSize: convKernelSize, stride: 1, padding: 0,
                                      dilation: 1, groups: convDim, bias: false)
        _inProjQKV.wrappedValue = Linear(args.hiddenSize, keyDim * 2 + valueDim, bias: false)
        _inProjZ.wrappedValue = Linear(args.hiddenSize, valueDim, bias: false)
        _inProjB.wrappedValue = Linear(args.hiddenSize, numVHeads, bias: false)
        _inProjA.wrappedValue = Linear(args.hiddenSize, numVHeads, bias: false)
        _dtBias.wrappedValue = MLXArray.ones([numVHeads])
        _aLog.wrappedValue = MLXArray.zeros([numVHeads])     // replaced by the stored weights
        _norm.wrappedValue = Qwen35RMSNormGated(dimensions: headVDim, eps: args.rmsNormEps)
        _outProj.wrappedValue = Linear(valueDim, args.hiddenSize, bias: false)
    }

    func callAsFunction(_ x: MLXArray, cache: KVCache?) -> MLXArray {
        let (B, S) = (x.dim(0), x.dim(1))

        let qkv = inProjQKV(x)
        let z = inProjZ(x).reshaped(B, S, numVHeads, headVDim)
        let b = inProjB(x)
        let a = inProjA(x)

        // A short causal convolution over the last few inputs; the cache
        // carries the inputs it needs from before this call.
        let convState = cache?.conv ?? MLXArray.zeros([B, convKernelSize - 1, convDim], dtype: x.dtype)
        let convInput = concatenated([convState, qkv], axis: 1)
        if let cache {
            let keep = convKernelSize - 1
            cache.conv = contiguous(convInput[0..., (convInput.dim(1) - keep)..., 0...])
        }
        let convOut = silu(conv1d(convInput))

        let parts = split(convOut, indices: [keyDim, 2 * keyDim], axis: -1)
        var q = parts[0].reshaped(B, S, numKHeads, headKDim)
        var k = parts[1].reshaped(B, S, numKHeads, headKDim)
        let v = parts[2].reshaped(B, S, numVHeads, headVDim)

        // L2-normalise queries and keys, folding the 1/sqrt(d) read-out
        // scale into the queries (mlx-lm's `normalize_qk`).
        let invScale = pow(Float(headKDim), -0.5)
        let rmsEps: Float = 1e-6 * invScale * invScale
        q = MLXArray(invScale * invScale).asType(q.dtype) * MLXFast.rmsNorm(q, weight: MLXArray.mlxNone, eps: rmsEps)
        k = MLXArray(invScale).asType(k.dtype) * MLXFast.rmsNorm(k, weight: MLXArray.mlxNone, eps: rmsEps)

        let (out, state) = GatedDelta.update(q: q, k: k, v: v, a: a, b: b,
                                            aLog: aLog, dtBias: dtBias, state: cache?.recurrent)
        cache?.recurrent = state

        let gated = norm(out, gate: z)
        return outProj(gated.reshaped(B, S, -1))
    }
}

/// The gated delta rule: for each token, decay the memory, correct it
/// toward the new value for this key, and read it with the query. Runs as
/// one fused Metal kernel across all heads.
enum GatedDelta {

    static func update(q: MLXArray, k: MLXArray, v: MLXArray, a: MLXArray, b: MLXArray,
                       aLog: MLXArray, dtBias: MLXArray, state: MLXArray?) -> (MLXArray, MLXArray) {
        let beta = sigmoid(b).asType(.float32)
        let g = exp(-exp(aLog.asType(.float32)) * softplus(a + dtBias))

        let (B, T, Hk, Dk) = (k.dim(0), k.dim(1), k.dim(2), k.dim(3))
        let (Hv, Dv) = (v.dim(2), v.dim(3))
        var state = state ?? MLXArray.zeros([B, Hv, Dv, Dk], dtype: .float32)
        if state.dtype != .float32 { state = state.asType(.float32) }

        let outputs = kernel(
            [q, k, v, g, beta, state, MLXArray(T)],
            template: [
                ("InT", q.dtype), ("StT", state.dtype),
                ("Dk", Dk), ("Dv", Dv), ("Hk", Hk), ("Hv", Hv),
            ],
            grid: (32, Dv, B * Hv),
            threadGroup: (32, 4, 1),
            outputShapes: [[B, T, Hv, Dv], state.shape],
            outputDTypes: [q.dtype, state.dtype])
        return (outputs[0], outputs[1])
    }

    /// From mlx-swift-lm's GatedDelta.swift (MIT). Each simdgroup of 32
    /// threads owns one row of one head's state; Dk must be a multiple of 32
    /// (Qwen3.5 uses 128).
    private static let kernel = MLXFast.metalKernel(
        name: "pip_gated_delta_step",
        inputNames: ["q", "k", "v", "g", "beta", "state_in", "T"],
        outputNames: ["y", "state_out"],
        source: """
            auto n = thread_position_in_grid.z;
            auto b_idx = n / Hv;
            auto hv_idx = n % Hv;
            auto hk_idx = hv_idx / (Hv / Hk);
            constexpr int n_per_t = Dk / 32;

            auto q_ = q + b_idx * T * Hk * Dk + hk_idx * Dk;
            auto k_ = k + b_idx * T * Hk * Dk + hk_idx * Dk;
            auto v_ = v + b_idx * T * Hv * Dv + hv_idx * Dv;
            y += b_idx * T * Hv * Dv + hv_idx * Dv;

            auto dk_idx = thread_position_in_threadgroup.x;
            auto dv_idx = thread_position_in_grid.y;

            auto g_ = g + b_idx * T * Hv;
            auto beta_ = beta + b_idx * T * Hv;

            auto i_state = state_in + (n * Dv + dv_idx) * Dk;
            auto o_state = state_out + (n * Dv + dv_idx) * Dk;

            float state[n_per_t];
            for (int i = 0; i < n_per_t; ++i) {
              auto s_idx = n_per_t * dk_idx + i;
              state[i] = static_cast<float>(i_state[s_idx]);
            }

            for (int t = 0; t < T; ++t) {
              float kv_mem = 0.0f;
              {
                #pragma clang fp reassociate(off)
                #pragma clang fp contract(off)
                float kv_compensation = 0.0f;
                for (int i = 0; i < n_per_t; ++i) {
                  auto s_idx = n_per_t * dk_idx + i;
                  state[i] = state[i] * g_[hv_idx];
                  auto product = state[i] * k_[s_idx];
                  auto corrected = product - kv_compensation;
                  auto next_sum = kv_mem + corrected;
                  kv_compensation = (next_sum - kv_mem) - corrected;
                  kv_mem = next_sum;
                }
              }
              kv_mem = simd_sum(kv_mem);

              auto delta = (v_[dv_idx] - kv_mem) * beta_[hv_idx];

              float out = 0.0f;
              for (int i = 0; i < n_per_t; ++i) {
                auto s_idx = n_per_t * dk_idx + i;
                state[i] = state[i] + k_[s_idx] * delta;
                out += state[i] * q_[s_idx];
              }
              out = simd_sum(out);
              if (thread_index_in_simdgroup == 0) {
                y[dv_idx] = static_cast<InT>(out);
              }
              q_ += Hk * Dk;
              k_ += Hk * Dk;
              v_ += Hv * Dv;
              y += Hv * Dv;
              g_ += Hv;
              beta_ += Hv;
            }
            for (int i = 0; i < n_per_t; ++i) {
              auto s_idx = n_per_t * dk_idx + i;
              o_state[s_idx] = static_cast<StT>(state[i]);
            }
            """)
}

// MARK: - Layers and model

final class Qwen35DecoderLayer: Module {
    let isLinear: Bool

    @ModuleInfo(key: "linear_attn") var linearAttention: Qwen35GatedDeltaNet?
    @ModuleInfo(key: "self_attn") var attention: Qwen35Attention?
    let mlp: Qwen35MLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    init(_ args: Qwen35Configuration, index: Int) {
        isLinear = (index + 1) % args.fullAttentionInterval != 0
        if isLinear {
            _linearAttention.wrappedValue = Qwen35GatedDeltaNet(args)
        } else {
            _attention.wrappedValue = Qwen35Attention(args)
        }
        mlp = Qwen35MLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
        _inputLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    func callAsFunction(_ x: MLXArray,
                        mask: MLXFast.ScaledDotProductAttentionMaskMode,
                        cache: KVCache?,
                        positions: MLXArray? = nil) -> MLXArray {
        let normed = inputLayerNorm(x)
        let r: MLXArray
        if let linearAttention {
            r = linearAttention(normed, cache: cache)
        } else if let attention {
            r = attention(normed, mask: mask, cache: cache, positions: positions)
        } else {
            r = x * 0
        }
        let h = x + r
        return h + mlp(postAttentionLayerNorm(h))
    }
}

final class Qwen35ModelInner: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    fileprivate let layers: [Qwen35DecoderLayer]
    let norm: RMSNorm

    init(_ args: Qwen35Configuration) {
        _embedTokens.wrappedValue = Embedding(embeddingCount: args.vocabularySize,
                                              dimensions: args.hiddenSize)
        layers = (0 ..< args.hiddenLayers).map { Qwen35DecoderLayer(args, index: $0) }
        norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        forward(embeddings: embedTokens(inputs), positions: nil, cache: cache)
    }

    /// From embeddings rather than token ids — so image features can stand
    /// in for the image's placeholder tokens — with explicit 3-D positions
    /// ([3, L]: time, row, column) when an image is present.
    func forward(embeddings: MLXArray, positions: MLXArray?, cache: [KVCache]?) -> MLXArray {
        var h = embeddings
        let mask: MLXFast.ScaledDotProductAttentionMaskMode = h.dim(1) > 1 ? .causal : .none
        for (index, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[index], positions: positions)
        }
        return norm(h)
    }
}

final class Qwen35Model: Module, ChatLanguageModel {
    let configuration: Qwen35Configuration
    let model: Qwen35ModelInner

    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    init(_ args: Qwen35Configuration) {
        configuration = args
        model = Qwen35ModelInner(args)
        if !args.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
        }
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        head(model(inputs, cache: cache))
    }

    /// Scores from embeddings, for input that includes an image.
    func callAsFunction(embeddings: MLXArray, positions: MLXArray?, cache: [KVCache]?) -> MLXArray {
        head(model.forward(embeddings: embeddings, positions: positions, cache: cache))
    }

    private func head(_ out: MLXArray) -> MLXArray {
        if let lmHead { return lmHead(out) }
        return model.embedTokens.asLinear(out)
    }

    func newCache() -> [KVCache] {
        (0 ..< configuration.hiddenLayers).map { _ in KVCache() }
    }

    /// Keeps the language model's weights under the names this code uses:
    /// drops the vision tower and the speculative-decoding head, strips the
    /// `language_model.` prefix, and fixes up weights exported straight from
    /// the original checkpoint (conv layout, norms stored as offsets from 1).
    func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var out: [String: MLXArray] = [:]
        for (key, value) in weights {
            var name = key
            if name.hasPrefix("vision_tower") || name.hasPrefix("model.visual") || name.contains("mtp.") {
                continue
            }
            if name.hasPrefix("language_model.") {
                name = String(name.dropFirst("language_model.".count))
            } else if name.hasPrefix("model.language_model.") {
                name = "model." + name.dropFirst("model.language_model.".count)
            } else if !name.hasPrefix("model.") && !name.hasPrefix("lm_head") {
                continue
            }
            if configuration.tieWordEmbeddings, name.hasPrefix("lm_head.") { continue }
            out[name] = value
        }

        let rawCheckpoint = out.contains { $0.key.contains("conv1d.weight") && $0.value.dim(-1) != 1 }
        let normSuffixes = [".input_layernorm.weight", ".post_attention_layernorm.weight",
                            "model.norm.weight", ".q_norm.weight", ".k_norm.weight"]
        for (key, value) in out {
            if key.contains("conv1d.weight"), value.dim(-1) != 1 {
                out[key] = value.swappedAxes(1, 2)
            }
            if rawCheckpoint, value.ndim == 1, normSuffixes.contains(where: { key.hasSuffix($0) }) {
                out[key] = value + 1
            }
        }
        return out
    }
}
