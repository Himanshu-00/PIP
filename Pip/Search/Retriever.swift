import AppKit

/// Spotlight as a wide, cheap retriever; ranking happens later. Takes about
/// 1.4 s, so names already known are shown first. Don't bring back partial
/// results while gathering (see Docs/history/Search.md: it crashed).
@MainActor
final class Retriever {

    /// Raw Spotlight attribute names (not every one has a Foundation constant).
    private enum Attribute {
        static let path = "kMDItemPath"
        static let displayName = "kMDItemDisplayName"
        static let modified = "kMDItemContentModificationDate"
        static let lastUsed = "kMDItemLastUsedDate"
        static let useCount = "kMDItemUseCount"
        static let whereFroms = "kMDItemWhereFroms"
        static let title = "kMDItemTitle"
    }

    /// The query string actually handed to Spotlight, for diagnostics. When
    /// nothing comes back, the first thing worth seeing is what was asked.
    private(set) var lastPredicate = ""
    private var queries: [NSMetadataQuery] = []
    private var observers: [Any] = []

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Runs one query and calls back once. Results are ordered by Spotlight's
    /// own ranking, which is kept as a feature rather than discarded.
    func search(_ text: String,
                in folder: URL?,
                limit: Int = 300,
                completion: @escaping ([Candidate]) -> Void) {

        cancel()
        generation += 1
        let current = generation
        let words = Tokens.query(text)
        guard !words.isEmpty else { completion([]); return }

        // Files holding every word first; any word only if that comes back thin.
        let required = Self.requiredWords(words)
        guard required.count >= 2 else {
            start(Self.predicate(for: words), words: words, folder: folder, limit: limit, completion: completion)
            return
        }
        start(Self.allWordsPredicate(for: required), words: words, folder: folder, limit: limit) { [weak self] found in
            var every = found
            for index in every.indices { every[index].matchesAll = true }
            guard let self, self.generation == current, every.count < 25 else {
                completion(every)
                return
            }
            self.start(Self.predicate(for: words), words: words, folder: folder, limit: limit) { anyWord in
                let seen = Set(every.map(\.url))
                completion(every + anyWord.filter { !seen.contains($0.url) })
            }
        }
    }

    /// Bumped by every search, so the second half of an older one doesn't
    /// start after a newer search has begun.
    private var generation = 0

    /// Words a file must contain for the all-words query: not the ones that
    /// describe a file ("paper", "pdf", "last week"), and not two-letter
    /// words, which Spotlight's content index often drops.
    private static func requiredWords(_ words: [String]) -> [String] {
        let describing: Set<String> = [
            "paper", "article", "file", "document", "doc", "pdf", "docx", "slide", "slides", "deck",
            "presentation", "sheet", "spreadsheet", "image", "picture", "photo", "screenshot", "video", "pic", "pics", "selfie",
            "today", "yesterday", "last", "this", "week", "month", "year", "recent", "latest", "new", "old",
            "around", "roughly", "approximately", "during", "wearing", "wear",
        ]
        return words.filter {
            !describing.contains($0) && !QueryTime.isTimeWord($0) && ($0.count >= 3 || $0.contains(where: \.isNumber))
        }
    }

    /// Each word somewhere — name, title, text or download address — and all
    /// of them.
    private static func allWordsPredicate(for words: [String]) -> (NSPredicate, String) {
        var perWord: [NSPredicate] = []
        var described: [String] = []
        for word in words {
            let (either, text) = predicate(for: [word])
            perWord.append(either)
            described.append("(\(text))")
        }
        return (NSCompoundPredicate(andPredicateWithSubpredicates: perWord), described.joined(separator: " && "))
    }

    /// One Spotlight query: gather, read off-main, call back once.
    private func start(_ built: (NSPredicate, String), words: [String], folder: URL?, limit: Int,
                       completion: @escaping ([Candidate]) -> Void) {
        let query = NSMetadataQuery()
        let (predicate, description) = built
        query.predicate = predicate
        lastPredicate = description
        query.searchScopes = folder.map { [$0] } ?? [NSMetadataQueryUserHomeScope]
        // No sort descriptor (Spotlight's relevance is the better prior); not live.
        query.notificationBatchingInterval = 0.2

        // Its own queue: gathering on main froze typing.
        let queue = OperationQueue()
        queue.name = "com.himanshu.dynamicnotch.spotlight"
        queue.maxConcurrentOperationCount = 1
        query.operationQueue = queue

        let token = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query, queue: queue) { notification in
                // The query from the notification, not captured: it isn't
                // Sendable, and this runs on its own queue.
                guard let query = notification.object as? NSMetadataQuery else { return }
                query.disableUpdates()
                query.stop()
                // Read here, on the query's own queue. Touching results from
                // another thread is exactly the race this queue exists to
                // avoid.
                let results = Self.candidates(from: query, words: words, limit: limit)
                Task { @MainActor in
                    completion(results)
                }
            }
        observers.append(token)

