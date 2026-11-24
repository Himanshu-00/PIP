import AppKit

/// Tidies a download, with your say-so: a better name from its title, the
/// folder where three or more similar files live, or "it's a copy". Nothing
/// moves without a click.
@MainActor
final class FileTidy: ObservableObject {

    struct Suggestion: Equatable {
        let file: URL
        /// The new name with its extension, when the current one is meaningless.
        let newName: String?
        /// The folder files like this one live in.
        let folder: URL?
        /// An identical file that's already filed.
        let duplicateOf: URL?
    }

    /// What the last tidy did, so it can be undone.
    struct Done: Equatable {
        let original: URL
        let now: URL
        /// Its `UndoLog` entry, so Pip's "undo" puts it back too, after a restart.
        var undoID: UUID?
    }

    /// Set by AppDelegate from "Suggest Where Downloads Go".
    var suggestsFolders = true

    /// Installers and disk images: opened once and deleted, never filed.
    private static let neverFiled: Set<String> = ["dmg", "pkg", "mpkg", "iso", "app"]

    @Published private(set) var suggestion: Suggestion?
    @Published private(set) var done: Done?

    private let extractor = TextExtractor()

    // MARK: - Working it out

    func prepare(for file: URL) async {
        done = nil
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let candidate = Candidate(url: file, displayName: file.lastPathComponent,
                                  modified: values?.contentModificationDate, lastOpened: nil,
                                  useCount: 0, whereFrom: nil)
        let extracted = await extractor.texts(for: [candidate])[file]

        // A better name: only for a meaningless one, only from a real title.
        var newName: String?
        if Self.isMeaningless(file.deletingPathExtension().lastPathComponent),
           let title = extracted?.title.flatMap(Self.cleanTitle) {
            newName = file.pathExtension.isEmpty ? title : title + "." + file.pathExtension.lowercased()
        }

        // Where files like it live.
        var folder: URL?
        if suggestsFolders, !Self.neverFiled.contains(file.pathExtension.lowercased()) {
            let words = Self.queryWords(title: extracted?.title, text: extracted?.text ?? "")
            folder = await Self.likelyFolder(for: file, contentQuery: words.joined(separator: " "))
        }

        // A copy of something already filed?
        let duplicate = Self.identicalFile(to: file, size: values?.fileSize, near: folder)

        guard newName != nil || folder != nil || duplicate != nil else {
            suggestion = nil
            return
        }
        suggestion = Suggestion(file: file, newName: newName, folder: folder, duplicateOf: duplicate)
        ActivityLog.write(.system, "tidy: \(file.lastPathComponent) → name \(newName ?? "-"), "
                          + "folder \(folder?.lastPathComponent ?? "-"), copy of \(duplicate?.lastPathComponent ?? "-")")
    }

    // MARK: - Doing it

    /// Renames and/or moves, as suggested. Returns one line for the notch.
    @discardableResult
    func apply() -> String? {
        guard let suggestion, FileManager.default.fileExists(atPath: suggestion.file.path) else { return nil }
        var current = suggestion.file
        if let name = suggestion.newName {
            let (message, renamed) = DailyTools.rename(current, to: name)
            guard let renamed else { return message }
            current = renamed
        }
        if let folder = suggestion.folder {
            let (message, moved) = DailyTools.move(current, to: folder.path)
            guard let moved else { return message }
            current = moved
        }
        let undoID = UndoLog.record("Filed \(suggestion.file.lastPathComponent) in \(current.deletingLastPathComponent().lastPathComponent)",
                                    moves: [(suggestion.file, current)])
        done = Done(original: suggestion.file, now: current, undoID: undoID)
        self.suggestion = nil
        ActivityLog.write(.system, "tidy: \(suggestion.file.lastPathComponent) → \(current.path)")
        return "Filed as \(current.lastPathComponent)"
    }

    /// Moves a duplicate download to the Trash (recoverable).
    func trashCopy() {
        guard let suggestion, suggestion.duplicateOf != nil else { return }
        _ = DailyTools.trash(suggestion.file)
        ActivityLog.write(.system, "tidy: trashed duplicate \(suggestion.file.lastPathComponent)")
        self.suggestion = nil
    }

    /// Puts the last tidied file back where and as it was.
    func undo() {
        guard let done else { return }
        if let id = done.undoID {
            _ = UndoLog.undo(id: id)
        } else if !FileManager.default.fileExists(atPath: done.original.path) {
            try? FileManager.default.moveItem(at: done.now, to: done.original)
        }
        ActivityLog.write(.system, "tidy: undone for \(done.original.lastPathComponent)")
        self.done = nil
    }

    func dismiss() {
        suggestion = nil
        done = nil
    }

    // MARK: - Names

    /// Names that say nothing about the file: arXiv ids and dates, camera and
    /// scanner names, uuids, "document (3)".
    static func isMeaningless(_ stem: String) -> Bool {
        let name = stem.lowercased().trimmingCharacters(in: .whitespaces)
        let patterns = [
            #"^[0-9][0-9._\- v]*$"#,
            #"^(img|dsc|dscn|pxl|photo|image|scan|scanned|document|doc|file|download|untitled|attachment)[ _\-]?[0-9a-f _\-()]*$"#,
            #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"#,
        ]
        return patterns.contains { name.range(of: $0, options: .regularExpression) != nil }
    }

