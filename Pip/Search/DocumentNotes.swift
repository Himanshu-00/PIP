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

    private static let system = "You describe the user's files so they can find and group them. "
        + "Reply with one short line only."
    /// "<kind> on/for/from <topic>": `ResultGroups.kind(of:)` reads the kind back.
    private static let question = "In 4 to 10 words, what is this file? First what kind of file a person would "
        + "call it, in one to three words, then \"on\", \"for\" or \"from\" and what it's about "
        + "(\"Lecture slides on probability\", \"Receipt for a phone case\"). Don't mention the file format. "
        + "No names of people, no full stop."

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
                guard let about = await Self.describe(document), !Task.isCancelled else { break }
                if await self.save(document, about: about) { each(document.path) }
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
            guard !Task.isCancelled, let about = await Self.describe(document) else { break }
            if await save(document, about: about) { wrote += 1 }
        }
        return wrote
    }

    /// Saves a description, into the searchable text and meaning too. True if written.
    private func save(_ document: ContentStore.Undescribed, about: String) async -> Bool {
        surfaced.removeAll { $0 == document.path }
        guard let saved = await ContentStore.shared.setAbout(path: document.path, modified: document.modified,
                                                             about: about) else { return false }
        FileNoteCache.shared.forget(document.path)
        guard !about.isEmpty else { return false }
        await SemanticIndex.shared.add(path: document.path, modified: document.modified,
                                       title: saved.title, text: saved.text, replace: true)
        ActivityLog.write(.search, "described \((document.path as NSString).lastPathComponent): \(about)")
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
    func hasWork() async -> Bool { await ContentStore.shared.undescribedCount() > 0 }

    private func run() async {
        var wrote = 0
        var seconds: [Double] = []
        while !Task.isCancelled, canWork {
            let batch = await ContentStore.shared.undescribedDocuments(first: surfaced, limit: 8)
            guard !batch.isEmpty else { break }
            for document in batch {
                guard !Task.isCancelled, canWork else { break }
                let started = Date()
                guard let about = await Self.describe(document) else { break }
                // Cancelled mid-line: the half-written one isn't kept.
                guard !Task.isCancelled else { break }
                if await save(document, about: about) {
                    wrote += 1
                    seconds.append(Date().timeIntervalSince(started))
                }
            }
            let each = seconds.isEmpty ? "" : String(format: ", %.1f s each", seconds.reduce(0, +) / Double(seconds.count))
            ActivityLog.write(.search, "descriptions: wrote \(wrote) (\(await ContentStore.shared.undescribedCount()) left)\(each)")
        }
        if !Task.isCancelled { stop() }
    }

    /// One line about the document; "" when there's nothing to say (so it
    /// isn't tried again); nil if the brain failed.
    static func describe(_ document: ContentStore.Undescribed) async -> String? {
        let url = URL(fileURLWithPath: document.path)
        let folder = url.deletingLastPathComponent()
        let home = NSHomeDirectory()
        let neighbours = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != url.lastPathComponent }
            .sorted().prefix(8).joined(separator: ", ")
        let opening = document.text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .prefix(700)
        guard opening.count >= 20 || document.title != nil else { return "" }
        var lines = ["File: \(url.lastPathComponent)",
                     "Folder: " + folder.path.replacingOccurrences(of: home, with: "~")]
        if !neighbours.isEmpty { lines.append("Next to it: \(neighbours)") }
        if let from = DirectScan.whereFrom(url), let host = URL(string: from)?.host { lines.append("Downloaded from: \(host)") }
        if let title = document.title, !title.isEmpty { lines.append("Title: \(title)") }
        lines.append("It starts: \(opening)")
        let messages: [[String: Any]] = [["role": "system", "content": system],
                                         ["role": "user", "content": lines.joined(separator: "\n") + "\n\n" + question]]
        guard let reply = try? await LocalBrain.shared.chat(messages: messages, tools: []) else { return nil }
        let line = OllamaClient.stripThinking(reply.content)
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " .\"'*"))
            ?? ""
        return String(line.prefix(120))
    }
}
