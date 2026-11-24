import Foundation

/// Every search shown and what was opened from it, on this Mac only.
actor SearchLog {

    static let shared = SearchLog()

    /// One search, and what happened.
    struct Entry: Codable {
        var query: String
        var at: Date
        /// The feature vectors of what was shown, in the order shown.
        var shown: [[Double]]
        var paths: [String]
        /// Index into `shown` of whatever was opened. Nil means the search was
        /// abandoned — which is information too: a query that never produces a
        /// click is a query the system is failing at.
        var chosen: Int?
    }

    private let storage: URL
    private var entries: [Entry] = []
    private var pending: Entry?

    /// A few thousand searches is plenty to train on and small enough to read
    /// and rewrite whole. Past that the oldest go, because search habits from
    /// a year ago aren't habits any more.
    private let limit = 1_500
    /// Set when there are changes not yet on disk.
    private var dirty = false

    private init() {
        storage = AppFolders.support.appendingPathComponent("searches.json")
        entries = Self.load(from: storage)
        for entry in entries { Self.countOpen(entry) }
    }

    // MARK: - Opens, for the ranker's familiarity

    /// Path → query → times opened from a search with that query. Read by the
    /// ranker's synchronous feature code, so it lives outside the actor.
    nonisolated(unsafe) private static var opens: [String: [String: Int]] = [:]
    private static let opensLock = NSLock()

    /// DEBUG search checks set this to the query being checked: an open from
    /// that same search is the answer, not familiarity.
    nonisolated(unsafe) static var ignoredOpenQuery: String?

    private static func key(_ query: String) -> String {
        query.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private static func countOpen(_ entry: Entry) {
        guard let chosen = entry.chosen, chosen < entry.paths.count else { return }
        opensLock.lock()
        opens[entry.paths[chosen], default: [:]][key(entry.query), default: 0] += 1
        opensLock.unlock()
    }

    /// How often this file was opened from a search.
    nonisolated static func openCount(_ path: String) -> Int {
        let ignored = ignoredOpenQuery.map(key)
        opensLock.lock()
        defer { opensLock.unlock() }
        return opens[path, default: [:]].reduce(0) { $0 + ($1.key == ignored ? 0 : $1.value) }
    }

    // MARK: - Recording

    /// Results went on screen: replaces the pending entry (one search, one entry).
    func recordImpression(query: String, candidates: [Candidate]) {
        // Only the visible ones. A candidate ranked fortieth was not seen, was
        // therefore not rejected, and teaching the model otherwise is teaching
        // it something false.
        let visible = Array(candidates.prefix(8))
        pending = Entry(query: query,
                        at: .now,
                        shown: visible.map(\.features.vector),
                        paths: visible.map(\.url.path),
                        chosen: nil)
    }

    /// A result was opened, built from what's on screen now.
    func recordOpen(path: String, query: String, shown candidates: [Candidate]) {
        guard let index = candidates.prefix(30).firstIndex(where: { $0.url.path == path })
        else { return }
        // Everything above the click was seen and passed over; a minimum of
        // eight, matching an impression, for the stats.
        let visible = Array(candidates.prefix(max(8, index + 1)))
        pending = nil
        append(Entry(query: query,
                     at: .now,
                     shown: visible.map(\.features.vector),
                     paths: visible.map(\.url.path),
                     chosen: index))
    }

    /// Called when the panel closes without anything being opened.
    func abandon() { flushPending() }

    /// Drops the search on screen without filing it — for the DEBUG search
    /// checks, whose replayed queries aren't the owner's searches.
    func discardPending() { pending = nil }

    /// Every search that ended in an open, as (query, opened path).
    func picks() -> [(query: String, path: String)] {
        entries.compactMap { entry in
            guard let chosen = entry.chosen, chosen < entry.paths.count else { return nil }
            return (entry.query, entry.paths[chosen])
        }
    }

    private func flushPending() {
        guard let entry = pending else { return }
        pending = nil
        // Keep the abandonments. They don't produce training pairs, but they
        // are the numerator of "how often does this fail", which is the number
        // worth watching.
        append(entry)
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        Self.countOpen(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        scheduleSave()
    }

    /// Saves at most every few seconds.
    private func scheduleSave() {
        dirty = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.flush()
        }
    }

    private var saveTask: Task<Void, Never>?

    func flush() {
        saveTask = nil
        guard dirty else { return }
        dirty = false
        save()
    }

    // MARK: - Measurement

    struct Stats {
        var searches = 0
        var withAnOpen = 0
        var topOne = 0
        var meanReciprocalRank = 0.0

        var successRate: Double {
            searches > 0 ? Double(withAnOpen) / Double(searches) : 0
        }
    }

    /// Mean reciprocal rank and friends.
    func stats(since: Date = .distantPast) -> Stats {
        var stats = Stats()
        var reciprocalSum = 0.0

        for entry in entries where entry.at >= since {
            stats.searches += 1
            guard let chosen = entry.chosen else { continue }
            stats.withAnOpen += 1
            if chosen == 0 { stats.topOne += 1 }
            reciprocalSum += 1 / Double(chosen + 1)
        }
        if stats.withAnOpen > 0 {
            stats.meanReciprocalRank = reciprocalSum / Double(stats.withAnOpen)
        }
        return stats
    }

    // MARK: - Persistence

    /// Static so the actor's init can call it.
    private static func load(from storage: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: storage),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return decoded
    }

    private func save() {
        let folder = storage.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storage, options: .atomic)
    }
}
