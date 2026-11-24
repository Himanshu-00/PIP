import Foundation

/// Text → the 77 token ids MobileCLIP's text encoder reads (CLIP's BPE).
final class CLIPTokenizer: @unchecked Sendable {

    static let contextLength = 77

    private let vocabulary: [String: Int32]
    private let ranks: [String: Int]
    private let start: Int32
    private let end: Int32
    private let splitter = try! NSRegularExpression(
        pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#)
    private var cache: [String: [Int32]] = [:]
    private let lock = NSLock()

    /// `clip-vocab.json` (token → id) and `clip-merges.txt` from the folder.
    init(folder: URL) throws {
        let data = try Data(contentsOf: folder.appendingPathComponent("clip-vocab.json"))
        let raw = try JSONDecoder().decode([String: Int32].self, from: data)
        vocabulary = raw
        let merges = try String(contentsOf: folder.appendingPathComponent("clip-merges.txt"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        // CLIP uses the first 49152 − 256 − 2 merges, after the version line.
        var ranks: [String: Int] = [:]
        for (rank, line) in merges.dropFirst().prefix(49_152 - 256 - 2).enumerated() { ranks[String(line)] = rank }
        self.ranks = ranks
        guard let start = raw["<|startoftext|>"], let end = raw["<|endoftext|>"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.start = start
        self.end = end
    }

    /// Exactly `contextLength` ids: start, the text (cut to fit), end, zeros.
    func encode(_ text: String) -> [Int32] {
        let cleaned = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let ns = cleaned as NSString
        var ids: [Int32] = []
        for match in splitter.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            ids += encodeWord(ns.substring(with: match.range))
        }
        ids = [start] + ids.prefix(Self.contextLength - 2) + [end]
        return ids + Array(repeating: 0, count: Self.contextLength - ids.count)
    }

    private func encodeWord(_ word: String) -> [Int32] {
        lock.lock()
        if let hit = cache[word] { lock.unlock(); return hit }
        lock.unlock()

        var symbols = word.utf8.map { String(QwenTokenizer.byteToCharacter[Int($0)]) }
        guard !symbols.isEmpty else { return [] }
        symbols[symbols.count - 1] += "</w>"

        // Merge the best-ranked adjacent pair, every occurrence, until none applies.
        while symbols.count > 1 {
            var best: (rank: Int, left: String, right: String)?
            for index in 0 ..< symbols.count - 1 {
                if let rank = ranks[symbols[index] + " " + symbols[index + 1]], rank < (best?.rank ?? .max) {
                    best = (rank, symbols[index], symbols[index + 1])
                }
            }
            guard let best else { break }
            var merged: [String] = []
            var index = 0
            while index < symbols.count {
                if index < symbols.count - 1, symbols[index] == best.left, symbols[index + 1] == best.right {
                    merged.append(best.left + best.right)
                    index += 2
                } else {
                    merged.append(symbols[index])
                    index += 1
                }
            }
            symbols = merged
        }
        let ids = symbols.compactMap { vocabulary[$0] }

        lock.lock()
        cache[word] = ids
        lock.unlock()
        return ids
    }
}
