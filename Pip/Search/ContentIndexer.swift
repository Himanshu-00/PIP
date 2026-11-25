import CoreGraphics
import CoreServices
import Foundation

/// Fills the content store in the background: new and changed documents in
/// the usual folders, plus a one-time backfill. Bounded; no OCR on battery.
@MainActor
final class ContentIndexer {

    /// How many documents one pass may read. Small on purpose: a pass that
    /// misses something gets another go in ten minutes, and there is never a
    /// reason for this to compete with anything the user is doing.
    private let batchLimit = 60
    /// The one-time catch-up on files that predate the store existing.
    private let backfillLimit = 500
    /// Long enough that it's not a busy loop, short enough that a document
    /// saved while the app is running is indexed before it's wanted.
    private let sweepInterval: TimeInterval = 600

    private let extractor = TextExtractor()
    /// One-line photo descriptions from Pip's vision, written while idle.
    let captions = PhotoCaptions()
    /// One recursive file-system event stream over the usual folders.
    private var stream: FSEventStreamRef?
    /// Paths changed since the last indexing of changes.
    private var changed = Set<String>()
    private var changeTask: Task<Void, Never>?
    private var timer: Timer?
    /// One pass at a time. Two overlapping passes would read the same files
    /// twice and race each other into the store.
    private var running = false

    private static let backfilledKey = "contentStoreBackfilled"

    // MARK: - Lifecycle

