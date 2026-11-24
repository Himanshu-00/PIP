import AppKit

/// Offers to move screenshots over a week old (15 or more) to Pictures ▸
/// Screenshots, with Undo; asks at most weekly. Spotlight's screenshot flag
/// decides what counts. Design notes: Docs/history/Sensors.md.
@MainActor
final class ScreenshotTidy: ObservableObject {

    struct Offer: Equatable {
        let files: [URL]
        let from: URL
        let to: URL
    }

    struct Done: Equatable {
        /// Where each one was, and where it is now.
        let moves: [(from: URL, to: URL)]
        let folder: URL
        /// Its entry in the UndoLog.
        let logID: UUID?
        static func == (a: Done, b: Done) -> Bool { a.folder == b.folder && a.moves.map(\.to) == b.moves.map(\.to) }
    }

    @Published private(set) var offer: Offer?
    @Published private(set) var done: Done?

    private static let askedKey = "screenshotTidyAsked"
    private static let minimumCount = 15
    private static let olderThanDays = 7

    /// Looks, unless it asked within the last week.
    func check() {
        guard offer == nil, done == nil else { return }
        if let asked = UserDefaults.standard.object(forKey: Self.askedKey) as? Date,
           Date().timeIntervalSince(asked) < 7 * 86_400 { return }
        let from = ScreenshotShelf.saveLocation()
        let to = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Screenshots", isDirectory: true)
        guard from.standardizedFileURL != to.standardizedFileURL else { return }
        Task {
            let query = "kMDItemIsScreenCapture == 1 && kMDItemContentCreationDate < $time.today(-\(Self.olderThanDays))"
            let output = await Task.detached(priority: .utility) {
                ScriptBridge.run("/usr/bin/mdfind", ["-onlyin", from.path, query], timeout: 6).output
            }.value
            // Only what's directly in the folder, not screenshots filed below it.
            let files = output.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
                .filter { $0.deletingLastPathComponent().standardizedFileURL == from.standardizedFileURL }
            guard files.count >= Self.minimumCount, self.offer == nil, self.done == nil else { return }
            self.offer = Offer(files: files, from: from, to: to)
            ActivityLog.write(.system, "screenshots: offering to move \(files.count) from \(from.lastPathComponent)")
        }
    }

    func apply() {
        guard let offer else { return }
        self.offer = nil
        let manager = FileManager.default
        try? manager.createDirectory(at: offer.to, withIntermediateDirectories: true)
        var moves: [(URL, URL)] = []
        for file in offer.files where manager.fileExists(atPath: file.path) {
            var target = offer.to.appendingPathComponent(file.lastPathComponent)
            var counter = 2
            while manager.fileExists(atPath: target.path) {
                let stem = file.deletingPathExtension().lastPathComponent
                target = offer.to.appendingPathComponent("\(stem) \(counter).\(file.pathExtension)")
                counter += 1
            }
            if (try? manager.moveItem(at: file, to: target)) != nil { moves.append((file, target)) }
        }
        let id = UndoLog.record("Moved \(moves.count) screenshots off the \(offer.from.lastPathComponent)", moves: moves)
        done = Done(moves: moves, folder: offer.to, logID: id)
        UserDefaults.standard.set(Date(), forKey: Self.askedKey)
        ActivityLog.write(.system, "screenshots: moved \(moves.count) to \(offer.to.path)")
    }

    func undo() {
        guard let done else { return }
        if let id = done.logID {
            _ = UndoLog.undo(id: id)
        } else {
            for move in done.moves where !FileManager.default.fileExists(atPath: move.from.path) {
                try? FileManager.default.moveItem(at: move.to, to: move.from)
            }
        }
        self.done = nil
        ActivityLog.write(.system, "screenshots: put \(done.moves.count) back")
    }

    /// "Not now", or the Undo row's time is up.
    func dismiss() {
        if offer != nil { UserDefaults.standard.set(Date(), forKey: Self.askedKey) }
        offer = nil
        done = nil
    }
}
