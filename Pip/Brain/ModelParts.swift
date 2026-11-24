import Foundation
import MLX
import MLXNN

// Pieces shared by the brain's model code. The cache first came with the Qwen3
// port of ml-explore/mlx-swift-lm (MIT License), in a simplified form.

/// How the stored weights are quantised (`quantization` in config.json).
struct WeightQuantization: Codable, Sendable {
    var groupSize: Int
    var bits: Int

    enum CodingKeys: String, CodingKey {
        case groupSize = "group_size"
        case bits
    }
}

// MARK: - Cache

/// Every earlier token's keys and values, for one layer.
///
/// The simplest correct cache: append and keep everything. A conversation
/// with Pip is a couple of thousand tokens at most, so there's no need for the
/// sliding windows, quantised caches or preallocated buffers a general
/// library carries.
final class KVCache {
    private(set) var keys: MLXArray?
    private(set) var values: MLXArray?
    /// How many tokens are already in the cache — the position of the next one.
    private(set) var offset = 0

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        if let keys, let values {
            self.keys = concatenated([keys, newKeys], axis: 2)
            self.values = concatenated([values, newValues], axis: 2)
        } else {
            keys = newKeys
            values = newValues
        }
        offset += newKeys.dim(2)
        return (keys!, values!)
    }

    /// A cache that starts where this one is and then goes its own way.
    ///
    /// Cheap: MLX arrays are immutable, so the copy shares the same keys and
    /// values until either side appends — and appending makes a new array
    /// rather than changing the shared one. This is what lets the fixed
    /// start of every prompt (Pip's instructions and tool list) be read once
    /// and reused by every question after.
    /// Fills an empty cache from saved keys and values (see LocalBrain's
    /// header file).
    func restore(keys: MLXArray?, values: MLXArray?, offset: Int) {
        self.keys = keys
        self.values = values
        self.offset = offset
    }

    func copy() -> KVCache {
        let clone = KVCache()
        clone.keys = keys
        clone.values = values
        clone.offset = offset
        clone.conv = conv
        clone.recurrent = recurrent
        clone.positionDelta = positionDelta
        return clone
    }

    // Qwen3.5's linear-attention layers keep no keys and values, just a
    // small running state: the last few inputs for its short convolution,
    // and the recurrent memory matrix. They live here too, so every layer's
    // cache is the same type and copies the same way.
    var conv: MLXArray?
    var recurrent: MLXArray?
    /// After an image, text positions run behind token positions: the image
    /// took many tokens but only a few "steps" of position (its rows and
    /// columns). This is the difference, applied to everything after it.
    var positionDelta = 0
}

/// What LocalBrain needs from a model: read tokens through a cache and say
/// what comes next. `Qwen35Model` provides it.
protocol ChatLanguageModel: Module {
    /// Scores for the next token at every position: [B, L, vocabulary].
    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray
    func newCache() -> [KVCache]
    func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray]
}
