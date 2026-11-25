import AppKit

/// One line per document from Pip's own brain — what kind of file it is and
/// what it's about, in its own words ("Research paper on transformer
/// language models", "Rent receipt for March 2026"). No list of categories:
/// the model reads the file and its surroundings (name, folder, the files
/// beside it, where it was downloaded from) and says what it is.
///
/// Two ways: a search's undescribed results, at once, as it settles
/// (`describeNow`); and the rest only while the Mac is idle, plugged in and
/// cool, and Pip isn't in use — any input stops that at once, and files
/// searches surfaced go first (`surfaced`). The line becomes the first line of the document's
/// searchable text and meaning, so "research papers" finds files described
/// as papers, and search results are grouped by it (`ResultGroups`).
@MainActor
final class DocumentNotes {

    static let shared = DocumentNotes()

    /// Pip is thinking, listening or speaking (set by `AppDelegate`).
    var pipInUse: () -> Bool = { false }

    /// Paths searches showed that have no description yet, newest first.
    private(set) var surfaced: [String] = []

    private var task: Task<Void, Never>?
    /// Describing a search's results right now.
    private var liveTask: Task<Void, Never>?
    /// A request made while Pip was busy, run when he's done.
    private var waiting: (paths: [String], limit: Int, each: @MainActor (String) -> Void)?

    /// Pip finished answering and speaking: a waiting request runs now.
    func pipBecameIdle() {
        guard let waiting, !pipInUse() else { return }
        self.waiting = nil
        describeNow(waiting.paths, limit: waiting.limit, each: waiting.each)
    }
    var isRunning: Bool { task != nil }
    private var watchers: [Any] = []
    private var observers: [NSObjectProtocol] = []

    private static let system = "You file the user's files so they can find and group them. "
        + "Reply with exactly the two lines asked for."
    /// The kind (stored, `Kinds`) and the line about it.
    private static let question = "Reply with two lines.\n"
        + "Kind: what kind of file this is, in one to three words — the folder a person would file it in. "
        + "Be specific about what it is, not its topic: a research paper and an exam paper are different kinds.\n"
        + "About: in 4 to 10 words, the kind then \"on\", \"for\" or \"from\" and what it's about.\n"
        + "Don't mention the file format. No names of people, no full stop."
    /// For a kind read from an older description: the kind alone.
    private static let kindQuestion = "What kind of file is this, in one to three words — the folder a person "
        + "would file it in? Be specific about what it is, not its topic: a research paper and an exam paper are "
        + "different kinds. Reply with the kind only."

