import AppKit
import CryptoKit

/// Recent files, duplicates, better names and organising a folder, for Pip's
/// tools; each shows the files and asks first. No language model.
enum FileCare {

    // MARK: - What was I working on

    /// Files opened or changed inside `window`, newest first: Spotlight's
    /// last-used and content-changed dates, across the home folder (or one
    /// folder), leaving out Library, hidden folders and app bundles.
    static func recent(in window: QueryTime.Window, folder: URL?, limit: Int = 12) async -> [URL] {
        let iso = ISO8601DateFormatter()
        let (start, end) = (iso.string(from: window.start), iso.string(from: window.end))
        let query = "(kMDItemLastUsedDate >= $time.iso(\(start)) && kMDItemLastUsedDate <= $time.iso(\(end)))"
            + " || (kMDItemFSContentChangeDate >= $time.iso(\(start)) && kMDItemFSContentChangeDate <= $time.iso(\(end)))"
        let scope = folder?.path ?? NSHomeDirectory()
        let output = await Task.detached(priority: .userInitiated) {
            ScriptBridge.run("/usr/bin/mdfind", ["-onlyin", scope, query], timeout: 6).output
        }.value
        let skip = ["/Library/", "/.", ".app/", "/node_modules/", "/DerivedData/", "/.build/"]
        let files = output.split(separator: "\n").map(String.init)
            .filter { path in !skip.contains { path.contains($0) } }
            .map { URL(fileURLWithPath: $0) }
            .filter { !$0.hasDirectoryPath && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        func touched(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey])
            return max(values?.contentModificationDate ?? .distantPast, values?.contentAccessDate ?? .distantPast)
        }
        return Array(files.sorted { touched($0) > touched($1) }.prefix(limit))
    }

    // MARK: - Copies

    /// Sets of byte-for-byte identical files in a folder (and its folders,
    /// two levels down), the one to keep first: the plainest name ("report"
    /// over "report (1)" or "report copy"), then the oldest.
    static func duplicates(in folder: URL) async -> [[URL]] {
        await Task.detached(priority: .userInitiated) { () -> [[URL]] in
            var bySize: [Int: [URL]] = [:]
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return [] }
            var seen = 0
            for case let url as URL in walker {
                if walker.level > 3 { walker.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let size = values.fileSize, size > 0 else { continue }
                bySize[size, default: []].append(url)
                seen += 1
                if seen >= 5_000 { break }
            }
            var sets: [[URL]] = []
            for group in bySize.values where group.count > 1 {
                var byHash: [String: [URL]] = [:]
                for url in group {
                    if let hash = digest(url) { byHash[hash, default: []].append(url) }
                }
                sets += byHash.values.filter { $0.count > 1 }.map(keepFirst)
            }
            return sets.sorted { $0[0].lastPathComponent < $1[0].lastPathComponent }
        }.value
    }

    private static func digest(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func keepFirst(_ copies: [URL]) -> [URL] {
        func copyMarks(_ url: URL) -> Int {
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            var marks = 0
            if stem.range(of: #"\s\(\d+\)$|-\d+$|_\d+$"#, options: .regularExpression) != nil { marks += 1 }
            if stem.hasSuffix(" copy") || stem.contains(" copy ") { marks += 1 }
            return marks
        }
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
        }
        return copies.sorted {
            (copyMarks($0), created($0)) < (copyMarks($1), created($1))
        }
    }

    // MARK: - Names

    /// Better names for files whose name says nothing (title, or what a picture
    /// shows and when), at most `limit`.
    @MainActor static func nameSuggestions(in folder: URL, limit: Int = 20) async -> [(file: URL, name: String)] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let vague = contents.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && FileTidy.isMeaningless($0.deletingPathExtension().lastPathComponent)
        }.prefix(limit * 2)

        let pictures = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"]
        let extractor = TextExtractor()
        var taken = Set(contents.map { $0.lastPathComponent.lowercased() })
        var suggestions: [(URL, String)] = []
        for file in vague {
            guard suggestions.count < limit else { break }
            let ext = file.pathExtension
            var stem: String?
            if pictures.contains(ext.lowercased()) {
                stem = await pictureName(file)
            } else {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                let candidate = Candidate(url: file, displayName: file.lastPathComponent,
                                          modified: values?.contentModificationDate, lastOpened: nil,
                                          useCount: 0, whereFrom: nil)
                stem = await extractor.texts(for: [candidate])[file]?.title.flatMap(FileTidy.cleanTitle)
            }
            guard var name = stem.map({ ext.isEmpty ? $0 : "\($0).\(ext)" }) else { continue }
            // Never two the same, nor one that's already there.
            var counter = 2
            while taken.contains(name.lowercased()), let base = stem {
                name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                counter += 1
            }
            taken.insert(name.lowercased())
            suggestions.append((file, name))
        }
        return suggestions
    }

    /// "Beach – 12 Mar 2026": the classifier's first concrete label and the
    /// day the picture was made. Nil when it sees nothing nameable.
    private static func pictureName(_ file: URL) async -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 800,
              ] as CFDictionary) else { return nil }
        let (labels, _) = await TextExtractor.describe(image)
        // Broad words name nothing: every outdoor photo is "outdoor".
        let broad: Set<String> = ["outdoor", "indoor", "structure", "people", "person", "adult", "group",
                                  "screenshot", "screen", "document", "paper", "machine", "art", "illustrations"]
        guard let label = labels.first(where: { !broad.contains($0) }) ?? labels.first else { return nil }
        let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let day = date.formatted(.dateTime.day().month(.abbreviated).year())
        return label.prefix(1).uppercased() + label.dropFirst() + " – " + day
    }

    // MARK: - Organising a folder

    /// Where each loose file in a folder would go, grouped. Subfolders and
    /// files still downloading stay where they are.
    struct Plan {
        let folder: URL
        let groups: [(name: String, files: [URL])]
        var count: Int { groups.reduce(0) { $0 + $1.files.count } }
    }

    /// Documents go into folders named from what Pip says they are: each one
    /// is described (`DocumentNotes`), similar descriptions are grouped
    /// (`ResultGroups`) and each group is named from the words they share.
    /// Everything else, and documents that fit no group, go by kind.
    @MainActor static func organizePlan(for folder: URL, limit: Int = 1_000) async -> Plan {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true }
            .filter { !["crdownload", "part", "download", "partial"].contains($0.pathExtension.lowercased()) }
            .prefix(limit)

        let screenshots = await Task.detached(priority: .userInitiated) {
            Set(ScriptBridge.run("/usr/bin/mdfind", ["-onlyin", folder.path, "kMDItemIsScreenCapture == 1"],
                                 timeout: 6).output.split(separator: "\n").map(String.init))
        }.value

        var chosen: [URL: String] = [:]
        for file in files { chosen[file] = screenshots.contains(file.path) ? "Screenshots" : kind(of: file) }
        let documents = files.filter { ["Documents", "Slides", "Spreadsheets"].contains(chosen[$0]) }

        // Documents the search index hasn't read are read now (at most 40, so
        // a huge folder doesn't take minutes), then described (at most 15,
        // about 4 s each); the rest group by what they already have.
        var unread: [Candidate] = []
        for file in documents where unread.count < 40 {
            guard await ContentStore.shared.record(path: file.path, modified: nil, anyDate: true) == nil else { continue }
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            unread.append(Candidate(url: file, displayName: file.lastPathComponent, modified: modified,
                                    lastOpened: nil, useCount: 0, whereFrom: nil))
        }
        for (url, extracted) in await TextExtractor().texts(for: unread) {
            let modified = unread.first { $0.url == url }?.modified
            await ContentStore.shared.store(path: url.path, modified: modified, title: extracted.title,
                                            text: extracted.text)
        }
        _ = await DocumentNotes.shared.describeAll(documents.map(\.path), limit: 15)

        for group in await ResultGroups.group(Array(documents), query: "", minGroups: 1) ?? [] where group.named {
            let name = group.name.replacingOccurrences(of: #"[/:]"#, with: "-", options: .regularExpression)
            for file in group.urls { chosen[file] = name }
        }
        let grouped = Dictionary(grouping: chosen.filter { $0.value != "Other" }, by: \.value)
            .map { (name: $0.key, files: $0.value.map(\.key).sorted { $0.lastPathComponent < $1.lastPathComponent }) }
            .sorted { $0.files.count > $1.files.count }
        return Plan(folder: folder, groups: grouped)
    }

    /// Moves everything as planned, into folders made as needed (one that
    /// exists with the name is used). Recorded in the UndoLog.
    @MainActor static func apply(_ plan: Plan) -> Int {
        let manager = FileManager.default
        var moves: [(URL, URL)] = []
        for group in plan.groups {
            let destination = plan.folder.appendingPathComponent(group.name, isDirectory: true)
            try? manager.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in group.files where manager.fileExists(atPath: file.path) {
                var target = destination.appendingPathComponent(file.lastPathComponent)
                var counter = 2
                while manager.fileExists(atPath: target.path) {
                    let stem = file.deletingPathExtension().lastPathComponent
                    let ext = file.pathExtension
                    target = destination.appendingPathComponent(ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)")
                    counter += 1
                }
                if (try? manager.moveItem(at: file, to: target)) != nil { moves.append((file, target)) }
            }
        }
        UndoLog.record("Organised \(plan.folder.lastPathComponent)", moves: moves)
        ActivityLog.write(.system, "organised \(moves.count) files in \(plan.folder.path)")
        return moves.count
    }

    private static func kind(of file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        let kinds: [(String, Set<String>)] = [
            ("Photos", ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "raw", "dng", "svg"]),
            ("Videos", ["mp4", "mov", "m4v", "avi", "mkv", "webm"]),
            ("Audio", ["mp3", "m4a", "wav", "aac", "flac", "aiff"]),
            ("Installers", ["dmg", "pkg", "mpkg"]),
            ("Archives", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
            ("Code", ["swift", "py", "js", "ts", "java", "c", "cpp", "h", "html", "css", "json", "ipynb", "sh", "r", "sql", "yml", "yaml"]),
            ("Slides", ["ppt", "pptx", "key"]),
            ("Spreadsheets", ["xls", "xlsx", "numbers", "csv"]),
            ("Documents", ["pdf", "doc", "docx", "pages", "txt", "md", "rtf", "odt", "epub"]),
        ]
        return kinds.first { $0.1.contains(ext) }?.0 ?? "Other"
    }
}
