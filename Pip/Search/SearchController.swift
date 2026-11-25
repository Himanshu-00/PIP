import AppKit
import SwiftUI

/// Retrieve, then rerank: cheap Spotlight results on screen at once, the
/// expensive reading and scoring in batches over the survivors only.
@MainActor
final class SearchController: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// Spotlight results are up; the semantic pass is still running.
        case refining
        case done
    }

    @Published private(set) var results: [Candidate] = []
    @Published private(set) var phase: Phase = .idle
    @Published var folder: URL?
    @Published var query = ""
    @Published var selection = 0
    /// Bumped only by the arrow keys; the list scrolls to follow this, never
    /// the hover selection (that made the list run away from the pointer).
    @Published private(set) var keyboardMoves = 0
    /// When something was last typed or selected; keeps the panel open while used.
    private(set) var lastActivity = Date.distantPast

    /// Called on every keystroke and on opening. Also what tells the background
    /// indexer to keep off the disk for a bit — see `ContentIndexer`.
    func noteActivity() {
        lastActivity = .now
        ContentIndexer.lastSearchActivity = lastActivity
    }

    @Published var focusToken = 0

    /// Finding files, or talking to Pip: one panel, two modes.
    enum Mode: Equatable { case files, pet }
    @Published private(set) var mode: Mode = .files

    /// Diagnostics: how many meaning matches, and the closest few.
    private var semanticMatchCount = 0
    private var semanticTop: [String] = []

    /// How many survive to the expensive stage (forty PDFs ≈ 0.2 s).
    private let deepLimit = 40

    private let retriever = Retriever()
    private let extractor = TextExtractor()
    /// One ranker for the panel and for Pip.
    static let sharedRanker = Ranker()
    let ranker = SearchController.sharedRanker

    private var work: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    /// Diagnostics that outlive the panel (opening the menu closes it).
    private struct Snapshot {
        var query = ""
        var folder: URL?
        var retrieved = 0
        var results: [Candidate] = []
        var ranked: [Candidate] = []
        var pooled = 0
        var opened = 0
        var words: [String] = []
        var predicate = ""
        var direct = 0
        var at = Date.distantPast
    }
    private var snapshot = Snapshot()
    private var lastRetrievedCount = 0
    private var directMatchCount = 0
    /// How many candidates came from the content store, for diagnostics. A
    /// number that stays zero after heavy use means the store isn't filling.
    private var storeMatchCount = 0
    private(set) var sweptFiles = 0

    var isOpen: Bool { phase != .idle }

    // MARK: - Lifecycle

    /// Drops the folder scope and searches everywhere, keeping the query.
    func widen() {
        guard folder != nil else { return }
        noteActivity()
        folder = nil
        let text = query
        query = ""
        query = text
        queryChanged()
    }

    func open(in folder: URL?, mode: Mode = .files) {
        self.mode = mode
        self.folder = folder
        query = ""
        results = []
        selection = 0
        phase = .refining
        // Before anything else, so the indexer stands down from the moment the
        // panel appears rather than from the first keystroke.
        noteActivity()
        // Focus immediately.
        focusToken += 1
        // Both modes: Pip's window shows files as you type too.
        loadNames()
    }

    /// The rows Pip's window shows while typing: clear matches only.
    nonisolated static func liveForPip(_ results: [Candidate]) -> [Candidate] {
        results.filter { $0.matchesAll || $0.features.nameMatch >= 0.5 || $0.features.textMatch >= 0.6 }
    }

    /// What Pip's window lists while you type: matching apps first (two at
    /// most), then the files. Nothing once he has answered (typing is then
    /// talking to him) or for text that isn't name-like.
    @MainActor static func pipRows(results: [Candidate], query: String, answered: Bool) -> [URL] {
        let files = liveForPip(results).map(\.url)
        guard !answered, looksLikeName(query) else { return files }
        let apps = InstalledApps.matching(query, limit: 2)
        return apps + files.filter { !apps.contains($0) }
    }

    /// Text that reads like a file name (one to three words, not a question or
    /// request) — only then does typing to Pip show files.
    nonisolated static func looksLikeName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".!,")))
        guard !trimmed.contains("?") else { return false }
        let words = trimmed.lowercased().split(whereSeparator: \.isWhitespace)
        guard (1...3).contains(words.count), let first = words.first else { return false }
        return !talkWords.contains(String(first))
    }

    private nonisolated static let talkWords: Set<String> = [
        "what", "whats", "what's", "how", "why", "when", "where", "who", "which", "whose",
        "can", "could", "would", "should", "will", "is", "are", "was", "do", "does", "did",
        "please", "tell", "show", "find", "open", "play", "pause", "set", "remind", "make", "move",
        "rename", "delete", "summarise", "summarize", "explain", "hey", "hi", "hello", "thanks",
        "thank", "ok", "okay", "yes", "no", "i", "im", "i'm", "you", "let's", "lets",
    ]

    /// Pip was asked: the live search stops, so his model has the machine.
    func stopLive() {
        debounce?.cancel()
        nameLane?.cancel()
        work?.cancel()
        retriever.cancel()
        if !results.isEmpty { results = [] }
    }

    // MARK: - Instant names

    /// Every file the content store knows, by name: matched on each keystroke
    /// before Spotlight has answered. Loaded when the panel opens, dropped
    /// when it closes.
    private var nameList: [(path: String, lower: String)]?
    private var nameListLoad: Task<Void, Never>?
    private var nameLane: Task<Void, Never>?
    /// What the name lane found for which text, to seed that text's pool.
    private var nameHits: (text: String, candidates: [Candidate]) = ("", [])
    /// The text Spotlight has put on screen; the name lane doesn't paint over it.
    private var spotlightText = ""
    /// Last keystroke, and how long after it the first results showed.
    private var typedAt = Date.distantPast
    private var firstPaint: TimeInterval?

    private func loadNames() {
        guard !quick, nameList == nil, nameListLoad == nil else { return }
        nameListLoad = Task { [weak self] in
            let names = await ContentStore.shared.knownNames()
            guard let self, !Task.isCancelled else { return }
            self.nameList = names
            self.nameListLoad = nil
        }
    }

    private func dropNames() {
        nameLane?.cancel()
        nameListLoad?.cancel()
        nameListLoad = nil
        nameList = nil
        nameHits = ("", [])
    }

    private func notePaint() {
        if firstPaint == nil, !quick, !results.isEmpty { firstPaint = Date().timeIntervalSince(typedAt) }
    }

    /// Names the app already knows that look like the query, on screen
    /// before Spotlight answers. The full pipeline reorders them later.
    private func showNames(for text: String) async {
        guard let names = nameList else { return }
        let parse = QueryParse(text, timeHint: nil)
        let words = parse.words
        guard !words.isEmpty else { return }
        let found: [(path: String, score: Double)] = await Task.detached(priority: .userInitiated) {
            // A cheap substring test first (33k names), Fuzzy only on those.
            let keys = words.map { String($0.prefix(3)) }
            var scored: [(path: String, score: Double)] = []
            for entry in names where keys.contains(where: { entry.lower.contains($0) }) {
                let score = Fuzzy.score(words: words, against: (entry.path as NSString).lastPathComponent)
                if score >= 0.5 { scored.append((entry.path, score)) }
            }
            return Array(scored.sorted { $0.score > $1.score }.prefix(20))
        }.value
        guard !Task.isCancelled, query == text, spotlightText != text else { return }

        var candidates: [Candidate] = []
        for hit in found where !DirectScan.isExcluded(hit.path) {
            let url = URL(fileURLWithPath: hit.path)
            // Still there? A row can outlive its file.
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey])
            else { continue }
            var candidate = Candidate(url: url, displayName: url.lastPathComponent,
                                      modified: values.contentModificationDate,
                                      lastOpened: values.contentAccessDate, useCount: 0, whereFrom: nil)
            Self.applyCheapFeatures(to: &candidate, words: words, kinds: parse.typeHints)
            candidate.features.retrievalRank = 0.5
            candidates.append(candidate)
        }
        nameHits = (text, candidates)
        guard !candidates.isEmpty else { return }
        ranker.score(&candidates)
        lastRanked = candidates
        results = Array(candidates.prefix(shortlist))
        shown = Set(results.map(\.url))
        selection = 0
        notePaint()
    }

    /// Pip → the full panel, carrying over whatever was typed.
    /// Pip found more than his window shows: the same search in the full
    /// panel, where every result fits and scrolls.
    func showAll(for text: String) {
        guard !text.isEmpty else { return }
        query = text
        if mode == .files { queryChanged() } else { switchToFiles() }
    }

    func switchToFiles() {
        guard mode != .files else { return }
        mode = .files
        noteActivity()
        focusToken += 1
        loadNames()
        queryChanged()
    }

    /// The full panel → Pip, keeping the text so it can be sent to him.
    func switchToPet() {
        guard mode != .pet else { return }
        work?.cancel()
        debounce?.cancel()
        retriever.cancel()
        results = []
        mode = .pet
        noteActivity()
        focusToken += 1
    }

    func close(_ caller: String = #fileID, line: Int = #line) {
        // Which path closed it: "the notch closes by itself" had no trace.
        if isOpen { ActivityLog.write(.search, "search closed by \((caller as NSString).lastPathComponent):\(line)") }
        work?.cancel()
        debounce?.cancel()
        retriever.cancel()
        dropNames()
        let opening = pendingOpenLog
        pendingOpenLog = nil
        Task {
            // The open is logged first, or `abandon` would file this search
            // as a failure a moment before the open recorded it as a success.
            await opening?.value
            await SearchLog.shared.abandon()
            // Free the extractor's memory, keeping a small working set.
            await extractor.trim()
            // Cap the disk store's growth, while the panel closes.
            await ContentStore.shared.prune()
            // Same for meaning: cap the index, and drop the in-memory
            // vectors until the next search wants them.
            await SemanticIndex.shared.prune()
            await SemanticIndex.shared.release()
        }
        lastRanked = []
        phase = .idle
        reach = .folder
        results = []
        query = ""
        // `mode` stays: the panel is still fading out.
    }

    // MARK: - Searching

    /// Typing calls this on every keystroke; the debounce is what stops that
    /// being forty Spotlight queries for one word.
    func queryChanged() {
        noteActivity()
        debounce?.cancel()
        nameLane?.cancel()
        // In pet mode the field is a chat box — nothing is sent to Pip until
        // Return — but it searches as you type, like the panel.
        let text = query
        guard text.count >= 2 else {
            work?.cancel()
            results = []
            return
        }
        typedAt = .now
        firstPaint = nil
        spotlightText = ""
        // Names the app already knows go up after a short pause — they cost
        // a few milliseconds, so they needn't wait for the Spotlight debounce.
        nameLane = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            await showNames(for: text)
        }
        debounce = Task {
            // Debounce: 140 ms fired between the letters of a word.
            try? await Task.sleep(nanoseconds: 240_000_000)
            guard !Task.isCancelled else { return }
            run(text)
        }
    }

    private func run(_ text: String) {
        work?.cancel()
        let searchStarted = Date()
        phase = .refining
        parsed = QueryParse(text, timeHint: timeHint)
        let words = parsed.words
        let scope = folder
        directMatchCount = 0
        storeMatchCount = 0
        semanticMatchCount = 0
        semanticTop = []
        sweptFiles = 0
        reach = .folder
        showsWeak = false
        prunedCount = 0
        lastRanked = []
        pool = []
        shown = []
        kinds = [:]
        aboutWords = [:]
        captionWords = [:]
        // From the words as said (Pip's finder strips "in": "papers data f"
        // read as data). A format ("pdf about …") is a filter, not a kind.
        askedKind = Kinds.asked(in: timeHint ?? text)
        retrieved = false
        // What the name lane already showed for this text stays in the pool
        // and on screen until Spotlight's answer joins it.
        if nameHits.text == text, !nameHits.candidates.isEmpty {
            pool = nameHits.candidates
            shown = Set(results.map(\.url))
        }
        prepareStrictness(for: text)
        // "last month", "yesterday": a filter on when (`applyTimeWindow`).
        timeWindow = parsed.time
        timeHint = nil
        // "oct rent": "oct" is the filter now, not a word the file must contain.

        armPipTimeout()
        retriever.search(text, in: folder) { [weak self] candidates in
            guard let self, self.query == text else { return }
            self.lastRetrievedCount = candidates.count
            self.retrieved = true
            self.spotlightText = text

            // Cheap features first, so something useful is on screen now. This
            // is the difference between a search that feels instant and one
            // that feels like it's thinking.
            var scored = candidates
            for index in scored.indices {
                Self.applyCheapFeatures(to: &scored[index], words: words, kinds: parsed.typeHints)
            }
            // Spotlight's own copy wins (it carries more), but what the name
            // lane found and it didn't stays.
            let found = Set(scored.map(\.url))
            self.pool = scored + self.pool.filter { !found.contains($0.url) }
            self.publish()
            self.notePaint()
            self.selection = 0
            self.recordImpression()
            let retrievedAt = Date()

            self.work = Task {
                // Per-stage timings, logged as one line when the search ends —
                // so "search is slow" points at a stage, not a guess.
                var stages: [String] = [String(format: "retrieve %.0fms", retrievedAt.timeIntervalSince(searchStarted) * 1000)]
                // From the last keystroke to the first rows on screen.
                if let paint = self.firstPaint { stages.insert(String(format: "first paint %.0fms", paint * 1000), at: 0) }
                var clock = Date()
                func mark(_ name: String) {
                    stages.append(String(format: "%@ %.0fms", name, Date().timeIntervalSince(clock) * 1000))
                    clock = Date()
                }
                // Already-read documents first: one SQLite query, ~1 ms.
                await self.addStoreMatches(words: words, query: text)
                guard !Task.isCancelled, self.query == text else { return }
                mark("index")


                // Then by meaning: a few milliseconds of dot products.
                await self.addSemanticMatches(query: text)
                guard !Task.isCancelled, self.query == text else { return }
                mark("meaning")

                // Typos in words no file holds: the index's own closest word.
                if let fixed = await self.corrected(words) {
                    ActivityLog.write(.search, "corrected \"\(words.joined(separator: " "))\" → \"\(fixed.joined(separator: " "))\"")
                    await self.addStoreMatches(words: fixed, query: text)
                    guard !Task.isCancelled, self.query == text else { return }
                    await self.addSemanticMatches(query: fixed.joined(separator: " "), as: text)
                    guard !Task.isCancelled, self.query == text else { return }
                }

                // What Pip says each file is, so "papers" finds all his papers.
                await self.addKindGroup(query: text)
                guard !Task.isCancelled, self.query == text else { return }
                await self.loadKinds()
                guard !Task.isCancelled, self.query == text else { return }
                self.publish()
                mark("kinds")

                await self.addPhotoMatches(query: text)
                guard !Task.isCancelled, self.query == text else { return }
                mark("looks")

                // Walk the folders (Spotlight's index has holes), unless the names are
                // already found (`strongNameResults`).
                if self.strongNameResults < self.thinResults {
                    await self.addDirectMatches(words: words, in: scope, query: text)
                }
                guard !Task.isCancelled, self.query == text else { return }
                mark("names")

                // The query says when: read that period's unread files now.
                if self.timeWindow != nil {
                    let read = await self.readTimeWindow(words: words, query: text)
                    guard !Task.isCancelled, self.query == text else { return }
                    mark("period read \(read)")
                }

                // (Files containing every word now come from the retriever's
                // all-words query, marked `matchesAll` — no separate lookup.)
                await self.refine(query: text)
                guard !Task.isCancelled, self.query == text else { return }

                // Read files only once typing stops; Pip's searches and typing to Pip skip it.
                let reads = !self.quick && self.mode == .files
                if reads {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                }
                guard !Task.isCancelled, self.query == text else { return }
                // Pip skips the slow rungs: the background indexer has read
                // the common folders, and Pip's brain judges the list anyway.
                if reads {
                    await self.escalate(words: words, query: text)
                    guard !Task.isCancelled, self.query == text else { return }
                    mark("read")
                }
                let top = self.results.prefix(3).map(\.displayName).joined(separator: " · ")
                let strict = self.pool.filter(\.matchesAll).count
                if let window = self.timeWindow { stages.append("time: \(window.label)") }
                stages.append(self.parsed.description)
                ActivityLog.write(.search, String(format: "%@\"%@\" in %.2fs — %@ — top: %@ (%ld contain every word)",
                                                  self.quick ? "Pip " : "", text, Date().timeIntervalSince(searchStarted),
                                                  stages.joined(separator: ", "), top, strict))
                self.endPipSearch()
            }
        }
    }

    /// The index's word evidence, 0…1: every word in order is 1; every word
    /// somewhere is 0.85 plus the BM25 score (a flat 0.85 tied everything).
    private static func indexEvidence(_ hit: ContentStore.Hit, _ score: Double) -> Double {
        hit.phrase ? 1 : hit.allWords ? 0.85 + 0.14 * score : score
    }

    private func addStoreMatches(words: [String], query text: String) async {
        // `words` hold no kind or time words (`QueryParse`). Ask for more hits
        // when a time or "pictures" filter will discard most of them.
        var hits = await ContentStore.shared.search(words: words,
                                                    limit: timeWindow == nil && !wantsPictures ? 60 : 500)
        // A format was asked for ("pdf about transformers"): the best of that
        // format too, or other formats fill the limit first.
        if !parsed.extensions.isEmpty, !wantsPictures {
            let seen = Set(hits.map(\.url))
            hits += await ContentStore.shared.search(words: words, limit: 60, extensions: parsed.extensions)
                .filter { !seen.contains($0.url) }
        }
        guard !Task.isCancelled, query == text else { return }
        // Indexed files the search didn't return don't contain the words: a
        // measured zero, not unread.
        let hitPaths = Set(hits.map(\.url.path))
        let unmeasured = pool.filter { !$0.features.textWasMeasured && !hitPaths.contains($0.url.path) }
        if !unmeasured.isEmpty {
            let held = await ContentStore.shared.currentPaths(unmeasured.map { ($0.url.path, $0.modified) })
            guard !Task.isCancelled, query == text else { return }
            for index in pool.indices where held.contains(pool[index].url.path) {
                pool[index].features.textWasMeasured = true
            }
        }
        guard !hits.isEmpty else { publish(); return }

        let known = Set(pool.map(\.url))
        // Its own normalisation, not ours — FTS5's scores are on a different
        // scale entirely. See `normaliseExternal`.
        let scaled = BM25.normaliseExternal(hits.map(\.score))

        // Already in the list (found by name or Spotlight): the store's word
        // match still counts — it's what tells the paper from attention.py.
        for (hit, score) in zip(hits, scaled) where known.contains(hit.url) {
            guard let index = pool.firstIndex(where: { $0.url == hit.url }) else { continue }
            let evidence = Self.indexEvidence(hit, score)
            pool[index].indexedTextMatch = max(pool[index].indexedTextMatch, evidence)
            pool[index].features.textMatch = max(pool[index].features.textMatch, evidence)
            pool[index].features.textWasMeasured = true
            if hit.allWords { pool[index].matchesAll = true }
            if hit.near { pool[index].wordsNear = true }
            if pool[index].pdfTitle == nil, let title = hit.title { pool[index].pdfTitle = title }
        }

        for (hit, score) in zip(hits, scaled) where !known.contains(hit.url) {
            guard var candidate = await storedCandidate(for: hit.url, words: words, query: text)
            else { continue }
            let evidence = Self.indexEvidence(hit, score)
            candidate.features.textMatch = evidence
            candidate.indexedTextMatch = evidence
            candidate.matchesAll = hit.allWords
            candidate.wordsNear = hit.near
            // FTS5 scored this against text we hold, so the number means
            // something — unlike a zero on a file nobody opened.
            candidate.features.textWasMeasured = true
            candidate.pdfTitle = hit.title
            if let title = hit.title {
                candidate.features.nameMatch = max(candidate.features.nameMatch,
                                                   Fuzzy.score(words: words, against: title))
            }
            // Above the folder walk's 0.5: found by its contents.
            candidate.features.retrievalRank = 0.65
            pool.append(candidate)
        }
        storeMatchCount = hits.count
        publish()
    }

    /// A candidate for a store or semantic hit, if the file still exists.
    private func storedCandidate(for url: URL, words: [String], query text: String) async -> Candidate? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                       .contentAccessDateKey])
        guard let values else {
            await ContentStore.shared.forget(path: url.path)
            return nil
        }
        var candidate = Candidate(
            url: url,
            displayName: url.lastPathComponent,
            modified: values.contentModificationDate,
            lastOpened: values.contentAccessDate,
            useCount: 0,
            whereFrom: nil)
        Self.applyCheapFeatures(to: &candidate, words: words, kinds: parsed.typeHints)
        return candidate
    }

    // MARK: - Strict matching

    /// The words a result must contain, for the query being shown.
    private var strictWords: [String] = []
    /// The kinds asked for ("pdf", "slides" → extensions); empty = any.
    private var wantedKinds: Set<String> = []
    /// This search, read once (`QueryParse`).
    private var parsed = QueryParse("")
    /// Coverage already worked out, keyed by file and how much text was known.
    private var coverage: [String: Bool] = [:]

    private func prepareStrictness(for text: String) {
        wantedKinds = parsed.extensions
        strictWords = parsed.required
        coverage = [:]
        let typed = Set(Tokens.of(text))
        wantsCode = !typed.isDisjoint(with: Self.codeWords) || !typed.isDisjoint(with: DirectScan.codeKinds)
        wantsPictures = parsed.wantsPictures
    }

    // MARK: - Time

    /// When the query says when ("last month", "oct"), or nil.
    private var timeWindow: QueryTime.Window?
    /// Set by `find` just before a run: Pip's whole request, for its time phrase.
    private var timeHint: String?
    /// Creation dates looked up so far — a stat each, so not repeated.
    private var createdDates: [URL: Date] = [:]

    private func inWindow(_ candidate: Candidate, _ window: QueryTime.Window) -> Bool {
        let created: Date?
        if let known = createdDates[candidate.url] {
            created = known
        } else {
            created = (try? candidate.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let created { createdDates[candidate.url] = created }
            if createdDates.count > 5_000 { createdDates.removeAll() }
        }
        return window.contains(modified: candidate.modified, created: created, name: candidate.displayName)
    }

    /// Indexing on demand for one period: reads the not-yet-indexed files from
    /// that time (and kind), newest first, then searches the index again.
    @discardableResult
    private func readTimeWindow(words: [String], query text: String) async -> Int {
        guard let window = timeWindow else { return 0 }
        var roots = DirectScan.commonFolders
        if let folder, !roots.contains(folder) { roots.insert(folder, at: 0) }
        let inventory = await DirectScan.inventory(of: roots, kinds: DirectScan.readableKinds, within: 1.5)
        guard !Task.isCancelled, query == text else { return 0 }
        let inPeriod = inventory.filter { inWindow($0, window) && (wantedKinds.isEmpty || kindFits($0)) }
        guard !inPeriod.isEmpty else { return 0 }
        let indexed = await ContentStore.shared.currentPaths(inPeriod.map { (path: $0.url.path, modified: $0.modified) })
        guard !Task.isCancelled, query == text else { return 0 }
        let unread = inPeriod.filter { !indexed.contains($0.url.path) }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        guard !unread.isEmpty else { return 0 }

        let limit = min(unread.count, 200)
        let deadline = Date().addingTimeInterval(quick ? 3 : 4)
        var read = 0
        for start in stride(from: 0, to: limit, by: 16) {
            guard Date() < deadline, !Task.isCancelled, query == text else { break }
            let slice = Array(unread[start ..< min(start + 16, limit)])
            _ = await extractor.texts(for: slice)
            read += slice.count
        }
        guard read > 0, !Task.isCancelled, query == text else { return read }
        // What was just read is in the index now.
        await addStoreMatches(words: words, query: text)
        return read
    }

    /// Drops files outside the query's time window, unless none are inside it.
    private func applyTimeWindow() {
        guard let window = timeWindow, !pool.isEmpty else { return }
        let kept = pool.filter { inWindow($0, window) }
        if !kept.isEmpty, kept.count < pool.count { pool = kept }
    }

    // MARK: - Kinds and copies

    private var wantsCode = false
    private static let codeWords: Set<String> = [
        "code", "script", "scripts", "source", "function", "python", "javascript",
        "repo", "program", "notebook", "module", "implementation",
    ]
    /// "my pic in yellow suit": only pictures, when any picture matched.
    private var wantsPictures = false

    /// Code below documents unless code was asked for.
    private func applyKindPreference() {
        guard !wantsCode else { return }
        for index in pool.indices where DirectScan.codeKinds.contains(pool[index].url.pathExtension.lowercased()) {
            pool[index].score -= 0.6
        }
        pool.sort { $0.score > $1.score }
    }

    /// One row per file, not per copy ("Report.pdf" and "Report (1).pdf", same size).
    private static func withoutCopies(_ ranked: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return ranked.filter { candidate in
            guard let key = copyKey(candidate.url) else { return true }
            return seen.insert(key).inserted
        }
    }

    nonisolated static func copyKey(_ url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            .replacingOccurrences(of: #"( \(\d+\)| copy( \d+)?)$"#, with: "", options: .regularExpression)
        return "\(stem).\(url.pathExtension.lowercased())#\(size)"
    }

    /// For two or more words, files holding all of them (and of the kind asked
    /// for) come first; if none does, the order stays.
    private func applyStrictness() {
        // One word: a file named with it comes first.
        if parsed.words.count == 1, let word = parsed.words.first {
            for index in pool.indices
            where Tokens.of(pool[index].url.deletingPathExtension().lastPathComponent).contains(word) {
                pool[index].score += 1
            }
            pool.sort { $0.score > $1.score }
            return
        }
        guard strictWords.count >= 2 else { return }
        var anyFull = false
        for index in pool.indices {
            if !pool[index].matchesAll { pool[index].matchesAll = covers(pool[index]) }
            if pool[index].matchesAll, kindFits(pool[index]) { anyFull = true }
        }
        guard anyFull else { return }
        let wantsImages = !wantedKinds.isEmpty
            && wantedKinds.allSatisfy { ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"].contains($0) }
        // Asked for pictures, a photo that clearly looks like it counts too —
        // once some file holds every word: with a typo none does, and the
        // order stays the ranker's.
        for index in pool.indices
        where (pool[index].matchesAll || (wantsPictures && pool[index].looks > 0)) && kindFits(pool[index]) {
            var lift = 100.0
            // Spotlight says every word is in it but our index saw none: buried in
            // something huge. Half the lift.
            let features = pool[index].features
            if features.textWasMeasured, features.textMatch == 0, features.nameMatch < 0.3,
               pool[index].looks == 0 { lift = 50 }
            // Within the strict set: a file whose *name or title* holds every
            // word is what the query names ("Attention Is All You Need") —
            // above one that merely mentions the words in its text.
            // Pip's kind counts as a name: "Pay Date 2025-03-31.pdf" is a "pay statement".
            let label = Set(Tokens.of(pool[index].displayName + " " + (pool[index].pdfTitle ?? "") + " "
                                      + (kinds[pool[index].url.path] ?? "")))
            if strictWords.allSatisfy({ word in label.contains { $0 == word || $0.hasPrefix(word) } }) {
                lift += 20
            }
            // Every word close together — a caption or a sentence about them —
            // over a big file where each turns up somewhere.
            // Not when pictures were asked for: then how a photo looks
            // decides between ones whose captions all say the words (the
            // best photo of a black suit isn't the one whose caption lists
            // "black, suit" side by side).
            if pool[index].wordsNear, !wantsPictures { lift += 10 }
            if wantsPictures, pool[index].isImage { lift += 10 * pool[index].looks }
            // "My pic": a photo of you is never a screenshot (a GitHub page
            // captioned "dark mode, gray" isn't you in a dark gray suit).
            if parsed.me, isScreenshot(pool[index]) { lift -= 20 }
            // A screenshot showing the words goes below documents, unless
            // images were asked for — not a photo whose caption says them.
            if pool[index].isImage, !wantsImages, !pool[index].wordsNear { lift -= 10 }
            pool[index].score += lift
        }
        pool.sort { $0.score > $1.score }
    }

    /// "latest": newest first among close matches; code keeps its place.
    private func applyLatest() {
        guard parsed.latest, let best = pool.first?.score, best > 0 else { return }
        let slots = pool.indices.filter {
            pool[$0].score >= best * 0.5 && !DirectScan.codeKinds.contains(pool[$0].url.pathExtension.lowercased())
        }
        guard slots.count > 1 else { return }
        let newestFirst = slots.map { pool[$0] }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        for (slot, candidate) in zip(slots, newestFirst) { pool[slot] = candidate }
    }

    private func kindFits(_ candidate: Candidate) -> Bool {
        wantedKinds.isEmpty || wantedKinds.contains(candidate.url.pathExtension.lowercased())
    }

    /// Every required word appears as a word (or the start of one) in the
    /// file's name, title, or the text we've read of it.
    private func covers(_ candidate: Candidate) -> Bool {
        let key = candidate.url.path + "#\(candidate.text?.count ?? -1)"
        if let known = coverage[key] { return known }
        let haystack = Set(Tokens.of(candidate.displayName + " " + (candidate.pdfTitle ?? "") + " "
                                     + (candidate.text ?? "")))
        let all = strictWords.allSatisfy { word in
            haystack.contains(word) || haystack.contains { $0.hasPrefix(word) }
                || Tokens.plainForm(word).map(haystack.contains) == true
                || Tokens.otherSpelling(word).map(haystack.contains) == true
        }
        coverage[key] = all
        return all
    }

    /// Sets `matchesAll` from a file's full text, while it's in hand.
    private func markCoverage(_ candidate: inout Candidate, fullText: String) {
        guard strictWords.count >= 2, !candidate.matchesAll else { return }
        let haystack = Set(Tokens.of(candidate.displayName + " " + (candidate.pdfTitle ?? "") + " " + fullText))
        candidate.matchesAll = strictWords.allSatisfy { word in
            haystack.contains(word) || haystack.contains { $0.hasPrefix(word) }
                || Tokens.plainForm(word).map(haystack.contains) == true
                || Tokens.otherSpelling(word).map(haystack.contains) == true
        }
    }

    // MARK: - Meaning

    /// Similarity below which a passage isn't considered related at all.
    private static let meaningFloor = 0.45
    /// How far behind the closest match another can be and still count.
    private static let meaningSpread = 0.15

    /// Cosine similarity as 0…1 text evidence, capped at 0.8 so meaning never
    /// outranks a literal match on its own.
    private static func meaningScore(_ similarity: Double) -> Double {
        min(max((similarity - 0.35) / 0.45, 0), 1) * 0.8
    }

    /// Two words or more, and not a file name.
    private static func wantsMeaning(_ text: String) -> Bool {
        guard Tokens.query(text).count >= 2 else { return false }
        return text.range(of: #"\.[A-Za-z0-9]{2,4}\b"#, options: .regularExpression) == nil
    }

    /// Adds documents about the query, whatever their words. Additive only.
    /// `as`: the search on screen, when `text` is a corrected form of it.
    private func addSemanticMatches(query text: String, as shown: String? = nil) async {
        guard Self.wantsMeaning(text) else { return }
        let matches = await SemanticIndex.shared.search(Tokens.expandText(text), limit: 30)
        guard !Task.isCancelled, query == (shown ?? text), let best = matches.first else { return }

        semanticTop = matches.prefix(3).map {
            "\($0.url.lastPathComponent) \(String(format: "%.2f", $0.similarity))"
        }
        let floor = max(Self.meaningFloor, best.similarity - Self.meaningSpread)
        let words = parsed.words
        var contributed = 0

        for match in matches where match.similarity >= floor {
            let score = Self.meaningScore(match.similarity)
            guard score > 0 else { continue }

            if let index = pool.firstIndex(where: { $0.url == match.url }) {
                pool[index].features.semanticMatch = max(pool[index].features.semanticMatch, score)
                pool[index].features.textWasMeasured = true
                contributed += 1
                continue
            }

            guard var candidate = await storedCandidate(for: match.url, words: words, query: shown ?? text)
            else { continue }
            candidate.features.semanticMatch = score
            candidate.features.textWasMeasured = true
            // Between the folder walk and the store: retrieved for what it's
            // about, which is real evidence but looser than containing the
            // words.
            candidate.features.retrievalRank = 0.6
            candidate.text = String(match.passage.prefix(300))
            pool.append(candidate)
            contributed += 1
        }
        semanticMatchCount = contributed
        if contributed > 0 { publish() }
    }

    // MARK: - Looks

    /// Spotlight has answered this search.
    private var retrieved = false

    /// Similarity below which a photo doesn't show what was asked (MobileCLIP
    /// S2: a clear match is 0.27–0.40; the best photo for "soa" is 0.21).
    private static let looksFloor: Float = 0.25
    /// How far behind the closest photo another can be and still count.
    private static let looksSpread: Float = 0.05

    /// Adds photos that look like the query. Asked for pictures, a clear match
    /// counts as holding every word; otherwise only clear ones, on score alone.
    private func addPhotoMatches(query text: String) async {
        let imageKinds: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp"]
        guard !parsed.phrase.isEmpty, wantsPictures || !wantsCode,
              wantedKinds.isSubset(of: imageKinds),
              text.range(of: #"\.[A-Za-z0-9]{2,4}\b"#, options: .regularExpression) == nil else { return }
        // Captions already matched pictures: how each one looks orders them
        // (forty photos captioned "yellow kurta" tie on words).
        let captioned = pool.contains { $0.isImage && $0.matchesAll }
        let matches = await PhotoVectors.shared.search(parsed.phrase, limit: wantsPictures || captioned ? 60 : 12)
        guard !Task.isCancelled, query == text, let best = matches.first else { return }
        let floor = max(Self.looksFloor, best.similarity - Self.looksSpread)
        let words = parsed.words
        var contributed = 0
        for match in matches {
            let clear = match.similarity >= floor
            // 0.25 → 0.4, 0.32 and up → 0.8: the same footing, and the same
            // cap, as meaning (`meaningScore`).
            let score = Double(min(max((match.similarity - 0.18) / 0.14, 0), 1)) * 0.8
            var index = pool.firstIndex { $0.url == match.url }
            // Not clear and not asked for pictures: only to order the ones already found.
            guard clear || wantsPictures || index != nil else { continue }
            if index == nil, let candidate = await storedCandidate(for: match.url, words: words, query: text) {
                pool.append(candidate)
                index = pool.count - 1
                pool[pool.count - 1].features.retrievalRank = 0.6
            }
            guard let index else { continue }
            pool[index].features.semanticMatch = max(pool[index].features.semanticMatch, score)
            pool[index].features.textWasMeasured = true
            if clear { pool[index].looks = score }
            contributed += 1
        }
        if contributed > 0 { publish() }
    }

    /// Adds file-name matches found by walking the disk (union with Spotlight).
    private func addDirectMatches(words: [String], in folder: URL?,
                                  query text: String) async {
        // The common folders are always walked, scope or no scope (~60 ms).
        var places = DirectScan.commonFolders
        if let folder, !places.contains(folder) { places.insert(folder, at: 0) }
        let scanned = await DirectScan.matches(words: words, in: places)
        guard !Task.isCancelled, query == text, !scanned.isEmpty else { return }

        directMatchCount = scanned.count
        let known = Set(pool.map(\.url))

        for var candidate in scanned where !known.contains(candidate.url) {
            Self.applyCheapFeatures(to: &candidate, words: words, kinds: parsed.typeHints)
            // Spotlight didn't return it, so it has no retrieval rank of its
            // own. Middling rather than zero: being absent from the index says
            // nothing about whether it's the right file.
            candidate.features.retrievalRank = 0.5
            pool.append(candidate)
        }
        publish()
    }

    /// The expensive half, in batches, updating the list between them.
    private func refine(query text: String) async {
        let candidates = deepSet()
        guard !candidates.isEmpty else { phase = .done; groupResults(); return }

        // Eight at a time. Small enough that the first reorder lands within a
        // couple of hundred milliseconds, large enough that the batching
        // overhead stays invisible.
        let batchSize = 8
        var working = candidates
        var readSoFar: [URL: TextExtractor.Extracted] = [:]
        let words = parsed.words

        for start in stride(from: 0, to: working.count, by: batchSize) {
            guard !Task.isCancelled, query == text else { return }
            let slice = Array(working[start..<min(start + batchSize, working.count)])

            let extracted = await extractor.texts(for: slice)
            guard !Task.isCancelled, query == text else { return }
            readSoFar.merge(extracted) { _, new in new }

            for index in working.indices {
                guard let found = extracted[working[index].url] else { continue }
                // Only a preview is kept on the candidate; the full text has
                // already done its job in the scorer below.
                working[index].text = String(found.text.prefix(300))
                // "Contains every word" is decided on everything read, not
                // the 300-character preview kept above.
                markCoverage(&working[index], fullText: found.text)

                // A PDF's own title competes with the file name (finds `1706.03762.pdf`).
                if let title = found.title {
                    working[index].features.nameMatch = max(working[index].features.nameMatch,
                                                            Fuzzy.score(words: words, against: title))
                    working[index].pdfTitle = title
                }
            }

            // Lexical relevance over everything read so far.
            Self.applyBM25(&working, query: text, texts: readSoFar)

            guard !Task.isCancelled, query == text else { return }
            absorb(working)
            publish()
        }

        phase = .done
        recordImpression()
        groupResults()
    }

    /// Group names by the index of their first row in `results` (the panel
    /// shows each above that row). Empty when the list isn't grouped.
    @Published private(set) var groupHeaders: [Int: String] = [:]
    /// Pip's descriptions of the files on screen, for their second line.
    @Published private(set) var abouts: [URL: String] = [:]
    private var groupWork: Task<Void, Never>?
    private var regroupWork: Task<Void, Never>?

    /// Once a search has settled: every result (weak ones too) grouped by what
    /// the files are (`ResultGroups`), and the files on screen queued for Pip
    /// to describe when the Mac is idle.
    private func groupResults(describe: Bool = true) {
        guard !quick, !lastRanked.isEmpty else { return }
        let text = query
        let ranked = lastRanked
        let urls = ranked.map(\.url)
        // Undescribed results described now; each one regroups, a moment later.
        if describe {
            DocumentNotes.shared.describeNow(urls.map(\.path), limit: 8) { [weak self] _ in
                guard let self, self.query == text else { return }
                self.regroupWork?.cancel()
                self.regroupWork = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard let self, !Task.isCancelled, self.query == text else { return }
                    self.groupResults(describe: false)
                }
            }
        }
        // Grouped: only the results shown — the cut where good answers end stays.
        let shown = results
        groupWork?.cancel()
        groupWork = Task { [weak self] in
            let notes = await ContentStore.shared.notes(for: urls.map(\.path))
            let groups = await ResultGroups.group(shown.map(\.url), query: text)
            guard let self, !Task.isCancelled, self.query == text else { return }
            self.abouts = Dictionary(uniqueKeysWithValues: urls.compactMap { url in notes[url.path]?.about.map { (url, $0) } })
            guard let groups else { return }
            var ordered: [Candidate] = []
            var headers: [Int: String] = [:]
            for group in groups {
                headers[ordered.count] = group.name
                ordered += group.urls.compactMap { url in shown.first { $0.url == url } }
            }
            let selected = self.results.indices.contains(self.selection) ? self.results[self.selection].url : nil
            self.groupHeaders = headers
            self.results = ordered
            self.selection = selected.flatMap { url in ordered.firstIndex { $0.url == url } } ?? 0
            ActivityLog.write(.search, "grouped \"\(text)\": " + groups.map { "\($0.name) (\($0.urls.count))" }.joined(separator: ", "))
        }
    }

    /// Everything retrieval found, scored (`results` is the pruned five).
    private var pool: [Candidate] = []

    /// Re-ranks the pool and publishes it.
    private func publish() {
        // Whatever found them (index rows from before a folder was marked
        // never-index, meaning, photo vectors): excluded paths never show.
        pool.removeAll { DirectScan.isExcluded($0.url.path) }
        // "on my desktop": that folder (and below), when anything is there —
        // a wrong guess about where a file lives shouldn't hide it.
        if let folder = parsed.folder {
            let root = NSHomeDirectory() + "/" + folder + "/"
            if pool.contains(where: { $0.url.path.hasPrefix(root) }) { pool.removeAll { !$0.url.path.hasPrefix(root) } }
        }
        applyTimeWindow()
        // A format typed outright ("pdf about transformers"): only that
        // format, when any file of it matched.
        if !parsed.extensions.isEmpty, !wantsPictures,
           pool.contains(where: { parsed.extensions.contains($0.url.pathExtension.lowercased()) }) {
            pool.removeAll { !parsed.extensions.contains($0.url.pathExtension.lowercased()) }
        }
        ranker.score(&pool)
        // Incumbency before the strict lift, or it outweighs every feature.
        applyIncumbency(&pool)
        applyDescribedKind()
        applyStrictness()
        applyKindPreference()
        applyLatest()
        let pictures = wantsPictures ? pool.filter(\.isImage) : []
        lastRanked = Array(Self.withoutCopies(Array((pictures.isEmpty ? pool : pictures).prefix(40))).prefix(30))
        if !groupHeaders.isEmpty { groupHeaders = [:] }
        results = prune(lastRanked)
        shown = Set(results.map(\.url))
        takeSnapshot()
    }

    /// Which documents to open and read: half the budget to the best-ranked,
    /// half to ones with no name match (before reading, rank is mostly name).
    private func deepSet() -> [Candidate] {
        let byScore = pool.prefix(deepLimit / 2)
        let contentOnly = pool
            .filter { $0.features.nameMatch < 0.2 }
            .sorted { left, right in
                // Retrieval rank, then recency: the tiebreak matters when ranks are flat.
                if left.features.retrievalRank != right.features.retrievalRank {
                    return left.features.retrievalRank > right.features.retrievalRank
                }
                return (left.modified ?? .distantPast) > (right.modified ?? .distantPast)
            }
            .prefix(deepLimit / 2)

        var chosen: [Candidate] = []
        var seen: Set<URL> = []
        for candidate in Array(byScore) + Array(contentOnly) where !seen.contains(candidate.url) {
            seen.insert(candidate.url)
            chosen.append(candidate)
        }
        return chosen
    }

    /// Writes what a deep pass learned back into the pool.
    private func absorb(_ updated: [Candidate]) {
        var byURL: [URL: Candidate] = [:]
        for candidate in updated { byURL[candidate.url] = candidate }
        for index in pool.indices {
            guard let fresh = byURL[pool[index].url] else { continue }
            pool[index] = fresh
        }
        // Anything the pass discovered that wasn't in the pool — the sweep
        // finds files nothing retrieved.
        let known = Set(pool.map(\.url))
        pool += updated.filter { !known.contains($0.url) }
    }

    // MARK: - Keeping only the close ones

    /// Rows shown, not found; the rest are a keystroke away.
    private let shortlist = 5
    /// How far a list of equally good results may grow past `shortlist`.
    nonisolated static let extendedShortlist = 12

    /// Set when the user asks to see the ones that were cut.
    @Published var showsWeak = false
    @Published private(set) var prunedCount = 0

    /// Cuts the list where the answers end: under 45% of the best, or at the
    /// biggest drop; never fewer than three.
    private func prune(_ candidates: [Candidate]) -> [Candidate] {
        let ranked = Array(candidates.prefix(30))
        guard ranked.count > 3, let best = ranked.first?.score, best > 0 else {
            prunedCount = 0
            return ranked
        }

        var cut = min(ranked.count, shortlist)

        // A near-exact name raises the bar for the rest; a weak field keeps it low.
        let confidence = ranked.first?.features.nameMatch ?? 0
        let floor = confidence >= 0.9 ? 0.72
                  : confidence >= 0.7 ? 0.58
                  : 0.45

        if let weak = ranked.firstIndex(where: { $0.score < best * floor }) {
            cut = min(cut, weak)
        }

        // A cliff only if the next result is under two thirds of this one.
        var cliff = cut
        var steepest = 0.0
        // `cut` can be under 2; a reversed range would trap.
        let upper = min(cut, ranked.count - 1)
        for index in 2..<max(upper, 2) where upper > 2 {
            let current = ranked[index].score
            let next = ranked[index + 1].score
            guard current > 0, next < current * 0.66 else { continue }
            let drop = (current - next) / current
            if drop > steepest {
                steepest = drop
                cliff = index + 1
            }
        }
        cut = min(cut, cliff)

        cut = max(cut, min(2, ranked.count))

        // More than five when they stay within 80% of the best, up to twelve.
        if cut == min(ranked.count, shortlist) {
            let extended = min(ranked.count, Self.extendedShortlist)
            while cut < extended, ranked[cut].score >= best * 0.8 { cut += 1 }
        }
        prunedCount = ranked.count - cut
        return showsWeak ? ranked : Array(ranked.prefix(cut))
    }

    /// Reveals what was cut, without re-running anything.
    func revealWeaker() {
        guard prunedCount > 0, !showsWeak else { return }
        noteActivity()
        showsWeak = true
        results = lastRanked
        selection = min(selection, max(results.count - 1, 0))
    }

    /// The full ranked set behind whatever is on screen, so revealing the
    /// weaker ones is instant rather than another pass over everything.
    private var lastRanked: [Candidate] = []

    /// What's currently on screen, for incumbency.
    private var shown: Set<URL> = []

    /// The kind each file is filed under in the store ("research paper",
    /// `Kinds`); "" when it isn't filed yet. Looked up once per file.
    private var kinds: [String: String] = [:]
    /// The words of Pip's description, for what a file is about.
    private var aboutWords: [String: Set<String>] = [:]
    /// The words of a picture's caption — what it shows, not text in it.
    private var captionWords: [String: Set<String>] = [:]
    /// The kind the query asks for ("can you list all research papers" →
    /// "research paper"); nil when it names none.
    private var askedKind: String?

    /// The group asked for, straight from the store: every file filed under
    /// that kind or another kind of the same thing ("exam paper" for
    /// "research papers"), whatever their names and however often their
    /// text says the words.
    private func addKindGroup(query text: String) async {
        guard let wanted = askedKind else { return }
        let group = await ContentStore.shared.documents(ofKind: Kinds.head(wanted))
        guard !Task.isCancelled, query == text, !group.isEmpty else { return }
        let known = Set(pool.map(\.url.path))
        for (path, kind) in group {
            kinds[path] = kind
            guard !known.contains(path) else { continue }
            let url = URL(fileURLWithPath: path)
            if !parsed.extensions.isEmpty, !parsed.extensions.contains(url.pathExtension.lowercased()) { continue }
            guard var candidate = await storedCandidate(for: url, words: parsed.words, query: text) else { continue }
            guard !Task.isCancelled, query == text else { return }
            candidate.features.retrievalRank = 0.65
            pool.append(candidate)
        }
    }

    /// Words no file holds, replaced by the closest word the index does
    /// ("retentve netwrk" → "retentive network"); nil when nothing changed.
    private func corrected(_ words: [String]) async -> [String]? {
        var changed = false
        var out: [String] = []
        for word in words {
            if let fix = await ContentStore.shared.correction(for: word) {
                out.append(Tokens.stem(fix)); changed = true
            } else {
                out.append(word)
            }
        }
        return changed ? out : nil
    }

    /// Kinds, descriptions and captions for the best of the pool.
    private func loadKinds() async {
        let paths = pool.prefix(150).map(\.url.path).filter { aboutWords[$0] == nil && captionWords[$0] == nil }
        guard !paths.isEmpty else { return }
        let notes = await ContentStore.shared.notes(for: paths)
        for path in paths {
            let note = notes[path]
            if kinds[path] == nil { kinds[path] = note?.kind ?? "" }
            aboutWords[path] = note?.about.map { Set(Tokens.of($0)) } ?? []
            if let caption = note?.caption { captionWords[path] = Set(Tokens.of(caption)) }
        }
    }

    /// How a file's kind answers the search (`Kinds.match`): 2, 1, 0 or nil.
    private func kindMatch(_ url: URL) -> Int? {
        guard let wanted = askedKind else { return nil }
        return Kinds.match(kinds[url.path], asked: wanted)
    }

    /// A screen capture: named so by macOS, or captioned as one.
    private func isScreenshot(_ candidate: Candidate) -> Bool {
        guard candidate.isImage else { return false }
        let name = candidate.displayName.lowercased()
        return name.hasPrefix("screenshot") || name.hasPrefix("screen shot") || name.hasPrefix("cleanshot")
            || captionWords[candidate.url.path]?.contains("screenshot") == true
    }

    /// Could be the kind asked for: filed under it, or a picture whose
    /// caption says it (a photographed receipt) — not a screenshot that
    /// merely shows the words "research paper", nor code. True when no kind
    /// was asked, or for a document not filed yet.
    func fitsAskedKind(_ url: URL) -> Bool {
        guard let wanted = askedKind else { return true }
        if let match = kindMatch(url) { return match > 0 }
        if DirectScan.codeKinds.contains(url.pathExtension.lowercased()) { return wantsCode }
        guard Candidate.imageKinds.contains(url.pathExtension.lowercased()) else { return true }
        let head = Kinds.head(wanted)
        return captionWords[url.path]?.contains { Tokens.stem($0) == head || $0.hasPrefix(head) } ?? false
    }

    /// Filed under the kind the last search asked for (or the same thing).
    func isAskedKind(_ url: URL) -> Bool { (kindMatch(url) ?? 0) > 0 }

    /// The group first: a file filed under the kind asked for goes up (the
    /// same kind most, "research paper"; then the same thing, "exam
    /// paper"); one filed under another kind, or a screenshot or script
    /// that only holds the words, goes down. And a file whose description
    /// holds the query's other words is about them.
    private func applyDescribedKind() {
        var changed = false
        if askedKind != nil {
            // The group asked for is a tier of its own, above everything that
            // only holds the words: the same kind ("research paper"), or any
            // kind of the thing when only the thing was asked ("papers").
            // Another kind of the same thing ("exam paper" for "research
            // papers") comes after it.
            let bare = !(askedKind ?? "").contains(" ")
            var inGroup = 0
            for index in pool.indices {
                switch kindMatch(pool[index].url) {
                case 2?: pool[index].score += 200; inGroup += 1
                case 1? where bare: pool[index].score += 200; inGroup += 1
                case 1?: pool[index].score += 1.0; inGroup += 1
                default: break
                }
            }
            // The group is there: what isn't in it goes down. Documents not
            // filed yet keep their place.
            if inGroup >= 2 {
                for index in pool.indices where !fitsAskedKind(pool[index].url) {
                    pool[index].score -= 0.8
                }
            }
            changed = inGroup > 0
        }
        // What it's about: the query's other words in Pip's line about the
        // file ("pdf about transformers" → "Attention paper on transformer
        // architecture"; a resume that mentions transformers isn't about them).
        let kindWords = Set(askedKind?.split(separator: " ").map(String.init) ?? [])
        let topic = parsed.words.filter { !kindWords.contains(Tokens.stem($0)) && $0.count >= 3 }
        if !topic.isEmpty {
            for index in pool.indices {
                guard let about = aboutWords[pool[index].url.path], !about.isEmpty else { continue }
                let held = topic.filter { word in
                    about.contains(word) || about.contains { $0.hasPrefix(word) }
                        || Tokens.plainForm(word).map(about.contains) == true
                }.count
                guard held > 0 else { continue }
                pool[index].score += 0.6 * Double(held) / Double(topic.count)
                changed = true
            }
        }
        if changed { pool.sort { $0.score > $1.score } }
    }

    /// 8% bonus for already being visible, so near-ties don't reshuffle.
    private func applyIncumbency(_ candidates: inout [Candidate]) {
        guard !shown.isEmpty else { return }
        for index in candidates.indices where shown.contains(candidates[index].url) {
            candidates[index].score *= 1.08
        }
        candidates.sort { $0.score > $1.score }
    }

    // MARK: - Escalation

    /// What the search is currently prepared to do. Each rung costs more than
    /// the one above it and only runs because that one came back thin.
    enum Reach: Equatable {
        case folder
        /// Reading files Spotlight never indexed, oldest windows last.
        case sweeping(window: String, read: Int)

        var label: String {
            switch self {
            case .folder:   return ""
            case .sweeping(let window, let read):
                return read == 0 ? "searching \(window)"
                                 : "searching \(window) — \(read) files read"
            }
        }
    }

    @Published private(set) var reach: Reach = .folder

    /// Below this, a search is considered to have failed and is worth
    /// escalating. Not zero: two weak matches and the file you wanted still
    /// missing is the same failure as none at all.
    private let thinResults = 5
    /// A result good enough to stop climbing for.
    private let goodEnough = 0.55
    /// How well a name must match to count as an answer (fuzzy 0.6 isn't).
    private let nameIsAnswer = 0.85

    /// Counted over everything ranked, not what survived pruning.
    private var strongResults: Int {
        pool.filter { candidate in
            candidate.features.nameMatch >= nameIsAnswer
                || candidate.features.textMatch >= goodEnough
        }.count
    }

    /// Files whose name answers the query; content matches don't skip the walk.
    private var strongNameResults: Int {
        pool.filter { $0.features.nameMatch >= nameIsAnswer }.count
    }

    /// Climbs the ladder by cost until there's enough; abandoned on each keystroke.
    private func escalate(words: [String], query text: String) async {
        guard strongResults < thinResults else { return }

        // Read the files themselves. Nothing cheaper is left to try: the first
        // pass already walked the common folders as well as the scoped one,
        // and retrieval already scored every name with the fuzzy matcher.
        await sweep(words: words, query: text)
        reach = .folder
    }

    private static let home = URL(fileURLWithPath: NSHomeDirectory())

    /// How long the sweep may spend opening files, across all its windows.
    private static let readBudget: TimeInterval = 2.5

    private static let sweepWindows: [(label: String, days: Double, bar: Double)] = [
        ("the last week",     7,      0.34),
        ("the last month",    31,     0.42),
        ("the last 3 months", 92,     0.50),
        ("the last year",     366,    0.58),
        ("everything older",  .infinity, 0.68),
    ]

    /// Reads file contents, sliding back through time; stops at an answer.
    private func sweep(words: [String], query text: String) async {
        // Common folders, never the whole home directory.
        var roots = DirectScan.commonFolders
        if let folder, !roots.contains(folder) { roots.insert(folder, at: 0) }
        if roots.isEmpty { roots = [folder ?? Self.home] }

        let inventory = await DirectScan.inventory(of: roots,
                                                   kinds: DirectScan.readableKinds,
                                                   within: DirectScan.sweepBudget)
        guard !Task.isCancelled, query == text, !inventory.isEmpty else { return }

        // Only files nothing has considered — the point is what the earlier
        // rungs couldn't see.
        let known = Set(pool.map(\.url))
        let notInPool = inventory.filter { !known.contains($0.url) }
        guard !notInPool.isEmpty else { return }
        // Indexed files were searched already; read only what isn't indexed.
        let indexed = await ContentStore.shared.currentPaths(notInPool.map { (path: $0.url.path, modified: $0.modified) })
        guard !Task.isCancelled, query == text else { return }
        var unseen = notInPool.filter { !indexed.contains($0.url.path) }
        // A time in the query narrows what's worth opening at all — the
        // biggest saving of the time filter, since this rung reads files.
        if let window = timeWindow {
            unseen = unseen.filter { inWindow($0, window) }
        }
        guard !unseen.isEmpty else { return }

        var read = 0
        var cutoff = Date.distantFuture
        // One reading budget shared across windows (older windows get what's left).
        let readUntil = Date.now.addingTimeInterval(Self.readBudget)

        for window in Self.sweepWindows {
            guard !Task.isCancelled, query == text, Date.now < readUntil else { return }

            let start = window.days.isFinite
                ? Date().addingTimeInterval(-window.days * 86_400)
                : Date.distantPast
            let slice = unseen.filter { candidate in
                let modified = candidate.modified ?? .distantPast
                return modified > start && modified <= cutoff
            }
            cutoff = start
            guard !slice.isEmpty else { continue }

            reach = .sweeping(window: window.label, read: read)
            read += await readAndScore(Array(slice.prefix(150)),
                                       words: words, query: text, bar: window.bar,
                                       deadline: readUntil)

            guard !Task.isCancelled, query == text else { return }
            // Enough is enough. Every window past this one costs seconds and
            // returns files that are older and, by construction, worse.
            if strongResults >= thinResults { return }
        }
    }

    /// One window's worth: open the files, score them, keep what clears the bar.
    private func readAndScore(_ batch: [Candidate],
                              words: [String],
                              query text: String,
                              bar: Double,
                              deadline: Date) async -> Int {
        var read = 0

        for start in stride(from: 0, to: batch.count, by: 25) {
            guard !Task.isCancelled, query == text else { return read }
            // Reading is time-boxed too, checked per batch of 25.
            guard Date.now < deadline else { return read }
            let slice = Array(batch[start..<min(start + 25, batch.count)])

            let extracted = await extractor.texts(for: slice)
            guard !Task.isCancelled, query == text else { return read }
            read += slice.count

            var found: [Candidate] = []
            for var candidate in slice {
                guard let body = extracted[candidate.url], !body.isEmpty else { continue }
                candidate.text = String(body.text.prefix(300))
                candidate.pdfTitle = body.title
                markCoverage(&candidate, fullText: body.text)

                Self.applyCheapFeatures(to: &candidate, words: words, kinds: parsed.typeHints)
                if let title = body.title {
                    candidate.features.nameMatch = max(candidate.features.nameMatch,
                                                       Fuzzy.score(words: words, against: title))
                }
                // Nothing retrieved it; it was found by walking. Middling
                // rather than zero — being absent from the index says nothing
                // about whether it's the right file.
                candidate.features.retrievalRank = 0.4
                found.append(candidate)
            }

            // BM25 over this batch, then the bar — the best few that matched at all
            // are exempt (normalising damps a lone match).
            Self.applyBM25(&found, query: text, texts: extracted)

            let rescued = Set(found
                .filter { $0.features.textMatch > 0 }
                .sorted { $0.features.textMatch > $1.features.textMatch }
                .prefix(3)
                .map(\.url))

            found = found.filter { candidate in
                rescued.contains(candidate.url)
                    || max(candidate.features.textMatch, candidate.features.nameMatch) >= bar
            }

            guard !Task.isCancelled, query == text else { return read }
            if !found.isEmpty {
                absorb(found)
                publish()
            }
            sweptFiles = read
            if strongResults >= thinResults { return read }
        }
        return read
    }

    // MARK: - Features that cost nothing

    /// BM25 over the candidates in hand: IDF is local to them.
    private static func applyBM25(_ candidates: inout [Candidate],
                                  query text: String,
                                  texts: [URL: TextExtractor.Extracted]) {
        let terms = Tokens.query(text)
        guard !terms.isEmpty else { return }

        // Only read documents are scored. Stems match by prefix ("augment").
        let stems = terms.filter { $0.count >= 4 }
        var tokenised: [URL: [String]] = [:]
        for (url, extracted) in texts where !extracted.text.isEmpty {
            tokenised[url] = Tokens.of(extracted.text).map { token in
                stems.first { token.count > $0.count && token.hasPrefix($0) } ?? token
            }
        }
        guard !tokenised.isEmpty else { return }

        let model = BM25(documents: Array(tokenised.values))
        let urls = Array(tokenised.keys)
        let raw = urls.map { model.score(query: terms, document: tokenised[$0] ?? []) }
        let scaled = BM25.normalise(raw)

        var byURL: [URL: Double] = [:]
        for (url, score) in zip(urls, scaled) { byURL[url] = score }

        for index in candidates.indices {
            // Measured means "we opened it", not "it matched". A document read
            // and found irrelevant scores zero and deserves to; one never
            // opened scores zero and doesn't.
            if tokenised[candidates[index].url] != nil {
                candidates[index].features.textWasMeasured = true
            }
            guard let score = byURL[candidates[index].url] else { continue }
            // Never below what the index already knew: this BM25 is scored
            // only against the handful of files in hand, the index's against
            // everything — an exact phrase there stays an exact phrase.
            candidates[index].features.textMatch = max(score, candidates[index].indexedTextMatch)
        }
    }

    private static func applyCheapFeatures(to candidate: inout Candidate,
                                           words: [String],
                                           kinds: Set<String>) {
        // Fuzzy on the name; literal on the download URL. Kind is scored separately.
        candidate.features.nameMatch = Fuzzy.score(words: words, against: candidate.displayName)
        // The folder it's in is part of its name: "receipts" → Downloads/Receipts/March.jpg.
        let folders = folderMatch(words: words, url: candidate.url)
        candidate.features.nameMatch = max(candidate.features.nameMatch, folders.score)
        // A document's own title is a name too — often its real one. An arXiv
        // paper saved as "1706.03762v7.pdf" is "Attention Is All You Need".
        if let title = candidate.pdfTitle, !title.isEmpty {
            candidate.features.nameMatch = max(candidate.features.nameMatch,
                                               Fuzzy.score(words: words, against: title))
        }
        // A name holding one word of a long query is a weak match.
        if words.count >= 3 {
            let nameWords = Tokens.of(candidate.displayName + " " + (candidate.pdfTitle ?? "") + " " + folders.names)
            let covered = words.filter { word in nameWords.contains { $0 == word || $0.hasPrefix(word) } }.count
            if Double(covered) / Double(words.count) < 0.5 {
                candidate.features.nameMatch = min(candidate.features.nameMatch, 0.45)
            }
        }

        // `whereFrom` read here, for survivors only.
        if candidate.whereFrom == nil {
            candidate.whereFrom = DirectScan.whereFrom(candidate.url)
        }
        candidate.features.whereFromMatch =
            Fuzzy.literalOverlap(words, in: candidate.whereFrom ?? "")

        // Exponential decay with a one-week half-life. A linear "days ago"
        // would make a file from last March meaningfully worse than one from
        // last April, which is a distinction nobody making a query has in mind.
        if let modified = candidate.modified {
            let days = max(0, -modified.timeIntervalSinceNow / 86_400)
            // Plus a slow tail (one-year half-life): with the week alone every
            // file older than two months scored 0.00, so a 2023 résumé tied
            // with this year's and the name decided.
            candidate.features.recency = 0.6 * pow(0.5, days / 7) + 0.4 * pow(0.5, days / 365)
        }

        // Familiarity: Spotlight's use count plus our own opens, squashed.
        let opens = candidate.useCount + SearchLog.openCount(candidate.url.path)
        if opens > 0 {
            candidate.features.familiarity = min(1, log(Double(opens) + 1) / 4)
        }
        candidate.features.typeMatch = kinds.contains(candidate.url.pathExtension.lowercased()) ? 1 : 0
    }

    /// How well the file's folder names match the query's content words (≤ 0.8).
    private static func folderMatch(words: [String], url: URL) -> (score: Double, names: String) {
        let names = url.deletingLastPathComponent().pathComponents.suffix(2).joined(separator: " ")
        let content = words.filter { $0.count >= 3 && !QueryParse.describing.contains($0) }
        guard !content.isEmpty else { return (0, names) }
        let covered = content.filter { Fuzzy.score($0, against: names) >= 0.9 }.count
        return (covered == 0 ? 0 : 0.8 * Double(covered) / Double(content.count), names)
    }

    // MARK: - Pip's search

    /// The pipeline behind Pip's `find_files`: its own instance, `quick` (no
    /// typing pause, no sweep).
    static let forPip: SearchController = {
        let engine = SearchController()
        engine.quick = true
        return engine
    }()

    /// A third instance for `FileTidy`, so working out where a download
    /// belongs never cancels a search Pip is in the middle of.
    static let forTidy: SearchController = {
        let engine = SearchController()
        engine.quick = true
        return engine
    }()

    private var quick = false
    private var pipWaiter: (id: Int, resume: ([Candidate]) -> Void)?
    private var pipCounter = 0
    /// What Pip was last given, for logging which one he opened.
    private var pipShown: [Candidate] = []
    private var pipQuery = ""

    /// One search to the end, cut below a third of the best score.
    func find(_ text: String, timeHint hint: String? = nil) async -> [Candidate] {
        pipCounter += 1
        let id = pipCounter
        endPipSearch()              // one still waiting gets what it has
        query = text
        pipQuery = text
        let ranked: [Candidate] = await withCheckedContinuation { continuation in
            pipWaiter = (id, { continuation.resume(returning: $0) })
            timeHint = hint
            run(text)
        }
        let best = ranked.first?.score ?? 0
        // A third of the best — but a file filed under the kind asked for
        // stays ("papers": the one named "…-Paper.pdf" isn't more of a paper).
        return best > 0 ? ranked.filter { $0.score >= best * 0.33 || isAskedKind($0.url) } : ranked
    }

    /// Hands the waiting caller what's ranked now. Called when a run ends,
    /// when a newer one starts, and by a timer, so it's never left hanging.
    private func endPipSearch() {
        guard let waiter = pipWaiter else { return }
        pipWaiter = nil
        waiter.resume(lastRanked)
    }

    /// Starts the safety timer for a Pip search. Separate so `run` stays the
    /// same for both instances.
    private func armPipTimeout() {
        guard quick, let id = pipWaiter?.id else { return }
        // Longer when the query names a period: that period's files may be
        // read on the spot first (see `readTimeWindow`).
        let seconds: UInt64 = timeWindow == nil ? 4 : 8
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, self.pipWaiter?.id == id else { return }
            // Nothing that holds every word yet, and still searching: one more
            // wait rather than handing over a half list as the answer (an
            // empty one sent Pip to the old fallback finder).
            if !self.lastRanked.contains(where: \.matchesAll) {
                ActivityLog.write(.search, "Pip search still running after \(seconds)s — waiting 4s more")
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard self.pipWaiter?.id == id else { return }
            }
            // Spotlight hasn't answered at all (a cold start, a common word):
            // the list is empty because nothing has run, not because nothing
            // matches. Up to twelve seconds more.
            for _ in 0..<12 where !self.retrieved {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.pipWaiter?.id == id else { return }
            }
            self.endPipSearch()
        }
    }

    /// The files Pip actually showed (after his type filter).
    func remember(shown: [Candidate]) {
        pipShown = shown
    }

    /// Pip opened or revealed a file he found: logged like a panel open.
    func recordPipOpen(_ url: URL) {
        guard let rank = pipShown.firstIndex(where: { $0.url == url }) else { return }
        ActivityLog.write(.search, "opened #\(rank + 1) of \(pipShown.count) for Pip \"\(pipQuery)\": \(url.lastPathComponent)")
        let shown = pipShown
        let text = pipQuery
        Task { await SearchLog.shared.recordOpen(path: url.path, query: text, shown: shown) }
    }

    // MARK: - Opening, which is also the label

    func openSelected() {
        guard results.indices.contains(selection) else { return }
        open(results[selection])
    }

    func open(_ candidate: Candidate) {
        // Record before opening. Once NSWorkspace activates another app this
        // panel is closing, and the label is the whole reason the log exists.
        logOpen(candidate.url)
        NSWorkspace.shared.open(candidate.url)
        close()
    }

    func revealSelected() {
        guard results.indices.contains(selection) else { return }
        reveal(results[selection])
    }

    /// Show a specific result in Finder. Separate from `revealSelected` because
    /// the detail pane's button acts on what it is displaying, which is not
    /// necessarily what the keyboard has selected.
    func reveal(_ candidate: Candidate) {
        logOpen(candidate.url)
        NSWorkspace.shared.activateFileViewerSelecting([candidate.url])
        close()
    }

    func move(by delta: Int) {
        noteActivity()
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
        keyboardMoves += 1
    }

    /// Hover just highlights. It deliberately doesn't scroll.
    func hover(_ index: Int) {
        guard results.indices.contains(index), selection != index else { return }
        selection = index
    }

    /// The open waiting to be logged, so closing can wait for it.
    private var pendingOpenLog: Task<Void, Never>?

    /// Logs an open against what is on screen right now — see
    /// `SearchLog.recordOpen` for why it isn't the last impression.
    private func logOpen(_ url: URL) {
        let text = query
        let shown = results
        // The accuracy measure: which position the file you wanted was in.
        if let rank = shown.firstIndex(where: { $0.url == url }) {
            ActivityLog.write(.search, "opened #\(rank + 1) of \(shown.count) for \"\(text)\": \(url.lastPathComponent)")
        } else {
            ActivityLog.write(.search, "opened a weaker match for \"\(text)\": \(url.lastPathComponent)")
        }
        pendingOpenLog = Task {
            await SearchLog.shared.recordOpen(path: url.path, query: text, shown: shown)
        }
    }

    private func recordImpression() {
        let snapshot = results
        let text = query
        Task { await SearchLog.shared.recordImpression(query: text, candidates: snapshot) }
    }

    private func takeSnapshot() {
        snapshot = Snapshot(query: query, folder: folder,
                            retrieved: lastRetrievedCount, results: results,
                            ranked: lastRanked,
                            pooled: pool.count,
                            opened: pool.filter { $0.text != nil }.count,
                            words: Tokens.query(query),
                            predicate: retriever.lastPredicate,
                            direct: directMatchCount, at: .now)
    }

    // MARK: - Explaining itself

    /// What the last search did, stage by stage, to locate a fault.
    func explain() async -> String {
        let shot = snapshot
        guard !shot.query.isEmpty else {
            return "No search has run yet. Press ⌥F, type something, then pick this again."
        }

        var lines: [String] = []
        lines.append("query: \"\(shot.query)\"")
        lines.append("folder: \(shot.folder?.path ?? "everywhere")")
        lines.append("words searched: \(shot.words.joined(separator: ", "))")
        lines.append("retrieved by Spotlight: \(shot.retrieved)"
                     + "    found by walking the folder: \(shot.direct)"
                     + "    shown: \(shot.results.count)")
        lines.append("in the pool: \(shot.pooled)    opened and read: \(shot.opened)"
                     + "    swept: \(sweptFiles)")
        // Matches from the content store (where content search actually lives).
        lines.append("from the content store: \(storeMatchCount)")
        // A full table scan, so only asked for here.
        lines.append(await ContentStore.shared.summary())
        // Meaning: whether the index exists, what it contributed, and how
        // close the closest documents were. The similarities are what to
        // read when deciding whether `meaningFloor` is set right.
        lines.append(await SemanticIndex.shared.summary())
        lines.append("from meaning: \(semanticMatchCount)"
                     + (semanticTop.isEmpty ? "" : "    closest: " + semanticTop.joined(separator: ", ")))
        lines.append("background indexing: "
                     + (PowerMonitor.isOnBattery
                        ? "paused — on battery"
                        : "active"))
        lines.append("")
        lines.append("The table below is the ranked pool, not the five shown — so a file")
        lines.append("that was found but ranked eleventh appears here. If it isn't listed")
        lines.append("at all, retrieval never returned it and nothing downstream could help.")
        lines.append("of the \(shot.results.count) shown: "
                     + "\(shot.results.filter { $0.text != nil }.count) read, "
                     + "\(shot.results.filter { !($0.text ?? "").isEmpty }.count) with text")
        lines.append("")
        lines.append(diagnosis(shot))
        lines.append("")
        lines.append("text is BM25 over the candidate set (or FTS5 for stored documents);")
        lines.append("mean is search-by-meaning: the closest of a document's passages.")
        lines.append("")
        lines.append(ranker.explain())
        lines.append("")

        let header = ["#", "score", "name", "from", "text", "mean", "recent", "used", "type"]
        lines.append(header.map { $0.padding(toLength: 6, withPad: " ", startingAt: 0) }
            .joined(separator: " ") + " file")

        for (index, candidate) in shot.ranked.prefix(15).enumerated() {
            let f = candidate.features
            let cells = ["\(index)",
                         String(format: "%.2f", candidate.score),

                         String(format: "%.2f", f.nameMatch),
                         String(format: "%.2f", f.whereFromMatch),
                         // A dash when nothing was read, not 0.00.
                         f.textWasMeasured ? String(format: "%.2f", f.textMatch) : "  —",
                         f.semanticMatch > 0 ? String(format: "%.2f", f.semanticMatch) : "  —",
                         String(format: "%.2f", f.recency),
                         String(format: "%.2f", f.familiarity),
                         String(format: "%.2f", f.typeMatch)]
            lines.append(cells.map { $0.padding(toLength: 6, withPad: " ", startingAt: 0) }
                .joined(separator: " ") + " " + candidate.displayName.prefix(44))
        }

        // The first words of what was actually read, because "extraction
        // returned something" and "extraction returned something useful" are
        // different claims and only one of them can be checked by eye.
        if let first = shot.results.first(where: { $0.text != nil }) {
            lines.append("")
            lines.append("text read from \(first.displayName):")
            lines.append((first.text ?? "").isEmpty
                         ? "  (empty — a scan with no text layer, or PDFKit refused it)"
                         : "  " + String((first.text ?? "").prefix(240)))
        }
        return lines.joined(separator: "\n")
    }

    /// Names the stage that failed.
    private func diagnosis(_ shot: Snapshot) -> String {
        if shot.retrieved == 0, shot.direct > 0 {
            return """
            DIAGNOSIS: Spotlight returned nothing, but walking the folder found \(shot.direct).

            Spotlight's index is missing these files. That is not this app's doing
            and, since the content store went in, not this app's problem either:
            filenames come from walking the folders, and contents come from files
            we've read ourselves and kept. Both work with the index empty.

            So this line is an observation, not a fault. Rebuilding the index would
            help Finder and the system search; it is not needed here.

              mdutil -s /System/Volumes/Data     is indexing on for your files?
              mdutil -E /System/Volumes/Data     rebuild it (takes a while)

            Note the volume: on Apple silicon `/` is the read-only system volume,
            so `mdutil -s /` reports "enabled" while your home directory is not
            indexed at all. Also worth checking System Settings ▸ Spotlight ▸
            Spotlight Privacy for a folder excluded and forgotten about.
            """
        }
        if shot.retrieved == 0 {
            return """
            DIAGNOSIS: Spotlight returned nothing, so nothing downstream ran.

            The query handed to Spotlight was:
              \(shot.predicate)

            Try that verbatim in Terminal to see whether it's the query or the index:
              mdfind -onlyin "\(shot.folder?.path ?? NSHomeDirectory())" 'kMDItemFSName == "*\(shot.words.first ?? "")*"cd'
            """
        }
        let read = shot.opened
        if read == 0 {
            return "DIAGNOSIS: retrieval worked, but nothing was read. "
                + "Extraction never ran — the deep pass was cancelled or failed early."
        }
        let withText = shot.results.filter { !($0.text ?? "").isEmpty }.count
        if withText == 0 {
            return "DIAGNOSIS: files were opened but no text came out. "
                + "PDFKit refused them, or they're a format nothing here can read "
                + "(Pages and Keynote files have no extractor). Scanned PDFs are "
                + "rendered and OCR'd, so those shouldn't land here."
        }
        return "DIAGNOSIS: every stage produced output. If the order is wrong, "
            + "it's the ranker's weights (`Ranker.priors`)."
    }
}