    private var canWork: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return !PowerMonitor.isOnBattery && ContentIndexer.macIsIdle
            && (thermal == .nominal || thermal == .fair) && !pipInUse()
    }

    /// Search results to describe first, next time Pip is idle.
    func noteSurfaced(_ paths: [String]) {
        let new = paths.filter { !surfaced.contains($0) }
        guard !new.isEmpty else { return }
        surfaced = Array((new + surfaced).prefix(200))
    }

    /// Called by the indexer when the Mac is idle; does nothing unless it's a good time.
    func startIfIdle() {
        guard task == nil, LocalBrain.isDownloaded, canWork else { return }
        let input: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
                                            .keyDown, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: input, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }) { watchers.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: input, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.stop() }
            return event
        }) { watchers.append(local) }
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.canWork == false { self?.stop() } }
        })
        task = Task { [weak self] in await self?.run() }
    }

    /// A search's results, described now (up to `limit` not yet described),
    /// best-ranked first; `each` after every one, to update the rows and
    /// groups. Cancelled by the next search or by Pip using the brain.
    func describeNow(_ paths: [String], limit: Int, each: @escaping @MainActor (String) -> Void) {
        liveTask?.cancel()
        liveTask = nil
        noteSurfaced(paths)
        // Pip is answering or speaking (his own file list arrives mid-answer):
        // kept for when he's done (`pipBecameIdle`).
        if pipInUse() { waiting = (paths, limit, each); return }
        waiting = nil
        let thermal = ProcessInfo.processInfo.thermalState
        guard LocalBrain.isDownloaded, task == nil, thermal == .nominal || thermal == .fair else { return }
        liveTask = Task { [weak self] in
            let batch = await ContentStore.shared.undescribedDocuments(first: paths, limit: limit, onlyFirst: true)
            guard !batch.isEmpty else { return }
            ActivityLog.write(.search, "describing \(batch.count) search results now")
            for document in batch {
                guard !Task.isCancelled, let self, !self.pipInUse() else { break }
                guard let described = await Self.describe(document), !Task.isCancelled else { break }
                if await self.save(document, about: described.about, kind: described.kind) { each(document.path) }
            }
        }
    }

    /// Describes up to `limit` of `paths` not yet described and returns once
    /// done (organising a folder needs them first). Pip asked for it, so it
    /// runs while he's in use. Returns how many were written.
    func describeAll(_ paths: [String], limit: Int) async -> Int {
        let thermal = ProcessInfo.processInfo.thermalState
        guard LocalBrain.isDownloaded, thermal != .critical else { return 0 }
        stop(forPip: true)
        let batch = await ContentStore.shared.undescribedDocuments(first: paths, limit: limit, onlyFirst: true)
        guard !batch.isEmpty else { return 0 }
        ActivityLog.write(.search, "describing \(batch.count) files to organise them")
        var wrote = 0
        for document in batch {
            guard !Task.isCancelled, let described = await Self.describe(document) else { break }
            if await save(document, about: described.about, kind: described.kind) { wrote += 1 }
        }
        return wrote
    }

    /// Saves a description, into the searchable text and meaning too. True if written.
    private func save(_ document: ContentStore.Undescribed, about: String, kind: String?) async -> Bool {
        surfaced.removeAll { $0 == document.path }
        guard let saved = await ContentStore.shared.setAbout(path: document.path, modified: document.modified,
                                                             about: about, kind: kind) else { return false }
        FileNoteCache.shared.forget(document.path)
        guard !about.isEmpty else { return false }
        await SemanticIndex.shared.add(path: document.path, modified: document.modified,
                                       title: saved.title, text: saved.text, replace: true)
        ActivityLog.write(.search, "described \((document.path as NSString).lastPathComponent): \(about) [\(kind ?? "-")]")
        return true
    }

    /// Stops at once. `forPip`: Pip is about to use the brain, so it stays loaded.
    func stop(forPip: Bool = false) {
        liveTask?.cancel()
        liveTask = nil
        guard let task else { return }
        task.cancel()
        self.task = nil
        watchers.forEach(NSEvent.removeMonitor)
        watchers.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if !forPip { Task { await LocalBrain.shared.unload() } }
    }

    /// True while there are documents left (so the caller knows to wait).
    func hasWork() async -> Bool {
        if await ContentStore.shared.undescribedCount() > 0 { return true }
        return await ContentStore.shared.kindsToRecheckCount() > 0
    }

    private func run() async {
        var wrote = 0
        var seconds: [Double] = []
        while !Task.isCancelled, canWork {
            let batch = await ContentStore.shared.undescribedDocuments(first: surfaced, limit: 8)
            guard !batch.isEmpty else { break }
            for document in batch {
                guard !Task.isCancelled, canWork else { break }
                let started = Date()
                guard let described = await Self.describe(document) else { break }
                // Cancelled mid-line: the half-written one isn't kept.
                guard !Task.isCancelled else { break }
                if await save(document, about: described.about, kind: described.kind) {
                    wrote += 1
                    seconds.append(Date().timeIntervalSince(started))
                }
            }
            let each = seconds.isEmpty ? "" : String(format: ", %.1f s each", seconds.reduce(0, +) / Double(seconds.count))
            ActivityLog.write(.search, "descriptions: wrote \(wrote) (\(await ContentStore.shared.undescribedCount()) left)\(each)")
        }
        // Then kinds only read from older descriptions: Pip looks again
        // ("Attention paper" → research paper; "Cryptography exam paper" → exam paper).
        var filed = 0
        while !Task.isCancelled, canWork {
            let batch = await ContentStore.shared.kindsToRecheck(first: surfaced, limit: 12)
            guard !batch.isEmpty else { break }
            var kinds: [(path: String, kind: String)] = []
            for document in batch {
                guard !Task.isCancelled, canWork, let kind = await Self.kind(of: document) else { break }
                kinds.append((document.path, kind))
            }
            guard !Task.isCancelled, !kinds.isEmpty else { break }
            await ContentStore.shared.setKinds(kinds, by: "pip")
            kinds.forEach { FileNoteCache.shared.forget($0.path) }
            filed += kinds.count
            ActivityLog.write(.search, "kinds: filed \(filed) (\(await ContentStore.shared.kindsToRecheckCount()) left) — "
                              + kinds.prefix(3).map { "\(($0.path as NSString).lastPathComponent): \($0.kind)" }.joined(separator: ", "))
        }
        if !Task.isCancelled { stop() }
    }

    /// Descriptions written before kinds were stored get one now, read from
    /// the line itself, so searches can use them at once; Pip's brain looks
    /// again while the Mac is idle (`run`).
    static func fileOldDescriptions() async {
        // The kinds in use, so the list can be looked over: the most common,
        // and how many are used only once (spelt oddly, or truly rare).
        let counts = await ContentStore.shared.kindCounts()
        let once = counts.filter { $0.count == 1 }
        ActivityLog.write(.search, "kinds: \(counts.count) in use; most: "
                          + counts.prefix(8).map { "\($0.kind) \($0.count)" }.joined(separator: ", ")
                          + "; \(once.count) used once (e.g. " + once.prefix(5).map(\.kind).joined(separator: ", ") + ")")
        let old = await ContentStore.shared.describedWithoutKind()
        guard !old.isEmpty else { return }
        let kinds = await Task.detached(priority: .utility) {
            old.compactMap { item in Kinds.fromLine(item.about).map { (path: item.path, kind: $0) } }
        }.value
        await ContentStore.shared.setKinds(kinds, by: "line")
        ActivityLog.write(.search, "kinds: filed \(kinds.count) older descriptions from their lines")
    }

    /// One line about the document and its kind; ("", nil) when there's
    /// nothing to say (so it isn't tried again); nil if the brain failed.
    static func describe(_ document: ContentStore.Undescribed) async -> (about: String, kind: String?)? {
        let url = URL(fileURLWithPath: document.path)
        let folder = url.deletingLastPathComponent()
        let home = NSHomeDirectory()
        let neighbours = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != url.lastPathComponent }
            .sorted().prefix(8).joined(separator: ", ")
        let opening = document.text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .prefix(700)
        guard opening.count >= 20 || document.title != nil else { return ("", nil) }
        var lines = ["File: \(url.lastPathComponent)",
                     "Folder: " + folder.path.replacingOccurrences(of: home, with: "~")]
        if !neighbours.isEmpty { lines.append("Next to it: \(neighbours)") }
        if let from = DirectScan.whereFrom(url), let host = URL(string: from)?.host { lines.append("Downloaded from: \(host)") }
        if let title = document.title, !title.isEmpty { lines.append("Title: \(title)") }
        lines.append("It starts: \(opening)")
        let messages: [[String: Any]] = [["role": "system", "content": system],
                                         ["role": "user", "content": lines.joined(separator: "\n") + "\n\n" + question]]
        guard let reply = try? await LocalBrain.shared.chat(messages: messages, tools: []) else { return nil }
        let replyLines = OllamaClient.stripThinking(reply.content).split(separator: "\n").map(String.init)
        let clean = { (line: String) in line.trimmingCharacters(in: CharacterSet(charactersIn: " .\"'*")) }
        let value = { (label: String) in
            replyLines.first { $0.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix(label) }
                .map { clean(String($0.drop { $0 != ":" }.dropFirst())) }
        }
        // Two lines as asked; an older-style single line still works.
        let about = String((value("about") ?? replyLines.first { !$0.lowercased().hasPrefix("kind") }.map(clean) ?? "").prefix(120))
        let kind = value("kind").flatMap(Kinds.normalise) ?? Kinds.fromLine(about)
        return (about, kind)
    }

    /// The kind alone, for a document whose kind was only read from its
    /// description. Nil if the brain failed.
    static func kind(of document: ContentStore.ToRecheck) async -> String? {
        let url = URL(fileURLWithPath: document.path)
        let home = NSHomeDirectory()
        var lines = ["File: \(url.lastPathComponent)",
                     "Folder: " + url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~"),
                     "What it is: \(document.about)"]
        if let title = document.title, !title.isEmpty { lines.append("Title: \(title)") }
        let opening = document.opening.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(400)
        if !opening.isEmpty { lines.append("It starts: \(opening)") }
        let messages: [[String: Any]] = [["role": "system", "content": system],
                                         ["role": "user", "content": lines.joined(separator: "\n") + "\n\n" + kindQuestion]]
        guard let reply = try? await LocalBrain.shared.chat(messages: messages, tools: []) else { return nil }
        let line = OllamaClient.stripThinking(reply.content).split(separator: "\n").first.map(String.init) ?? ""
        let kind = line.replacingOccurrences(of: #"^\s*kind\s*:"#, with: "", options: [.regularExpression, .caseInsensitive])
        return Kinds.normalise(kind)
    }
}
