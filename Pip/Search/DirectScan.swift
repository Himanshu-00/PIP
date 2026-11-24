import Foundation
import Darwin
import os

/// Walks folders directly for file names: Spotlight's index has holes.
enum DirectScan {

    /// Loop protection only (symlink cycles); breadth-first does the rest.
    private static let maximumDepth = 12

    /// Walks are bounded by time, shared across a whole pass.
    static let keystrokeBudget: TimeInterval = 0.4
    static let sweepBudget: TimeInterval = 2.5

    /// Machine-generated folders nobody searches.
    static let skippedFolders: Set<String> = [
        "node_modules", ".git", "Library", ".Trash", "DerivedData",
        ".build", "build", "Pods", "venv", ".venv", "__pycache__",
        "go", ".cargo", ".npm", ".gradle", ".cache", ".conda", ".nvm",
        "site-packages", "vendor", "dist", "target", ".next", ".pub-cache",
    ]

    /// Paths search never returns, reads or stores: `~/Library`, hidden folders,
    /// and the skipped folders.
    static func isExcluded(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/Library/") { return true }
        let inside = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        let folders = inside.split(separator: "/").dropLast()
        if folders.contains(where: { $0.hasPrefix(".") || skippedFolders.contains(String($0)) }) { return true }
        // Folders marked never-index, inside home.
        guard path.hasPrefix(home + "/") else { return false }
        var folder = home
        for name in folders {
            folder += "/" + name
            if isMarkedNeverIndex(folder) { return true }
        }
        return false
    }

    /// Folders under a `.metadata_never_index` file, cached per session.
    private static let neverIndex = OSAllocatedUnfairLock(initialState: [String: Bool]())

    /// Developer switch: `true` searches marked folders (Pip's own code,
    /// task notes) like any other. Code only, off (it was a menu item until
    /// 2026-11-22).
    static let searchesMarkedFolders = false

    /// Marks a folder never-index (the menu's "Exclude a Folder…"), or
    /// unmarks it; the cache forgets it either way.
    static func setExcluded(_ folder: URL, _ excluded: Bool) {
        let marker = folder.appendingPathComponent(".metadata_never_index")
        if excluded {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
        neverIndex.withLock { $0[folder.path] = nil }
    }

    private static func isMarkedNeverIndex(_ folder: String) -> Bool {
        if searchesMarkedFolders { return false }
        if let known = neverIndex.withLock({ $0[folder] }) { return known }
        let marked = FileManager.default.fileExists(atPath: folder + "/.metadata_never_index")
        neverIndex.withLock { $0[folder] = marked }
        return marked
    }

    private static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "photoslibrary", "xcodeproj",
        "xcworkspace", "rtfd", "playground", "docset"
    ]

    /// Files whose words PDFKit, a text read or OCR can get at (one shared list).
    static let readableKinds: Set<String> = [
        "pdf", "txt", "md", "rtf", "csv", "tsv", "json", "html", "htm",
        "xml", "log", "tex", "srt", "vtt", "docx", "doc", "odt",
        // Slides and spreadsheets.
        "pptx", "xlsx",
        "png", "jpg", "jpeg", "heic", "webp", "tiff",
    ]

    /// Code and notebooks: indexed in the background, not read by a search's sweep.
    static let codeKinds: Set<String> = [
        "py", "ipynb", "swift", "js", "ts", "jsx", "tsx", "java", "kt", "go", "rs", "rb",
        "c", "cpp", "h", "hpp", "m", "cs", "php", "scala", "dart", "sql", "sh", "yaml", "yml", "toml",
    ]

    /// Downloads, Desktop, Documents, Pictures, Movies, plus the screenshot
    /// folder if elsewhere (never `~` itself).
    static var commonFolders: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var folders = ["Downloads", "Desktop", "Documents", "Pictures", "Movies"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        let shots = ScreenshotShelf.saveLocation().standardizedFileURL
        let covered = folders.contains { folder in
            shots.path == folder.path || shots.path.hasPrefix(folder.path + "/")
        }
        if !covered, shots.path != home.standardizedFileURL.path {
            folders.append(shots)
        }
        return folders
    }

    /// Filename matches across several folders at once.
    static func matches(words: [String], in folders: [URL], limit: Int = 200) async -> [Candidate] {
        guard !words.isEmpty, !folders.isEmpty else { return [] }

        // One clock for the whole pass. A per-folder budget would multiply by
        // the number of folders, and what anyone notices is the total.
        let deadline = Date.now.addingTimeInterval(keystrokeBudget)

        var all: [Candidate] = []
        // Serial rather than concurrent: these are all on the same disk, and
        // four enumerators competing for it is slower than one at a time.
        for folder in folders {
            all += await matches(words: words, in: folder, limit: limit, deadline: deadline)
        }
        all.sort { left, right in
            if left.features.nameMatch != right.features.nameMatch {
                return left.features.nameMatch > right.features.nameMatch
            }
            return (left.modified ?? .distantPast) > (right.modified ?? .distantPast)
        }
        return Array(all.prefix(limit))
    }

