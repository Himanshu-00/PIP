import Foundation

/// Turns text into Qwen's token ids and back.
///
/// Qwen uses byte-level BPE, the same scheme as GPT-2: text is split into
/// word-like pieces, each piece's UTF-8 bytes are mapped one-to-one onto
/// printable characters, and then pairs of symbols are merged, most frequent
/// pair first, until no learned merge applies. Every byte has a token, so
/// any text at all can be encoded — there is no "unknown" token.
///
/// Built from the model folder: `vocab.json` (piece → id), the merge rules
/// (`merges.txt`, or inside `tokenizer.json` for newer models like Qwen3.5),
/// and the special tokens like `<|im_start|>` (from `tokenizer_config.json`
/// or `tokenizer.json`).
final class QwenTokenizer {

    enum Failure: Error { case missingFile(String) }

    private let vocabulary: [String: Int]
    private let pieces: [Int: String]
    /// "a b" → priority. Lower merges first.
    private let ranks: [String: Int]
    /// Special tokens, matched whole in the text before anything else.
    private let special: [String: Int]
    private let specialByID: [Int: String]
    private let specialPattern: NSRegularExpression?
    private let splitter: NSRegularExpression

    /// Encodings of pieces already seen. Prompts repeat the same words —
    /// the tool list alone is identical every turn — so this saves most of
    /// the merging work after the first message.
    private var cache: [String: [Int]] = [:]
    private let lock = NSLock()

    let endOfTurn: Int
    let endOfText: Int

    init(folder: URL) throws {
        func read(_ name: String) throws -> Data {
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { throw Failure.missingFile(name) }
            return data
        }

        // Newer models put merges and special tokens only in tokenizer.json —
        // and some exports (the reranker) put the vocabulary there too.
        let full = (try? read("tokenizer.json"))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let vocab: [String: Int]
        if let data = try? read("vocab.json") {
            vocab = try JSONSerialization.jsonObject(with: data) as? [String: Int] ?? [:]
        } else if let inFull = (full?["model"] as? [String: Any])?["vocab"] as? [String: Int] {
            vocab = inFull
        } else {
            throw Failure.missingFile("vocab.json")
        }

        var ranks: [String: Int] = [:]
        if let mergesData = try? read("merges.txt") {
            let mergesText = String(decoding: mergesData, as: UTF8.self)
            var rank = 0
            for line in mergesText.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("#version") { continue }
                ranks[String(line)] = rank
                rank += 1
            }
        } else if let model = full?["model"] as? [String: Any], let merges = model["merges"] as? [Any] {
            // Either "a b" strings or ["a", "b"] pairs, depending on the version.
            for (rank, merge) in merges.enumerated() {
                if let text = merge as? String {
                    ranks[text] = rank
                } else if let pair = merge as? [String], pair.count == 2 {
                    ranks[pair[0] + " " + pair[1]] = rank
                }
            }
        } else {
            throw Failure.missingFile("merges.txt")
        }

        var special: [String: Int] = [:]
        let config = (try? read("tokenizer_config.json"))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let added = config?["added_tokens_decoder"] as? [String: [String: Any]] {
            for (id, entry) in added {
                guard let number = Int(id), let content = entry["content"] as? String else { continue }
                special[content] = number
            }
        }
        if let added = full?["added_tokens"] as? [[String: Any]] {
            for entry in added {
                guard let content = entry["content"] as? String,
                      let id = (entry["id"] as? NSNumber)?.intValue else { continue }
                special[content] = id
            }
        }

        vocabulary = vocab
        var reverse: [Int: String] = [:]
        for (piece, id) in vocab { reverse[id] = piece }
        pieces = reverse
        self.ranks = ranks
        self.special = special
        specialByID = Dictionary(special.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

        // Longest first, so `</tool_call>` wins over any shorter token it contains.
        let alternatives = special.keys
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
        specialPattern = alternatives.isEmpty
            ? nil
            : try? NSRegularExpression(pattern: alternatives.joined(separator: "|"))

        // Qwen2's pre-tokenizer, verbatim from its tokenizer.json: contractions,
        // letter runs with one optional leading non-letter, single digits,
        // punctuation runs, newlines, and whitespace.
        // Newer models state their own (Qwen3.5 also keeps accent marks with
        // their letters).
        let qwen2Pattern =
            #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
        let pattern = config?["pretokenize_regex"] as? String ?? qwen2Pattern
        if let custom = try? NSRegularExpression(pattern: pattern) {
            splitter = custom
        } else {
            splitter = try NSRegularExpression(pattern: qwen2Pattern)
        }

        endOfTurn = special["<|im_end|>"] ?? 151_645
        endOfText = special["<|endoftext|>"] ?? 151_643
    }