    /// A title as a file name: no slashes or colons, single spaces, at most
    /// about 80 characters cut at a word. Nil if it doesn't read like a title.
    static func cleanTitle(_ title: String) -> String? {
        var text = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,;-"))
        let words = text.split(separator: " ")
        let letters = text.filter(\.isLetter).count
        guard words.count >= 2, words.count <= 16, letters * 2 >= text.count else { return nil }
        if text.count > 80 {
            var cut = ""
            for word in words where cut.count + word.count + 1 <= 80 { cut += (cut.isEmpty ? "" : " ") + word }
            text = cut
        }
        return text.isEmpty ? nil : text
    }

    // MARK: - Folders

    /// Words to find files like this one: its title, else the words its
    /// text uses most (a picture's labels line left out — "document" and
    /// "text" describe every scan).
    private static func queryWords(title: String?, text: String) -> [String] {
        if let title, let clean = cleanTitle(title) {
            return Array(Tokens.of(clean).filter { $0.count >= 3 }.prefix(8))
        }
        let body = text.hasPrefix("Picture of:")
            ? String(text.drop { $0 != "\n" })
            : text
        var counts: [String: Int] = [:]
        for word in Tokens.of(String(body.prefix(2_000))) where word.count >= 4 && !word.allSatisfy(\.isNumber) {
            counts[word, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(6).map(\.key)
    }

    /// The folder files like this live in, when three or more agree (loose
    /// places don't count).
    private static func likelyFolder(for file: URL, contentQuery: String) async -> URL? {
        let home = NSHomeDirectory()
        let loose: Set<String> = [home + "/Downloads", home + "/Desktop", home + "/Documents", home,
                                  file.deletingLastPathComponent().path]
        let kind = file.pathExtension.lowercased()
        var votes: [String: Set<String>] = [:]      // folder → the files that put it there
        func vote(_ url: URL) {
            let parent = url.deletingLastPathComponent().path
            guard url != file, url.pathExtension.lowercased() == kind, !loose.contains(parent),
                  !parent.hasPrefix(home + "/Downloads/"), !DirectScan.isExcluded(url.path) else { return }
            votes[parent, default: []].insert(url.path)
        }

        // a. Similar content: the engine, searching by the file's title or words.
        var content = 0
        if !contentQuery.isEmpty {
            let ranked = await SearchController.forTidy.find(contentQuery)
            if let best = ranked.first?.score, best > 0 {
                for candidate in ranked.prefix(12) where candidate.score >= best * 0.5 {
                    vote(candidate.url); content += 1
                }
            }
        }
        // b. A similar name: the engine again, by the name's own words.
        var named = 0
        let nameWords = Tokens.of(file.deletingPathExtension().lastPathComponent).filter { $0.count >= 3 || $0.contains(where: \.isNumber) }
        if !nameWords.isEmpty, !isMeaningless(file.deletingPathExtension().lastPathComponent) {
            for candidate in await SearchController.forTidy.find(nameWords.joined(separator: " ")).prefix(12)
            where candidate.features.nameMatch >= 0.6 {
                vote(candidate.url); named += 1
            }
        }
        // c. The same site: earlier downloads from it, wherever they went.
        var site = 0
        if let domain = downloadDomain(of: file) {
            let found = await Task.detached(priority: .utility) {
                ScriptBridge.run("/usr/bin/mdfind", ["-onlyin", home, "kMDItemWhereFroms == \"*\(domain)*\"cd"], timeout: 3)
            }.value
            for path in found.output.split(separator: "\n").prefix(200) {
                vote(URL(fileURLWithPath: String(path))); site += 1
            }
        }

        let top = votes.max { $0.value.count < $1.value.count }
        ActivityLog.write(.system, "tidy: \(file.lastPathComponent) — content \(content), name \(named), site \(site); "
                          + "best \(top.map { "\(URL(fileURLWithPath: $0.key).lastPathComponent) (\($0.value.count))" } ?? "none")")
        guard let top, top.value.count >= 3 else { return nil }
        return URL(fileURLWithPath: top.key, isDirectory: true)
    }

    /// The host a download came from ("moodle.example.edu"), from the
    /// address macOS records; the page it was linked from when the file's
    /// own address is a CDN's. Nil for files that weren't downloaded.
    private static func downloadDomain(of file: URL) -> String? {
        guard let sources = DirectScan.whereFrom(file) else { return nil }
        let hosts = sources.split(separator: " ").compactMap { URL(string: String($0))?.host?.lowercased() }
        guard let host = hosts.last ?? hosts.first, host.contains(".") else { return nil }
        // Quotes would break the query; hosts never contain them anyway.
        return host.replacingOccurrences(of: "\"", with: "")
    }

    // MARK: - Copies

    /// An identical file already in the suggested folder or elsewhere in
    /// Downloads: same extension, same size, same bytes.
    private static func identicalFile(to file: URL, size: Int?, near folder: URL?) -> URL? {
        guard let size, size > 0 else { return nil }
        let manager = FileManager.default
        var places = [file.deletingLastPathComponent()]
        if let folder { places.append(folder) }
        for place in places {
            let entries = (try? manager.contentsOfDirectory(at: place, includingPropertiesForKeys: [.fileSizeKey],
                                                            options: [.skipsHiddenFiles])) ?? []
            for other in entries where other != file
                && other.pathExtension.lowercased() == file.pathExtension.lowercased()
                && (try? other.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == size
                && manager.contentsEqual(atPath: other.path, andPath: file.path) {
                return other
            }
        }
        return nil
    }
}