        queries.append(query)
        query.start()
    }

    func cancel() {
        queries.forEach { $0.stop() }
        queries.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    // MARK: - Query building

    /// Any word, anywhere, built clause by clause (one malformed clause nils the
    /// whole predicate).
    private static func predicate(for words: [String]) -> (NSPredicate, String) {
        var parsed: [NSPredicate] = []
        var described: [String] = []

        for word in words {
            let escaped = word.replacingOccurrences(of: "\"", with: "")
            // Names `*word*`, content `word*` (the content index is by prefix).
            let clauses = [
                "kMDItemFSName == \"*\(escaped)*\"cd",
                "kMDItemDisplayName == \"*\(escaped)*\"cd",
                "kMDItemTextContent == \"\(escaped)*\"cd",
                "kMDItemWhereFroms == \"*\(escaped)*\"cd",
                "kMDItemTitle == \"*\(escaped)*\"cd",
            ]
            for clause in clauses {
                guard let predicate = NSPredicate(fromMetadataQueryString: clause) else { continue }
                parsed.append(predicate)
                described.append(clause)
            }
        }

        guard !parsed.isEmpty else {
            // Everything failed to parse. A plain filename match is the one
            // thing that must never stop working, so it's the floor.
            let fallback = words.compactMap {
                NSPredicate(fromMetadataQueryString: "kMDItemFSName == \"*\($0)*\"cd")
            }
            return (NSCompoundPredicate(orPredicateWithSubpredicates: fallback),
                    "FALLBACK: filename only")
        }
        return (NSCompoundPredicate(orPredicateWithSubpredicates: parsed),
                described.joined(separator: " || "))
    }

    // MARK: - Reading results

    /// Two passes: names to decide what to keep, the other attributes for the
    /// survivors only.
    private nonisolated static func candidates(from query: NSMetadataQuery,
                                               words: [String],
                                               limit: Int) -> [Candidate] {
        // Also lowered from four thousand. Past a point these are all files
        // that matched one word weakly, and reading more of them buys nothing
        // the ranker can use.
        let ceiling = 1_500

        // Pass one: names only.
        var shortlist: [(index: Int, url: URL, name: String, score: Double)] = []
        shortlist.reserveCapacity(min(query.resultCount, ceiling))

        for index in 0..<min(query.resultCount, ceiling) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: Attribute.path) as? String
            else { continue }

            let url = URL(fileURLWithPath: path)
            // Bundles are directories pretending to be files. Returning the
            // hundred files inside an .app is never what anyone meant.
            guard !isInsideBundle(url) else { continue }
            // Never ~/Library (Mail, Messages, app data), hidden or
            // generated folders — Spotlight's home scope includes them all.
            guard !DirectScan.isExcluded(path) else { continue }

            let name = url.lastPathComponent
            shortlist.append((index, url, name, Fuzzy.score(words: words, against: name)))
        }

        // Name matches first, then Spotlight's own order, which is a better
        // prior than nothing.
        shortlist.sort { left, right in
            left.score != right.score ? left.score > right.score : left.index < right.index
        }

        // Pass two: everything else, only for what survived.
        var kept: [Candidate] = []
        kept.reserveCapacity(min(shortlist.count, limit))

        for (position, entry) in shortlist.prefix(limit).enumerated() {
            let item = query.result(at: entry.index) as? NSMetadataItem

            var candidate = Candidate(
                url: entry.url,
                displayName: item?.value(forAttribute: Attribute.displayName) as? String
                    ?? entry.name,
                modified: item?.value(forAttribute: Attribute.modified) as? Date,
                lastOpened: item?.value(forAttribute: Attribute.lastUsed) as? Date,
                useCount: (item?.value(forAttribute: Attribute.useCount) as? NSNumber)?.intValue ?? 0,
                whereFrom: (item?.value(forAttribute: Attribute.whereFroms) as? [String])?
                    .joined(separator: " ")
            )
            // A document's own title (PDF metadata) counts as a name.
            if let title = item?.value(forAttribute: Attribute.title) as? String, !title.isEmpty {
                candidate.pdfTitle = title
            }
            candidate.features.nameMatch = max(entry.score,
                                               candidate.pdfTitle.map { Fuzzy.score(words: words, against: $0) } ?? 0)
            candidate.features.retrievalRank = 1 - Double(position) / Double(max(limit, 1))
            kept.append(candidate)
        }
        return kept
    }

    private nonisolated static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "photoslibrary", "xcodeproj", "xcworkspace",
        "rtfd", "playground", "lproj", "docset"
    ]

    private nonisolated static func isInsideBundle(_ url: URL) -> Bool {
        url.pathComponents.contains { component in
            guard let dot = component.lastIndex(of: ".") else { return false }
            return bundleExtensions.contains(String(component[component.index(after: dot)...]).lowercased())
        }
    }
}
