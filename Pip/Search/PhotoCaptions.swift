import AppKit
import CoreServices
import ImageIO

/// Keywords per photo from Pip's own vision, written only while the Mac is
/// idle, plugged in and cool; stops at once on any input. Saved as the first
/// line of the photo's text, so search finds it unchanged.
@MainActor
final class PhotoCaptions {

    /// Pip is thinking, listening or speaking (set by `AppDelegate`).
    var pipInUse: () -> Bool = { false }

    private var task: Task<Void, Never>?
    /// A batch is being written (photo vectors wait for it).
    var isRunning: Bool { task != nil }
    private var watchers: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// Keywords rather than a sentence: about half the tokens to write, and
    /// a search matches words anyway.
    private static let question = "List 8-12 comma-separated search keywords for this photo: people "
        + "(no names), clothing with colours, objects, colours, setting. Name clothing precisely (kurta, "
        + "saree, suit, hoodie, t-shirt, dress)."
    private static let system = "You describe the user's photos so they can find them by searching. "
        + "Reply with keywords only."

    private var canWork: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return !PowerMonitor.isOnBattery && ContentIndexer.macIsIdle
            && (thermal == .nominal || thermal == .fair) && !pipInUse()
    }

    /// Called by the indexer after a pass; does nothing unless it's a good time.
    func startIfIdle() {
        guard task == nil, LocalBrain.isDownloaded, LocalBrain.shared.canSee, canWork else { return }
        // Watch for anything that should stop it — only while it runs.
        let input: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
                                            .keyDown, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: input, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }) { watchers.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: input, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.stop() }
            return event
        }) { watchers.append(local) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.canWork == false { self?.stop() } }
        })
        task = Task { [weak self] in await self?.run() }
    }

    /// Stops at once. `forPip`: Pip is about to use the brain, so it stays loaded.
    func stop(forPip: Bool = false) {
        guard let task else { return }
        task.cancel()
        self.task = nil
        watchers.forEach(NSEvent.removeMonitor)
        watchers.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if !forPip { Task { await LocalBrain.shared.unload() } }
    }

    private func run() async {
        while !Task.isCancelled {
            // ~200 at a time in folder order from the store, then the ones
            // the owner opened most recently first within each folder group.
            let candidates = await ContentStore.shared.uncaptionedPhotos(limit: 200)
            guard !candidates.isEmpty else { break }
            let (ordered, opened) = Self.recentlyOpenedFirst(candidates)
            let next = ordered.prefix(3).map { URL(fileURLWithPath: $0.path).lastPathComponent }
            ActivityLog.write(.search, "captions next: " + next.joined(separator: ", ")
                              + " (\(opened) of \(ordered.count) have a last-opened date)")
            for start in stride(from: 0, to: ordered.count, by: 8) {
                guard await captionBatch(Array(ordered[start ..< min(start + 8, ordered.count)])) else { break }
            }
            guard !Task.isCancelled, canWork else { break }
        }
        if !Task.isCancelled { stop() }
    }

    /// Captions a few photos and logs them; false once it should stop.
    private func captionBatch(_ batch: [(path: String, modified: Date)]) async -> Bool {
        var wrote = 0
        var seconds: [Double] = []
        var stopped = false
        for photo in batch {
            guard !Task.isCancelled, canWork else { stopped = true; break }
            let started = Date()
            let caption = await Self.caption(of: URL(fileURLWithPath: photo.path))
            // Cancelled mid-sentence: the half-written one is not kept.
            guard !Task.isCancelled, let caption else { stopped = true; break }
            guard let saved = await ContentStore.shared.setCaption(path: photo.path, modified: photo.modified,
                                                                     caption: caption) else { continue }
            if !caption.isEmpty {
                await SemanticIndex.shared.add(path: photo.path, modified: photo.modified,
                                               title: saved.title, text: saved.text, replace: true)
                wrote += 1
                seconds.append(Date().timeIntervalSince(started))
            }
        }
        let left = await ContentStore.shared.uncaptionedCount()
        let each = seconds.isEmpty ? "" : String(format: ", %.1f s each", seconds.reduce(0, +) / Double(seconds.count))
        ActivityLog.write(.search, "captions: wrote \(wrote) (\(left) left)\(each)")
        return !stopped
    }

    /// The store's order (Desktop and Downloads, Documents, Pictures; screenshots
    /// last in each) with the photos opened most recently first inside each group.
    private static func recentlyOpenedFirst(_ photos: [(path: String, modified: Date)])
        -> (photos: [(path: String, modified: Date)], opened: Int) {
        let home = NSHomeDirectory()
        func group(_ path: String) -> Int {
            if path.hasPrefix(home + "/Desktop/") || path.hasPrefix(home + "/Downloads/") { return 0 }
            return path.hasPrefix(home + "/Documents/") ? 1 : 2
        }
        func isScreenshot(_ path: String) -> Bool {
            let name = (path as NSString).lastPathComponent.lowercased()
            return name.hasPrefix("screenshot") || name.hasPrefix("screen shot") || name.hasPrefix("cleanshot")
        }
        let keyed = photos.map { photo in
            let opened = lastOpened(photo.path)
            return (photo: photo, group: group(photo.path), screenshot: isScreenshot(photo.path),
                    known: opened != nil, date: opened ?? photo.modified)
        }
        let sorted = keyed.sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            if $0.screenshot != $1.screenshot { return !$0.screenshot }
            return $0.date > $1.date
        }
        return (sorted.map(\.photo), keyed.filter(\.known).count)
    }

    /// Spotlight's "last opened" date (not the access date the indexer sets).
    private static func lastOpened(_ path: String) -> Date? {
        guard let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Keywords for the photo at `url`; "" for an image too small or
    /// broken to say anything about (so it isn't tried again); nil if the
    /// brain failed.
    static func caption(of url: URL) async -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return "" }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard max(width, height) >= 200 else { return "" }
        // ~336 px on the long side (~144 image tokens: enough for colours,
        // clothes and objects), the right way up.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 336]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return "" }
        guard let answer = try? await LocalBrain.shared.look(at: image, question: question, maxTokens: 256,
                                                             system: system, answerLimit: 24, greedy: true,
                                                             cachePrompt: true) else { return nil }
        return tidy(answer)
    }

    /// The first line as keywords: no quotes, no dangling comma (24 tokens
    /// often stop mid-list), and not the question's own headings echoed back
    /// ("people, clothing, objects…" came back once as the whole answer).
    private static func tidy(_ answer: String) -> String {
        let line = answer.split(separator: "\n").first.map(String.init) ?? ""
        let echoes: Set<String> = ["people", "clothing", "objects", "colours", "colors", "setting"]
        let keywords = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ."))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !echoes.contains($0.lowercased()) }
        return keywords.joined(separator: ", ")
    }
}