    func start() {
        // Changes are indexed as they happen, at any depth (`startEvents`).
        // The timer is the catch-up for files that predate the app or changed
        // while it wasn't running.
        startEvents()

        timer = Timer.scheduledTimer(withTimeInterval: sweepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.pass() }
            }
        }
        // Tolerance lets macOS line this up with other timers instead of
        // waking the CPU on its own account. For work nobody is waiting on,
        // being a minute late is free and the wakeup isn't.
        timer?.tolerance = 60

        Task { [weak self] in
            // A moment after launch, not during it. Login is busy enough, and
            // the first pass after an update is the expensive one.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await self?.pass()
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        timer?.invalidate()
        timer = nil
        captions.stop()
        DocumentNotes.shared.stop()
    }

    // MARK: - Changes, as they happen

    /// FSEvents: changed files at any depth, as they happen.
    private func startEvents() {
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let indexer = Unmanaged<ContentIndexer>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { indexer.noteChanges(Array(list.prefix(count))) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(nil, callback, &context,
                                               DirectScan.commonFolders.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               3.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func noteChanges(_ paths: [String]) {
        let skipped = DirectScan.skippedFolders
        for path in paths {
            let parts = path.split(separator: "/")
            guard !parts.contains(where: { $0.hasPrefix(".") || skipped.contains(String($0)) }),
                  !DirectScan.isExcluded(path) else { continue }
            changed.insert(path)
        }
        guard !changed.isEmpty, changeTask == nil else { return }
        // Gather a few seconds of changes into one batch (a download or a
        // save produces a burst of events for one file).
        changeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await self?.indexChanges()
        }
    }

    /// Reads just the files that changed — no folder walk.
    private func indexChanges() async {
        changeTask = nil
        guard !Self.searchIsBusy, !running else {
            // Try again shortly; the changes are kept.
            noteChanges([])
            return
        }
        let paths = changed
        changed.removeAll()
        let kinds = DirectScan.readableKinds.union(DirectScan.codeKinds)
        let onBattery = PowerMonitor.isOnBattery
        var entries: [(path: String, modified: Date?, size: Int?)] = []
        var candidates: [Candidate] = []
        var gone: [String] = []
        var batteryImages = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard kinds.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey,
                                                                 .contentAccessDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                gone.append(path)       // deleted — or renamed: decided after the new paths are recorded
                continue
            }
            let size = values.fileSize ?? 0
            guard size > 512, size < 80_000_000 else { continue }
            entries.append((path, values.contentModificationDate, size))
            let candidate = Candidate(url: url, displayName: url.lastPathComponent,
                                      modified: values.contentModificationDate,
                                      lastOpened: values.contentAccessDate, useCount: 0, whereFrom: nil)
            // A few new images are read even on battery (OCR is on the Neural Engine).
            if onBattery, candidate.isImage {
                guard batteryImages < 5 else { continue }
                batteryImages += 1
            }
            candidates.append(candidate)
        }
        // New paths first: a renamed file is matched to its old row (same
        // inode) and keeps its text and vectors — so it's current, not read
        // again, and its old path isn't forgotten.
        let renamed = await ContentStore.shared.recordFiles(entries)
        for path in gone where !renamed.contains(path) { await ContentStore.shared.forget(path: path) }
        var toRead: [Candidate] = []
        for candidate in candidates where !(await ContentStore.shared.isCurrent(path: candidate.url.path,
                                                                                  modified: candidate.modified)) {
            toRead.append(candidate)
        }
        guard !toRead.isEmpty else { return }
        running = true
        defer { running = false }
        _ = await extractor.texts(for: toRead, parallel: Self.parallelism)
        await extractor.trim(to: 0)
        ActivityLog.write(.search, "indexer: read \(toRead.count) changed file\(toRead.count == 1 ? "" : "s")")
    }

    /// How hard to work: four at a time when plugged in and cool, fewer as
    /// the Mac warms up, one on battery, none when it's hot.
    private static var parallelism: Int {
        if PowerMonitor.isOnBattery { return 1 }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 4
        case .fair: return 2
        default: return 1
        }
    }

    private static var tooHot: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    /// Nobody has touched the keyboard, mouse or trackpad for two minutes.
    /// Asked when work is about to start, never polled.
    static var macIsIdle: Bool {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) >= 120
    }

    // MARK: - The work

    /// When search last did anything; indexing waits for it. A timestamp, so
    /// nothing has to clear it.
    static var lastSearchActivity = Date.distantPast

    /// How long after the last search keystroke to stay out of the way.
    private static let quietPeriod: TimeInterval = 20

    private static var searchIsBusy: Bool {
        lastSearchActivity.timeIntervalSinceNow > -quietPeriod
    }

    private func pass() async {
        guard !running, !Self.searchIsBusy, !Self.tooHot else { return }
        // On battery: text layers only, no OCR or vectors. Plugged in: everything.
        let onBattery = PowerMonitor.isOnBattery
        running = true
        defer { running = false }
        if onBattery {
            let light = await gather(limit: 30, includeImages: false)
            if !light.isEmpty {
                _ = await extractor.texts(for: light, parallel: 1)
                await extractor.trim(to: 0)
                ActivityLog.write(.search, "indexer (battery): read \(light.count) documents")
            }
            await pictureBacklogOnBattery()
            startIdleWork()
            return
        }

        // Bring the v2 index (name + title + text) up to date with what the
        // store already holds — a few hundred documents per step, yielding
        // between steps, so the first run after an update never stalls anything.
        while !(await ContentStore.shared.migrateStep()) {
            guard !PowerMonitor.isOnBattery, !Self.searchIsBusy else {
                ActivityLog.write(.search, "indexer: index upgrade paused")
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let defaults = UserDefaults.standard
        // Plugged in and nobody searching: read more per pass, so every
        // document in the usual folders is read within a few passes rather
        // than a few days. (The 500 newest are read first, once.)
        let limit = defaults.bool(forKey: Self.backfilledKey) ? batchLimit * 4 : backfillLimit

        let candidates = await gather(limit: limit)
        guard !candidates.isEmpty else {
            defaults.set(true, forKey: Self.backfilledKey)
            await embedBacklog()
            startIdleWork()
            return
        }

        // Batches of 16, yielding between them.
        for start in stride(from: 0, to: candidates.count, by: 16) {
            // Rechecked per batch, not just at the start: the backfill runs for
            // minutes, and a search opened partway through shouldn't have to
            // wait it out — nor should a Mac that's getting warm.
            guard !PowerMonitor.isOnBattery, !Self.searchIsBusy, !Self.tooHot else { break }
            let slice = Array(candidates[start..<min(start + 16, candidates.count)])
            // The extraction itself writes to the store; the return value is
            // only interesting to a search.
            _ = await extractor.texts(for: slice, parallel: Self.parallelism)
            await extractor.trim(to: 0)
            // A breath between batches — short when cool, longer when warm.
            let pause: UInt64 = ProcessInfo.processInfo.thermalState == .nominal ? 50_000_000 : 400_000_000
            try? await Task.sleep(nanoseconds: pause)
        }

        defaults.set(true, forKey: Self.backfilledKey)
        ActivityLog.write(.search, "indexer: read \(candidates.count) files")
        if candidates.contains(where: \.isImage) {
            ActivityLog.write(.search, "indexer: \(await ContentStore.shared.picturesLeft()) pictures left")
        }
        await embedBacklog()
        startIdleWork()

        // More waiting (the pass filled its quota): go again in half a minute
        // rather than ten, while plugged in and cool, until caught up. The
        // first catch-up takes minutes instead of hours.
        if candidates.count >= limit, !PowerMonitor.isOnBattery, !Self.tooHot {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.pass()
            }
        }
    }

    /// The picture backlog on battery: idle and cool only, a few at a time.
    private func pictureBacklogOnBattery() async {
        guard Self.macIsIdle, !Self.tooHot else { return }
        let pictures = await gather(limit: 16).filter(\.isImage)
        guard !pictures.isEmpty else { return }
        var read = 0
        for picture in pictures {
            guard Self.macIsIdle, !Self.tooHot, !Self.searchIsBusy else { break }
            _ = await extractor.texts(for: [picture], parallel: 1)
            read += 1
        }
        await extractor.trim(to: 0)
        let left = await ContentStore.shared.picturesLeft()
        ActivityLog.write(.search, "indexer (battery): read \(read) pictures, \(left) pictures left")
        // More waiting and still idle: another small batch in a minute
        // rather than ten.
        if left > 0, read == pictures.count {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.pass()
            }
        }
    }

    // MARK: - Idle work: photo vectors, then captions

    private var vectoring = false

    /// Photo vectors first (also while in use), then captions (idle only).
    private func startIdleWork() {
        guard !vectoring, !Self.tooHot, !captions.isRunning, !DocumentNotes.shared.isRunning else { return }
        vectoring = true
        Task { [weak self] in
            guard let self else { return }
            let finished = await self.photoVectorBacklog()
            self.vectoring = false
            guard finished else { return }
            // Space a migration freed, given back once while nobody's using the Mac.
            if Self.macIsIdle { await ContentStore.shared.vacuumIfPending() }
            // Documents described before photos captioned: files come first.
            if await DocumentNotes.shared.hasWork() {
                DocumentNotes.shared.startIfIdle()
            } else {
                self.captions.startIfIdle()
            }
        }
    }

    /// Embeds photos without a current vector, newest first; stops for heat or
    /// search. True when none are left. The model downloads only on power.
    private func photoVectorBacklog() async -> Bool {
        let vectors = PhotoVectors.shared
        if !(await vectors.isDownloaded) {
            guard !PowerMonitor.isOnBattery, await vectors.download() else { return false }
        }
        await vectors.dropSmall()
        let pending = await vectors.pending(from: await ContentStore.shared.pictureFiles())
        guard !pending.isEmpty else { return true }
        var done = 0
        var logged = 0
        var started = Date()
        defer { Task { await vectors.unloadModels() } }
        for start in stride(from: 0, to: pending.count, by: 32) {
            guard !Self.tooHot, !Self.searchIsBusy, !captions.isRunning, !DocumentNotes.shared.isRunning else { break }
            // In use: a breather between batches, so the Neural Engine and
            // disk are never busy for long at a stretch.
            if !Self.macIsIdle { try? await Task.sleep(nanoseconds: 300_000_000) }
            for photo in pending[start ..< min(start + 32, pending.count)] {
                guard await vectors.embed(path: photo.path, modified: photo.modified) else { return false }
                done += 1
            }
            if done - logged >= 256 || done == pending.count {
                let each = Date().timeIntervalSince(started) * 1000 / Double(done - logged)
                ActivityLog.write(.search, String(format: "photo vectors: wrote %ld (%ld left), %.0f ms each",
                                                  done - logged, pending.count - done, each))
                logged = done
                started = Date()
            }
        }
        if done > logged {
            ActivityLog.write(.search, "photo vectors: wrote \(done - logged) (\(pending.count - done) left), stopped")
        }
        return done == pending.count
    }

    /// Embeds stored documents the semantic index doesn't hold yet, bounded.
    private func embedBacklog(limit: Int = 200) async {
        guard await SemanticIndex.shared.isAvailable() else { return }
        var after: Int64 = 0
        var embedded = 0
        while embedded < limit {
            guard !PowerMonitor.isOnBattery, !Self.searchIsBusy else { return }
            let rows = await ContentStore.shared.rows(after: after, limit: 100)
            guard let last = rows.last else { return }
            after = last.id
            for row in rows where embedded < limit {
                if await SemanticIndex.shared.add(path: row.path, modified: row.modified,
                                                  title: row.title, text: row.text) {
                    embedded += 1
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Documents in the usual folders the store doesn't hold, newest first.
    private func gather(limit: Int, includeImages: Bool = true) async -> [Candidate] {
        let found = await DirectScan.inventory(of: DirectScan.commonFolders,
                                               kinds: DirectScan.readableKinds.union(DirectScan.codeKinds),
                                               within: DirectScan.sweepBudget)
        // Every file seen goes into the name index, read or not.
        await ContentStore.shared.recordFiles(found.map { ($0.url.path, $0.modified, nil) })
        await ContentStore.shared.removeVanished(seen: Set(found.map(\.url.path)))

        // Ask the store before reading; documents before images, newest first.
        let ordered = found.filter { !$0.isImage } + (includeImages ? found.filter(\.isImage) : [])
        var wanted: [Candidate] = []
        for candidate in ordered {
            guard wanted.count < limit else { break }
            let current = await ContentStore.shared.isCurrent(path: candidate.url.path,
                                                              modified: candidate.modified)
            if !current { wanted.append(candidate) }
        }
        return wanted
    }
}