    /// Every file under `folder` whose name contains any of the words (off main).
    static func matches(words: [String], in folder: URL, limit: Int = 200,
                        deadline: Date? = nil) async -> [Candidate] {
        guard !words.isEmpty else { return [] }
        let stopAt = deadline ?? Date.now.addingTimeInterval(keystrokeBudget)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: walk(words: words, folder: folder,
                                                    limit: limit, deadline: stopAt))
            }
        }
    }

    private static func walk(words: [String], folder: URL, limit: Int,
                             deadline: Date) -> [Candidate] {
        var found: [Candidate] = []
        // A folder named for the query vouches for what's in it: "rent" finds
        // Downloads/Receipts/March.jpg, whose own name says nothing. Worked out
        // once per folder, not per file.
        let named = words.filter { $0.count >= 3 }
        var folderVouches: [String: Bool] = [:]
        traverse(from: folder, deadline: deadline) { url, name, values in
            // Fuzzy rather than substring: the point of walking the disk is to
            // find what Spotlight missed, and a name you only half remember is
            // the other half of that problem.
            var score = Fuzzy.score(words: words, against: name)
            let parent = url.deletingLastPathComponent()
            let vouches: Bool
            if let known = folderVouches[parent.path] {
                vouches = known
            } else {
                let folderName = parent.lastPathComponent
                vouches = named.contains { Fuzzy.score($0, against: folderName) >= 0.9 }
                folderVouches[parent.path] = vouches
            }
            if vouches { score = max(score, 0.7) }
            guard score > 0 else { return }

            var candidate = Candidate(
                url: url,
                displayName: name,
                modified: values.contentModificationDate,
                lastOpened: values.contentAccessDate,
                useCount: 0,
                // Not read here. See `whereFrom` — it's filled in later, for
                // the few candidates that survive rather than the thousands
                // that don't.
                whereFrom: nil
            )
            candidate.features.nameMatch = score
            found.append(candidate)
        }

        found.sort { left, right in
            if left.features.nameMatch != right.features.nameMatch {
                return left.features.nameMatch > right.features.nameMatch
            }
            return (left.modified ?? .distantPast) > (right.modified ?? .distantPast)
        }
        return Array(found.prefix(limit))
    }

    /// Breadth-first, bounded only by the clock, so shallow files come first.
    private static func traverse(from root: URL, deadline: Date,
                                 onFile: (URL, String, URLResourceValues) -> Void) {
        // `contentAccessDate` comes from the file system, unlike Spotlight's use count.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey,
                                         .nameKey, .fileSizeKey, .contentAccessDateKey]
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var head = 0

        while head < queue.count {
            // Checked per directory rather than per file: `Date.now` is cheap
            // but not free, and a directory is a natural unit to abandon on.
            guard Date.now < deadline else { return }

            let (directory, depth) = queue[head]
            head += 1
            guard depth <= maximumDepth else { continue }

            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
            else { continue }

            for url in entries {
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                let name = values.name ?? url.lastPathComponent

                if values.isDirectory == true {
                    // Prune whole subtrees rather than filtering their contents
                    // one file at a time — the cost of a bad folder is
                    // everything underneath it.
                    guard !skippedFolders.contains(name),
                          !bundleExtensions.contains(url.pathExtension.lowercased()),
                          !isMarkedNeverIndex(url.path)
                    else { continue }
                    queue.append((url, depth + 1))
                    continue
                }
                onFile(url, name, values)
            }
        }
    }

    /// Where a file was downloaded from, from its `kMDItemWhereFroms` xattr.
    static func whereFrom(_ url: URL) -> String? {
        let attribute = "com.apple.metadata:kMDItemWhereFroms"

        return url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }

            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }

            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { raw in
                getxattr(path, attribute, raw.baseAddress, size, 0, 0)
            }
            guard read == size else { return nil }

            // A binary plist array (download URL, referring page).
            let plist = try? PropertyListSerialization.propertyList(
                from: buffer, options: [], format: nil)
            guard let list = plist as? [String] else { return nil }

            let joined = list.filter { !$0.isEmpty }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
    }


    /// Everything under several folders, deduplicated, newest first.
    static func inventory(of folders: [URL], kinds: Set<String>,
                          within budget: TimeInterval) async -> [Candidate] {
        // One clock for the whole pass, not one per folder: five folders at
        // two and a half seconds each would be twelve seconds of waiting.
        let deadline = Date.now.addingTimeInterval(budget)

        var seen: Set<URL> = []
        var all: [Candidate] = []
        for folder in folders {
            for candidate in await inventory(of: folder, kinds: kinds, deadline: deadline)
            where !seen.contains(candidate.url) {
                seen.insert(candidate.url)
                all.append(candidate)
            }
        }
        all.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return all
    }

    static func inventory(of folder: URL, kinds: Set<String>,
                          deadline: Date) async -> [Candidate] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: catalogue(folder: folder, kinds: kinds,
                                                         deadline: deadline))
            }
        }
    }

    private static func catalogue(folder: URL, kinds: Set<String>, deadline: Date) -> [Candidate] {
        var files: [Candidate] = []
        traverse(from: folder, deadline: deadline) { url, name, values in
            guard kinds.contains(url.pathExtension.lowercased()) else { return }
            // A file too small to hold a sentence isn't worth opening, and an
            // enormous one costs more to read than it's likely to be worth.
            let size = values.fileSize ?? 0
            guard size > 512, size < 80_000_000 else { return }

            files.append(Candidate(
                url: url,
                displayName: name,
                modified: values.contentModificationDate,
                lastOpened: values.contentAccessDate,
                useCount: 0,
                whereFrom: nil))
        }

        // Everything found in time is returned; the sweep decides how much to read.
        files.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return files
    }
}
