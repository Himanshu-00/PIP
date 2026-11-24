#if DEBUG
import Foundation
import ImageIO

/// Search quality as numbers (DEBUG): the hand set in
/// `Docs/tasks/search-eval-queries.json` and a replay of opened searches;
/// top-1, top-3, MRR.
@MainActor
enum SearchChecks {

    private struct Check: Decodable {
        let query: String
        /// Parts of accepted files' paths — any one counts.
        let expect: [String]
        /// "List all" checks: every one of these should be in Pip's list (path parts).
        let every: [String]
        let note: String?

        private enum Keys: String, CodingKey { case query, expect, every, note }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            query = try container.decode(String.self, forKey: .query)
            note = try container.decodeIfPresent(String.self, forKey: .note)
            every = try container.decodeIfPresent([String].self, forKey: .every) ?? []
            if let many = try? container.decode([String].self, forKey: .expect) {
                expect = many
            } else if let one = try? container.decode(String.self, forKey: .expect) {
                expect = [one]
            } else {
                expect = every
            }
        }
    }

    /// The checks file, read from the source tree (it isn't bundled).
    private static var file: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Docs/tasks/search-eval-queries.json")
    }

    /// The task docs hold every test query word for word, so they match them
    /// all. Not a search fault — left out of the ranking.
    private static var docs: String { file.deletingLastPathComponent().deletingLastPathComponent().path + "/" }

    private static let home = NSHomeDirectory()

    private static func short(_ path: String) -> String { path.replacingOccurrences(of: home, with: "~") }

    /// Just the hand set (`--args -searchChecks YES`), one log line per check.
    static func runHandSet() async {
        await handSet()
        await SearchLog.shared.discardPending()
    }

    static func run() async {
        await handSet()
        await replay()
        await photoEngineAlone()
        await SearchLog.shared.discardPending()
    }

    /// One line of numbers: top-1, top-3, MRR over ranks (nil = missing).
    private static func summary(_ ranks: [Int?]) -> String {
        let total = ranks.count
        let within = { (n: Int) in ranks.filter { ($0 ?? 99) <= n }.count }
        let mrr = total == 0 ? 0 : ranks.reduce(0.0) { $0 + ($1.map { 1 / Double($0) } ?? 0) } / Double(total)
        return String(format: "top1 %ld/%ld, top3 %ld/%ld, MRR %.2f", within(1), total, within(3), total, mrr)
    }

    private static func ranked(_ query: String) async -> [Candidate] {
        // An open recorded for this same query is the answer itself.
        SearchLog.ignoredOpenQuery = query
        defer { SearchLog.ignoredOpenQuery = nil }
        return await SearchController.forPip.find(query).filter { !$0.url.path.hasPrefix(docs) }
    }

    /// Queries' results with why (`--args -searchDebug "flight ticket latest"`).
    /// Several at once with " || "; "query => part of a path" also says where
    /// that file came (or that it wasn't found at all).
    static func explain(_ queries: String) async {
        for item in queries.components(separatedBy: " || ") {
            let parts = item.components(separatedBy: " => ")
            let query = parts[0]
            let results = await ranked(query)
            let line = { (candidate: Candidate) -> String in
                let f = candidate.features
                let date = candidate.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) } ?? "-"
                return String(format: "%.2f %@ name %.2f text %.2f%@ sem %.2f recent %.2f fam %.2f type %.2f retr %.2f %@ — %@",
                    candidate.score, candidate.matchesAll ? "ALL" : "   ", f.nameMatch, f.textMatch,
                    f.textWasMeasured ? "" : "?", f.semanticMatch, f.recency, f.familiarity, f.typeMatch, f.retrievalRank, date,
                    short(candidate.url.path))
            }
            ActivityLog.write(.search, "explain \"\(query)\": \(results.count) results")
            let photos = await PhotoVectors.shared.search(QueryParse(query).phrase, limit: 60)
            if !photos.isEmpty {
                let at = { (n: Int) in photos.count > n ? String(format: "%.3f", photos[n].similarity) : "-" }
                ActivityLog.write(.search, "  photo vectors: 1st \(at(0)), 5th \(at(4)), 20th \(at(19)), 60th \(at(59)) — "
                                  + photos.prefix(2).map(\.url.lastPathComponent).joined(separator: ", "))
            }
            for candidate in results.prefix(parts.count > 1 ? 5 : 30) { ActivityLog.write(.search, "  " + line(candidate)) }
            if parts.count > 1 {
                if let at = results.firstIndex(where: { $0.url.path.contains(parts[1]) }) {
                    ActivityLog.write(.search, "  wanted at \(at + 1): " + line(results[at]))
                } else {
                    ActivityLog.write(.search, "  wanted \(parts[1]): not in the list")
                }
            }
        }
        ActivityLog.write(.search, "explain done")
    }

    private static func handSet() async {
        guard let data = try? Data(contentsOf: file),
              let checks = try? JSONDecoder().decode([Check].self, from: data) else {
            ActivityLog.write(.search, "search checks: can't read \(file.path)")
            return
        }
        var engineRanks: [Int?] = []
        var pipRanks: [Int?] = []
        var everyFound = 0, everyWanted = 0
        for check in checks {
            let results = await ranked(check.query)
            let engine = Array(results.prefix(12)).map(\.url)
            // Why the top three won: score, every-word flag, and the features.
            for candidate in results.prefix(3) {
                let f = candidate.features
                ActivityLog.write(.search, String(format: "  %.2f %@ name %.2f text %.2f%@ sem %.2f recent %.2f type %.0f — %@",
                    candidate.score, candidate.matchesAll ? "ALL" : "   ", f.nameMatch, f.textMatch,
                    f.textWasMeasured ? "" : "?", f.semanticMatch, f.recency, f.typeMatch, short(candidate.url.path)))
            }
            SearchLog.ignoredOpenQuery = check.query
            let pip = Array(await FileFinder.find(check.query).filter { !$0.path.hasPrefix(docs) }.prefix(12))
            SearchLog.ignoredOpenQuery = nil
            // 1…12, or nil: missing from the first twelve.
            let rank = { (urls: [URL]) in
                urls.firstIndex { url in check.expect.contains { url.path.contains($0) } }.map { $0 + 1 }
            }
            engineRanks.append(rank(engine))
            pipRanks.append(rank(pip))
            let shown = { (r: Int?) in r.map(String.init) ?? "missing" }
            if !check.every.isEmpty {
                let missing = check.every.filter { part in !pip.contains { $0.path.contains(part) } }
                let wrong = pip.filter { url in !check.every.contains { url.path.contains($0) } }
                everyFound += check.every.count - missing.count
                everyWanted += check.every.count
                ActivityLog.write(.search, "list check \"\(check.query)\" → \(check.every.count - missing.count)/\(check.every.count) in Pip's \(pip.count)"
                                  + (missing.isEmpty ? "" : " — missing: " + missing.joined(separator: ", "))
                                  + (wrong.isEmpty ? "" : " — others: " + wrong.prefix(6).map(\.lastPathComponent).joined(separator: ", ")))
            }
            ActivityLog.write(.search, "search check \"\(check.query)\" → rank \(shown(engineRanks.last!)) (pip \(shown(pipRanks.last!)))"
                              + " — top: " + engine.prefix(3).map { short($0.path) }.joined(separator: ", "))
        }
        ActivityLog.write(.search, "checks: \(summary(engineRanks)) (pip: \(summary(pipRanks)))"
                          + (everyWanted == 0 ? "" : ", lists \(everyFound)/\(everyWanted)"))
    }

    /// Photo picks only (replay + hand set): the photo vectors alone versus
    /// today's engine, on the same queries — search v3 phase 2's check.
    private static func photoEngineAlone() async {
        let images = ["png", "jpg", "jpeg", "heic", "webp"]
        var cases: [(query: String, accepted: [String])] = []
        var seen = Set<String>()
        for pick in await SearchLog.shared.picks()
        where images.contains((pick.path as NSString).pathExtension.lowercased())
            && FileManager.default.fileExists(atPath: pick.path) {
            let key = pick.query.lowercased() + "\n" + pick.path
            if seen.insert(key).inserted { cases.append((pick.query, [pick.path])) }
        }
        if let data = try? Data(contentsOf: file), let checks = try? JSONDecoder().decode([Check].self, from: data) {
            for check in checks where check.expect.allSatisfy({ images.contains(($0 as NSString).pathExtension.lowercased()) || !$0.contains(".") }) {
                cases.append((check.query, check.expect))
            }
        }
        let held = await PhotoVectors.shared.count()
        var photoRanks: [Int?] = []
        var engineRanks: [Int?] = []
        for item in cases {
            let parse = QueryParse(item.query)
            let photos = await PhotoVectors.shared.search(parse.phrase, limit: 30).map(\.url.path)
            let engine = await ranked(item.query).prefix(30).map(\.url.path)
            let rank = { (list: [String]) in list.firstIndex { path in item.accepted.contains { path.contains($0) } }.map { $0 + 1 } }
            photoRanks.append(rank(photos))
            engineRanks.append(rank(Array(engine)))
            ActivityLog.write(.search, "  photo \"\(parse.phrase)\": vectors \(photoRanks.last!.map(String.init) ?? "-")"
                              + ", engine \(engineRanks.last!.map(String.init) ?? "-")"
                              + " — " + photos.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
        }
        ActivityLog.write(.search, "photo engine alone (\(held) photos with vectors), \(cases.count) photo queries: "
                          + "vectors \(summary(photoRanks)); engine \(summary(engineRanks))")
    }

    /// Photo precision, judged by Pip's vision (yes/no per top-five photo).
    static func photoPrecision() async {
        let queries = ["blue suit", "grey suit", "yellow kurta", "wedding stage", "car", "headphones",
                       "beach", "food on a plate", "dog", "receipt", "birthday cake", "mountains"]
        var vectorHits = 0, engineHits = 0, vectorShown = 0, engineShown = 0
        for query in queries {
            let vectors = await PhotoVectors.shared.search(query, limit: 5).map(\.url)
            let engine = Array(await ranked(query + " photo").map(\.url).filter {
                ["png", "jpg", "jpeg", "heic", "webp"].contains($0.pathExtension.lowercased())
            }.prefix(5))
            var line: [String] = []
            for (name, urls) in [("vectors", vectors), ("engine", engine)] {
                var yes = 0
                for url in urls {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                              kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceCreateThumbnailWithTransform: true,
                              kCGImageSourceThumbnailMaxPixelSize: 448] as CFDictionary),
                          let answer = try? await LocalBrain.shared.look(
                              at: image, question: "Does this picture show: \(query)? Answer only yes or no.",
                              system: "Answer only yes or no.", answerLimit: 3) else { continue }
                    if answer.lowercased().hasPrefix("yes") { yes += 1 }
                }
                line.append("\(name) \(yes)/\(urls.count)")
                if name == "vectors" { vectorHits += yes; vectorShown += urls.count } else { engineHits += yes; engineShown += urls.count }
            }
            ActivityLog.write(.search, "  rated \"\(query)\": " + line.joined(separator: ", "))
        }
        ActivityLog.write(.search, "photo precision (vision-rated): engine \(engineHits)/\(engineShown), vectors \(vectorHits)/\(vectorShown)")
    }

    /// The owner's own searches that ended in an open, rerun now. One per
    /// distinct query and file; files gone from disk are skipped.
    private static func replay() async {
        var seen = Set<String>()
        var picks: [(query: String, path: String)] = []
        var gone = 0
        for pick in await SearchLog.shared.picks() {
            let key = pick.query.lowercased().trimmingCharacters(in: .whitespaces) + "\n" + pick.path
            guard seen.insert(key).inserted else { continue }
            guard FileManager.default.fileExists(atPath: pick.path) else { gone += 1; continue }
            picks.append(pick)
        }
        var ranks: [Int?] = []
        var misses: [(query: String, path: String, rank: Int?)] = []
        for pick in picks {
            let results = await ranked(pick.query)
            // The engine shows one of identical copies; either is the pick.
            let copy = SearchController.copyKey(URL(fileURLWithPath: pick.path))
            let rank = results.prefix(30).firstIndex {
                $0.url.path == pick.path || (copy != nil && SearchController.copyKey($0.url) == copy)
            }.map { $0 + 1 }
            ranks.append(rank)
            if (rank ?? 99) > 3 { misses.append((pick.query, pick.path, rank)) }
        }
        ActivityLog.write(.search, "replay: \(picks.count) picks (\(gone) skipped, file gone): \(summary(ranks))")
        // Every pick's rank, to compare two builds line by line.
        let lines = zip(picks, ranks).map { pick, rank in
            "\(rank.map(String.init) ?? "-")\t\(pick.query)\t\((pick.path as NSString).lastPathComponent)"
        }
        let report = AppFolders.logs.appendingPathComponent("search-replay.txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        // The worst ten: missing first, then the lowest ranks.
        for miss in misses.sorted(by: { ($0.rank ?? 99) > ($1.rank ?? 99) }).prefix(10) {
            ActivityLog.write(.search, "  replay miss \"\(miss.query)\" → \((miss.path as NSString).lastPathComponent)"
                              + " at \(miss.rank.map(String.init) ?? "missing")")
        }
    }
}
#endif