    // MARK: - Encoding

    func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        let ns = text as NSString
        var cursor = 0

        // Special tokens are copied straight through; the text between them
        // is tokenised normally.
        let matches = specialPattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        for match in matches {
            if match.range.location > cursor {
                ids += encodeOrdinary(ns.substring(with: NSRange(location: cursor,
                                                                 length: match.range.location - cursor)))
            }
            if let id = special[ns.substring(with: match.range)] { ids.append(id) }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            ids += encodeOrdinary(ns.substring(from: cursor))
        }
        return ids
    }

    private func encodeOrdinary(_ text: String) -> [Int] {
        // NFC first, as the tokenizer's normaliser does.
        let normalised = text.precomposedStringWithCanonicalMapping
        let ns = normalised as NSString
        var ids: [Int] = []
        for match in splitter.matches(in: normalised, range: NSRange(location: 0, length: ns.length)) {
            ids += encodeWord(ns.substring(with: match.range))
        }
        return ids
    }

    private func encodeWord(_ word: String) -> [Int] {
        lock.lock()
        if let hit = cache[word] { lock.unlock(); return hit }
        lock.unlock()

        // Bytes → printable stand-in characters.
        var symbols = word.utf8.map { String(Self.byteToCharacter[Int($0)]) }

        // Merge the highest-priority adjacent pair, all of its occurrences,
        // until no adjacent pair has a learned merge.
        while symbols.count > 1 {
            var best: (rank: Int, pair: (String, String))?
            for index in 0 ..< symbols.count - 1 {
                if let rank = ranks[symbols[index] + " " + symbols[index + 1]],
                   rank < (best?.rank ?? .max) {
                    best = (rank, (symbols[index], symbols[index + 1]))
                }
            }
            guard let pair = best?.pair else { break }
            let (left, right) = pair

            var merged: [String] = []
            merged.reserveCapacity(symbols.count)
            var index = 0
            while index < symbols.count {
                if index < symbols.count - 1, symbols[index] == left, symbols[index + 1] == right {
                    merged.append(left + right)
                    index += 2
                } else {
                    merged.append(symbols[index])
                    index += 1
                }
            }
            symbols = merged
        }

        // Every single byte is in the vocabulary, so a symbol that somehow
        // isn't falls back to its bytes rather than being dropped.
        var ids: [Int] = []
        for symbol in symbols {
            if let id = vocabulary[symbol] {
                ids.append(id)
            } else {
                for character in symbol {
                    if let id = vocabulary[String(character)] { ids.append(id) }
                }
            }
        }

        lock.lock()
        if cache.count > 20_000 { cache.removeAll() }
        cache[word] = ids
        lock.unlock()
        return ids
    }

    // MARK: - Decoding

    func decode(_ ids: [Int]) -> String {
        var bytes: [UInt8] = []
        var out = ""
        for id in ids {
            if let token = specialByID[id] {
                // Flush ordinary bytes before writing the special token as-is.
                out += String(decoding: bytes, as: UTF8.self)
                bytes.removeAll()
                out += token
                continue
            }
            guard let piece = pieces[id] else { continue }
            for character in piece {
                if let byte = Self.characterToByte[character] { bytes.append(byte) }
            }
        }
        out += String(decoding: bytes, as: UTF8.self)
        return out
    }

    // MARK: - Byte ↔ character map

    /// GPT-2's `bytes_to_unicode`: printable bytes map to themselves, the
    /// rest to characters from U+0100 upwards, so every byte has a visible
    /// stand-in and no piece ever contains a space or control character.
    static let byteToCharacter: [Character] = {
        var printable: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var codes = printable
        var extra = 0
        for byte in 0 ..< 256 where !printable.contains(byte) {
            printable.append(byte)
            codes.append(256 + extra)
            extra += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (byte, code) in zip(printable, codes) {
            table[byte] = Character(UnicodeScalar(UInt32(code))!)
        }
        return table
    }()

    private static let characterToByte: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (byte, character) in byteToCharacter.enumerated() { map[character] = UInt8(byte) }
        return map
    }()
}
