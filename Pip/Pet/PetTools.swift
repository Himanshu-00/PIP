import Foundation

/// Pip's tools as JSON-schema function definitions; descriptions kept short.
enum PetTools {

    /// The tools the model sees: fewer is better for a 9B, so `QuickCommands`'
    /// tools and unused ones are left out (their code stays).
    static let schemas: [[String: Any]] = {
        var seen = Set<String>()
        return (baseSchemas + webSchemas + dailySchemas + controlSchemas).filter { schema in
            guard let function = schema["function"] as? [String: Any],
                  let name = function["name"] as? String else { return true }
            return !quickOnly.contains(name) && !retired.contains(name) && seen.insert(name).inserted
        }
    }()

    /// Typed, not asked: caught by `QuickCommands` before the model.
    static let quickOnly: Set<String> = [
        "battery_status", "take_screenshot",
    ]

    /// Kept in the code, off the model's list: rarely or never used.
    static let retired: Set<String> = []

    /// Everyday jobs: clipboard, screenshots, files.
    static let dailySchemas: [[String: Any]] = [
        tool("read_clipboard", "Read the text on the clipboard.", [:], required: []),
        tool("take_screenshot", "Save a screenshot to the Desktop.",
             ["target": choice(["screen", "window"], "Whole screen or the front window")], required: []),
        // One tool for changing files (merged 2026-11-12 from create_folder,
        // move_file, copy_file, rename_file, trash_file — `PetAgent.resolve`
        // maps it back, so each job keeps its own checks).
        tool("file",
             "Change one file or folder: move it, copy it into a folder (the original stays), rename it where it "
             + "is (the extension is kept), put it in the Trash, or make a new folder.",
             ["action": choice(["move", "copy", "rename", "trash", "new_folder"], "What to do"),
              "path": string("Full path of the file, from a tool's result (not for new_folder)"),
              "to": string("For move and copy: desktop, documents, downloads, or a folder path. "
                           + "For new_folder: where to make it"),
              "name": string("For rename: the new name, e.g. 2026-10-15 Rent. For new_folder: its name")],
             required: ["action"]),
        tool("ask_files",
             "Answer a question from the user's own files (receipts, statements, letters, notes, papers): finds the "
             + "relevant files and returns excerpts to answer from. E.g. 'how much rent did I pay last month'.",
             ["question": string("The user's question"),
              "query": string("Optional: which files to look in, e.g. 'rent receipts' or 'offer letter'"),
              "folder": string("Optional: only look in this folder, e.g. 'Uni' or 'Downloads'")],
             required: ["question"]),
        tool("timer",
             "A countdown timer shown in the notch: start, pause, resume, add time, cancel, or say how long is left.",
             ["action": choice(["start", "pause", "resume", "add", "cancel", "status"], "What to do"),
              "minutes": number("For start/add: how many minutes (decimals allowed, e.g. 0.5)"),
              "label": string("Optional: what it's for, e.g. tea")],
             required: ["action"]),
        tool("collect_files",
             "Copy or move every file matching a search into one folder (made if needed). Only when the user "
             + "asks to put, copy, move or gather files into a folder — never to list, show or find them "
             + "(that's find_files). Shows the files and asks the user once.",
             ["query": string("Which files, e.g. 'rent receipts' or 'visa documents pdf'"),
              "folder": string("Folder name, e.g. Rent History, or a path"),
              "mode": choice(["copy", "move"], "copy keeps the originals where they are (default)"),
              "from": string("Optional: only files lying in this folder (desktop, downloads, documents or a "
                             + "path) — every match there, e.g. all screenshots on the Desktop"),
              "since": string("Optional: only files added since then, e.g. 'just now' (the last hour), "
                              + "'today', 'this week' — for 'the files I just downloaded'")],
             required: ["query", "folder"]),
        tool("search_conversations",
             "Search earlier conversations with the user (yesterday, last week, further back): what they asked, "
             + "what you answered, which files came up. Use when they refer to something discussed before. "
             + "Earlier answers can be wrong: for a fact from a file (a date, an amount), read that file again.",
             ["query": string("Words to look for, e.g. 'visa letter' or 'rent receipt'"),
              "when": string("Optional: when, in the user's words, e.g. 'yesterday', 'last week'")],
             required: ["query"]),
        tool("recent_files",
             "List the files the user opened or changed in a time window. Use for 'what was I working on "
             + "yesterday', 'files I changed this morning'.",
             ["when": string("The time, in the user's words, e.g. 'yesterday', 'last week', 'today'"),
              "folder": string("Optional: Desktop, Documents, Downloads or a path")],
             required: ["when"]),
        tool("find_duplicates",
             "Find files that are exact copies of each other in a folder, show them, and offer to move the "
             + "extra copies to the Trash (asks the user first; originals stay).",
             ["folder": string("Desktop, Documents, Downloads or a path (default Downloads)")],
             required: []),
        tool("organize_folder",
             "Sort the loose files in a folder into subfolders by what they are (receipts, study, photos, "
             + "installers…). Shows the plan and asks first.",
             ["folder": string("Desktop, Documents, Downloads or a path (default Downloads)")],
             required: []),
        tool("suggest_names",
             "Find files with meaningless names (IMG_4821.jpg, Document (3).pdf) in a folder, suggest names "
             + "from what's in them, and rename them if the user agrees (asks first).",
             ["folder": string("Desktop, Documents, Downloads or a path (default Downloads)")],
             required: []),
    ]

    /// The internet directly, in the background — no browser involved.
    static let webSchemas: [[String: Any]] = [
        tool("web_search", "Search the internet in the background (no browser). Returns titles, addresses and snippets. "
             + "kind 'images' instead shows pictures of it in your window — for 'show me pictures of…'.",
             ["query": string("What to search for"),
              "kind": choice(["web", "images"], "web (default), or images to show pictures")],
             required: ["query"]),
        tool("read_webpage", "Read a web page's text in the background (no browser).",
             ["url": string("The page address")], required: ["url"]),
    ]

    private static let baseSchemas: [[String: Any]] = [
        tool("find_files",
             "Search the user's files by name or by what is inside them, or by what kind of file they are. "
             + "Use for find, list and show — 'list all my research papers' too. Returns the best matches with "
             + "their full paths; the rest are on screen.",
             ["query": string("What to look for, e.g. 'applied task 4' or 'rent invoice'")],
             required: ["query"]),
        tool("open_file",
             "Open a file in its default app, or show it in Finder. Use a full path returned by find_files.",
             ["path": string("Full path of the file"),
              "in_finder": boolean("true to show it in Finder instead of opening it")],
             required: ["path"]),
        // One music tool (merged 2026-11-12 from play_music, media_control,
        // now_playing, music_list).
        tool("music",
             "Apple Music: play a song, artist, album or one of the user's playlists (e.g. their favourite songs); "
             + "pause or resume; next or previous; say what's playing; or list a playlist's songs (or the whole "
             + "library), optionally saved to Notes.",
             ["action": choice(["play", "pause", "next", "previous", "now_playing", "list"], "What to do"),
              "what": string("For play: the song, artist, album or playlist (empty to resume). "
                             + "For list: the playlist (empty for the whole library)"),
              "to_notes": boolean("For list: save the whole list as a note")],
             required: ["action"]),
        // One app tool (merged 2026-11-12 from open_app, switch_to_app, quit_app).
        tool("app",
             "Open a Mac app, bring an open one to the front, or quit one, by name (e.g. 'Safari', 'Notes').",
             ["action": choice(["open", "switch", "quit"], "What to do"),
              "name": string("The app's name")],
             required: ["action", "name"]),
        tool("open_website",
             "Open a website in the default browser. (For pictures, use web_search with kind 'images'.)",
             ["url": string("The address, e.g. 'github.com'")],
             required: ["url"]),
        tool("battery_status", "Report the battery level and whether it is charging.", [:], required: []),
    ]

    /// Working the Mac itself: sound, apps, and looking at the screen. Kept
    /// in a separate list so the original tools above stay easy to read.
    static let controlSchemas: [[String: Any]] = [
        // One volume tool (merged 2026-11-12 from set_volume, mute).
        tool("volume", "Set the output volume, or mute or unmute the sound.",
             ["level": number("0 to 100"), "mute": boolean("true to mute, false to unmute")], required: []),
        tool("look_at_screen",
             "Look at what is on the user's screen right now and answer a question about it: images, charts, videos, colours, layout, or text. Not for files — a file name means look_at_photo. Takes a few seconds.",
             ["question": string("What to find out from the picture"),
              "target": choice(["screen", "window"], "The whole screen, or just the front window")],
             required: ["question"]),
        tool("look_at_photo",
             "Look at a photo or picture file (or a PDF's first page) and answer a question about what it shows: "
             + "people, clothes, colours, objects, the place, text in it. Use whenever the user names a file "
             + "(e.g. photo.jpg) or a photo of theirs. Takes a few seconds.",
             ["path": string("The file's name (e.g. photo.jpg) or a full path from find_files"),
              "question": string("What to find out from it")],
             required: ["path"]),
    ]

    // MARK: - Schema helpers

    private static func tool(_ name: String,
                             _ description: String,
                             _ properties: [String: Any],
                             required: [String]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    private static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func choice(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }
}

/// Search as one function for Pip: names, the full-text store and meaning,
/// once each, merged.
enum FileFinder {

    /// Words a request wraps around the name ("open the file called…", "the
    /// attention paper"). Kind words are filters, in `QueryParse`.
    private static let filler: Set<String> = QueryParse.chatWords

    /// The extensions a type word names, plurals included ("pictures").
    private static func kindExtensions(_ word: String) -> Set<String>? {
        QueryParse.extensions(for: word)
    }

    /// Every file that clearly matches, for acting on a collection; stricter
    /// than `find`.
    static func findAll(_ query: String, limit: Int = 60) async -> [URL] {
        let words = Tokens.of(query).filter { !filler.contains($0) }
        guard !words.isEmpty else { return [] }
        var wanted = Set<String>()
        for word in words {
            if let extensions = kindExtensions(word) { wanted.formUnion(extensions) }
        }
        let ranked = await SearchController.forPip.find(words.joined(separator: " "), timeHint: query)
        let confident = ranked.filter { candidate in
            (wanted.isEmpty || wanted.contains(candidate.url.pathExtension.lowercased()))
                && (candidate.matchesAll || candidate.features.nameMatch >= 0.7
                    || candidate.features.textMatch >= 0.6)
                && FileManager.default.fileExists(atPath: candidate.url.path)
        }
        return Array(confident.prefix(limit)).map(\.url)
    }

    /// Files directly in `folder` that the query describes (kind words filter
    /// by extension, other words must be in the name). No words = every file.
    static func inFolder(_ folder: URL, matching query: String) -> [URL] {
        // "screenshots on desktop": the folder's own name isn't in the files' names.
        let places: Set<String> = ["desktop", "download", "downloads", "document", "documents", "folder", "all"]
        // Nor are "every file", "recent files": when they're all that's left,
        // it means every file there ("all files" and "*" found nothing).
        let everything: Set<String> = ["file", "files", "every", "everything", "recent", "recently", "just",
                                       "latest", "newest", "downloaded", "now", "today", "yesterday", "week", "hour"]
        let words = Tokens.query(query).filter { !filler.contains($0) && !places.contains($0) && !everything.contains($0) }
        var wanted = Set<String>()
        var named: [String] = []
        for word in words {
            if word != "screenshot", let extensions = kindExtensions(word) {
                wanted.formUnion(extensions)
            } else {
                named.append(word)
            }
        }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { file in
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
            if !wanted.isEmpty, !wanted.contains(file.pathExtension.lowercased()) { return false }
            let name = file.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "")
            return named.allSatisfy { name.contains($0) }
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Answering from files

    /// Words that ask rather than describe: left out when looking for the
    /// files a question is about.
    private static let questionWords: Set<String> = [
        "what", "which", "how", "much", "many", "when", "where", "who", "why", "did", "does", "do", "is",
        "are", "was", "were", "i", "my", "me", "tell", "say", "says", "said", "according", "total",
        "last", "month", "week", "year", "ago", "this", "there",
    ]

    /// Excerpts for the model to answer from: up to six files, read deeply,
    /// cut into passages, scored by meaning plus question words, ~2,400
    /// characters in all. Falls back to keyword windows without the embedding.
    static func evidence(question: String, query: String?, folder: URL? = nil) async -> (files: [URL], text: String) {
        var source = (query?.isEmpty == false ? query! : question)
        // The question says "latest"; the model's query often doesn't.
        if let word = PetAgent.latestWord(in: question), PetAgent.latestWord(in: source) == nil { source += " " + word }
        let words = Tokens.of(source).filter { !filler.contains($0) && !questionWords.contains($0) }
        // What to look for inside: the question's own words, as stems.
        let needles = Tokens.query(question).filter { $0.count >= 3 && !questionWords.contains($0) }
            + Tokens.query(source).filter { $0.count >= 3 }

        var chosen: [Candidate]
        if let folder {
            chosen = await files(in: folder, about: question, needles: needles)
        } else {
            guard !words.isEmpty else { return ([], "") }
            // The question carries the time ("last month"); the search words may not.
            let ranked = await SearchController.forPip.find(words.joined(separator: " "), timeHint: question)
            chosen = ranked.filter { candidate in
                candidate.matchesAll || candidate.features.nameMatch >= 0.6
                    || candidate.features.textMatch >= 0.4 || candidate.features.semanticMatch >= 0.4
            }
            if chosen.isEmpty { chosen = Array(ranked.prefix(3)) }
            chosen = Array(chosen.filter { FileManager.default.fileExists(atPath: $0.url.path) }.prefix(6))
        }
        guard !chosen.isEmpty else { return ([], "") }

        var blocks = await meaningExcerpts(question: question, needles: needles, files: chosen)
        if blocks == nil { blocks = await keywordExcerpts(needles: needles, files: chosen) }
        let text = "From the user's files (answer only from these, and name the file you used; "
            + "if they don't say, tell the user it isn't there):\n" + (blocks ?? []).joined(separator: "\n\n")
        return (chosen.map(\.url), text)
    }

    /// "[n] name — in folder, modified date:" — the line the model names its source from.
    private static func blockHeader(_ number: Int, _ candidate: Candidate) -> String {
        let folder = candidate.url.deletingLastPathComponent().lastPathComponent
        let date = candidate.modified.map {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)
        } ?? "unknown date"
        return "[\(number)] \(candidate.url.lastPathComponent) — in \(folder), modified \(date):"
    }

    /// The older way, kept as the fallback: the indexed text (the first
    /// 4,000 characters), windows around the question's words.
    private static func keywordExcerpts(needles: [String], files chosen: [Candidate]) async -> [String] {
        let extractor = TextExtractor()
        let budget = 2_400 / chosen.count
        var blocks: [String] = []
        for (index, candidate) in chosen.enumerated() {
            var body = await ContentStore.shared.record(path: candidate.url.path, modified: nil, anyDate: true)?.text ?? ""
            if body.isEmpty {
                body = await extractor.texts(for: [candidate])[candidate.url]?.text ?? ""
            }
            let excerpt = body.isEmpty ? "(no readable text)" : excerpts(of: body, around: needles, budget: budget)
            blocks.append(blockHeader(index + 1, candidate) + "\n" + excerpt)
        }
        return blocks
    }

    /// One file's deep text, its passages worth embedding, and what's cached.
    private struct AskDocument {
        var candidate: Candidate
        var key: String
        var text: String
        var passages: [String]
        /// Each passage's word bonus (`wordBonus`).
        var bonus: [Double]
        var vectors: [String: [Float]]
    }

    /// The word half of a passage's score, 0…0.49: rarer question words count
    /// more, and two close together more again.
    private static func wordBonus(_ passages: [String], stems: [String]) -> [Double] {
        let tokens = passages.map { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        let count = Double(passages.count)
        let idf = stems.map { stem -> Double in
            let holding = Double(tokens.filter { $0.contains { $0.hasPrefix(stem) } }.count)
            return holding == 0 ? 0 : log((count - holding + 0.5) / (holding + 0.5) + 1)
        }
        let total = idf.reduce(0, +)
        return tokens.map { words in
            let positions = stems.map { stem in words.indices.filter { words[$0].hasPrefix(stem) } }
            let covered = zip(positions, idf).filter { !$0.0.isEmpty }.reduce(0.0) { $0 + $1.1 }
            var near = 0
            for a in positions.indices {
                for b in positions.indices where b > a && positions[a].contains(where: { x in
                    positions[b].contains { abs($0 - x) <= 4 } }) {
                    near += 1
                }
            }
            return (total > 0 ? 0.25 * covered / total : 0) + 0.12 * Double(min(near, 2))
        }
    }

    /// Passages chosen by meaning, at most two per file, ~2,400 characters
    /// in all. Nil when the embedding isn't available or nothing had text.
    private static func meaningExcerpts(question: String, needles: [String],
                                        files chosen: [Candidate]) async -> [String]? {
        let started = Date()
        let stems = Array(Set(needles))
        let fallbackReader = TextExtractor()

        // 1. Deep text, every file at once.
        var documents: [AskDocument?] = Array(repeating: nil, count: chosen.count)
        await withTaskGroup(of: (Int, AskDocument).self) { group in
            for (index, candidate) in chosen.enumerated() {
                group.addTask {
                    let modified = (try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    let key = candidate.url.path + "|" + String(Int(modified?.timeIntervalSince1970 ?? 0))
                    let cached = await SemanticIndex.shared.askCached(key)
                    var text = cached.text ?? ""
                    if cached.text == nil {
                        text = await TextExtractor.deepText(of: candidate)
                        if text.isEmpty {
                            text = await ContentStore.shared.record(path: candidate.url.path, modified: nil,
                                                                    anyDate: true)?.text ?? ""
                        }
                        if text.isEmpty {
                            text = await fallbackReader.texts(for: [candidate])[candidate.url]?.text ?? ""
                        }
                    }
                    // Up to 80 passages a file get a vector: its opening, then
                    // those with the best word bonus. A 40-page paper is ~160
                    // passages, and each costs a few milliseconds.
                    let all = SemanticIndex.overlappingPassages(from: text)
                    let bonus = wordBonus(all, stems: stems)
                    var keep = Set(all.indices.prefix(3))
                    for position in all.indices.sorted(by: { bonus[$0] != bonus[$1] ? bonus[$0] > bonus[$1] : $0 < $1 })
                    where keep.count < 80 {
                        keep.insert(position)
                    }
                    let picked = keep.sorted()
                    return (index, AskDocument(candidate: candidate, key: key, text: text,
                                               passages: picked.map { all[$0] }, bonus: picked.map { bonus[$0] },
                                               vectors: cached.vectors))
                }
            }
            for await (index, document) in group { documents[index] = document }
        }
        let read = documents.compactMap { $0 }
        guard read.contains(where: { !$0.passages.isEmpty }) else { return nil }
        let readAt = Date()

        // 2. Vectors for the question and every passage not cached yet.
        var missing: [String] = []
        var seen = Set<String>()
        for document in read {
            for passage in document.passages where document.vectors[passage] == nil && seen.insert(passage).inserted {
                missing.append(passage)
            }
        }
        let batch = [question] + missing
        guard let vectors = await Task.detached(priority: .userInitiated, operation: { SemanticIndex.embed(batch) }).value,
              let probe = vectors.first, !probe.isEmpty else { return nil }
        var fresh: [String: [Float]] = [:]
        for (passage, vector) in zip(missing, vectors.dropFirst()) where !vector.isEmpty { fresh[passage] = vector }
        let embeddedAt = Date()

        // 3. Score: meaning, plus a little per question word in the passage.
        var scored: [(file: Int, position: Int, score: Float)] = []
        for (file, document) in read.enumerated() {
            var own: [String: [Float]] = [:]
            for (position, passage) in document.passages.enumerated() {
                guard let vector = document.vectors[passage] ?? fresh[passage], vector.count == probe.count else { continue }
                own[passage] = vector
                let similarity = zip(probe, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                scored.append((file, position, similarity + Float(document.bonus[position])))
            }
            await SemanticIndex.shared.askRemember(document.key, text: document.text, vectors: own)
        }
        guard !scored.isEmpty else { return nil }

        // 4. Best first, within the budget: two per file when three or more
        //    were read (so a broad question spreads across them), more when
        //    there are fewer — the right passage is often third, not first.
        let perFile = max(2, 6 / read.count)
        var picks: [Int: [Int]] = [:]
        var used = 0
        for entry in scored.sorted(by: { $0.score > $1.score }) {
            let passage = read[entry.file].passages[entry.position]
            guard picks[entry.file, default: []].count < perFile, used + passage.count <= 2_400 else { continue }
            picks[entry.file, default: []].append(entry.position)
            used += passage.count
        }
        var blocks: [String] = []
        for (file, document) in read.enumerated() {
            guard let positions = picks[file] else { continue }
            let excerpt = positions.sorted().map { document.passages[$0] }.joined(separator: " … ")
            blocks.append(blockHeader(blocks.count + 1, document.candidate) + "\n" + excerpt)
        }
        let names = read.map(\.candidate.url.lastPathComponent).joined(separator: ", ")
        ActivityLog.write(.tool, String(format: "ask_files: read %ld files (%@) — text %.0fms, embedded %ld in %.0fms, "
                                        + "scored %ld passages, used %ld from %ld files",
                                        read.count, names, readAt.timeIntervalSince(started) * 1000, missing.count,
                                        embeddedAt.timeIntervalSince(readAt) * 1000, scored.count,
                                        picks.values.reduce(0) { $0 + $1.count }, picks.count))
        return blocks
    }

    // MARK: - Asking within a folder

    /// Kinds "Ask your files" can read in a folder.
    private static let askable: Set<String> = [
        "pdf", "doc", "docx", "rtf", "odt", "html", "htm", "pptx", "xlsx",
        "txt", "md", "markdown", "csv", "tex", "png", "jpg", "jpeg", "heic",
    ]

    /// A folder by name — "Uni", "Japanese 2", "Downloads" — or a path. The
    /// usual places and paths through `DailyTools.place`; a bare name is
    /// looked for under the home folder, shallowest first, a few levels down.
    static func folder(named name: String) async -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        if let place = await MainActor.run(body: { DailyTools.place(trimmed) }),
           FileManager.default.fileExists(atPath: place.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return place
        }
        let wanted = trimmed.lowercased()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var level = [home]
        var close: URL?
        var visited = 0
        for _ in 0..<5 {
            var next: [URL] = []
            for parent in level {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                    options: [.skipsHiddenFiles])) ?? []
                for child in children {
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    // `DailyTools.isOffLimits`' rule: ~/Library, hidden and developer folders.
                    guard values?.isDirectory == true, values?.isPackage != true,
                          !DirectScan.isExcluded(child.appendingPathComponent("x").path) else { continue }
                    let own = child.lastPathComponent.lowercased()
                    if own == wanted { return child }
                    if close == nil, own.contains(wanted) { close = child }
                    next.append(child)
                }
                visited += 1
                if visited > 4_000 { return close }
            }
            level = next
        }
        return close
    }

    /// The files in `folder` (and below, newest 200) closest to the
    /// question, six at most: by the index's meaning vectors, the question's
    /// words in the indexed text, and the name. All of them when six or fewer.
    private static func files(in folder: URL, about question: String, needles: [String]) async -> [Candidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var found: [(url: URL, modified: Date)] = []
        var looked = 0
        while let url = walker?.nextObject() as? URL, looked < 5_000 {
            looked += 1
            guard askable.contains(url.pathExtension.lowercased()), !DirectScan.isExcluded(url.path),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            found.append((url, values.contentModificationDate ?? .distantPast))
        }
        let candidates = found.sorted { $0.modified > $1.modified }.prefix(200).map { entry in
            Candidate(url: entry.url, displayName: entry.url.lastPathComponent, modified: entry.modified,
                      lastOpened: nil, useCount: 0, whereFrom: nil)
        }
        guard candidates.count > 6 else { return Array(candidates) }

        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        var meaning: [String: Double] = [:]
        for match in await SemanticIndex.shared.search(question, limit: 8_000) where match.url.path.hasPrefix(prefix) {
            meaning[match.url.path] = match.similarity
        }
        var stored: [String: String] = [:]
        for candidate in candidates {
            if let text = await ContentStore.shared.record(path: candidate.url.path, modified: nil, anyDate: true)?.text {
                stored[candidate.url.path] = text
            }
        }
        // Never read: read the newest few now (this also indexes them).
        let unread = candidates.filter { stored[$0.url.path] == nil }.prefix(24)
        if !unread.isEmpty {
            for (url, extracted) in await TextExtractor().texts(for: Array(unread)) { stored[url.path] = extracted.text }
        }
        let scored = candidates.map { candidate -> (Candidate, Double) in
            let path = candidate.url.path
            let score = (meaning[path] ?? 0)
                + 0.3 * Fuzzy.literalOverlap(needles, in: stored[path] ?? "")
                + 0.4 * Fuzzy.score(words: needles, against: candidate.url.deletingPathExtension().lastPathComponent)
            return (candidate, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
    }

    /// The parts of `text` around the words, up to `budget` characters;
    /// the start of the text when none of them appear.
    private static func excerpts(of text: String, around words: [String], budget: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        var windows: [Range<String.Index>] = []
        for word in Set(words) {
            var from = flat.startIndex
            while windows.count < 4,
                  let hit = flat.range(of: word, options: .caseInsensitive, range: from ..< flat.endIndex) {
                let start = flat.index(hit.lowerBound, offsetBy: -120, limitedBy: flat.startIndex) ?? flat.startIndex
                let end = flat.index(hit.upperBound, offsetBy: 180, limitedBy: flat.endIndex) ?? flat.endIndex
                if !windows.contains(where: { $0.overlaps(start ..< end) }) { windows.append(start ..< end) }
                from = hit.upperBound
            }
        }
        guard !windows.isEmpty else { return String(flat.prefix(budget)) }
        windows.sort { $0.lowerBound < $1.lowerBound }
        var out = ""
        for window in windows {
            let piece = String(flat[window]).trimmingCharacters(in: .whitespaces)
            if out.count + piece.count > budget { break }
            out += (out.isEmpty ? "" : " … ") + piece
        }
        return out.isEmpty ? String(flat.prefix(budget)) : out
    }

    /// Whether the query names only a kind of file ("pdf", "it's a pdf") —
    /// a refinement of the previous search, not a search of its own.
    static func isOnlyKind(_ query: String) -> Bool {
        let words = Tokens.of(query).filter { !filler.contains($0) && !["it", "is", "s", "its"].contains($0) }
        return !words.isEmpty && words.allSatisfy { kindExtensions($0) != nil }
    }

    /// Pip's file search: wrapping words removed, the notch search's engine,
    /// then a kind filter; the older finder if nothing fits.
    static func find(_ query: String, limit: Int = 5) async -> [URL] {
        // Five, or more when more are as good: past five, a file is kept
        // while it scores within 80% of the best, or Pip described it as the
        // kind asked for ("list all my papers"), up to twelve.
        let all = Tokens.of(query).filter { !filler.contains($0) }
        guard !all.isEmpty else { return [] }
        var wanted = Set<String>()
        for word in all {
            if let extensions = kindExtensions(word) { wanted.formUnion(extensions) }
        }
        // Kind words stay in the text: the engine treats them as hints about the kind of file.
        // A file name ("photo.jpg") goes to the engine as typed: split into
        // "profile jpg" it lost the dot, and with it the name — Pip got
        // screenshots that happened to be JPGs.
        let named = query.range(of: #"[\w-]\.[A-Za-z0-9]{2,5}\b"#, options: .regularExpression) != nil
        let text = named ? query.trimmingCharacters(in: .whitespaces)
                         : Tokens.of(query).filter { !filler.contains($0) }.joined(separator: " ")
        let ranked = await SearchController.forPip.find(text, timeHint: query)
        var fitting = ranked.filter { candidate in
            (wanted.isEmpty || wanted.contains(candidate.url.pathExtension.lowercased()))
                && FileManager.default.fileExists(atPath: candidate.url.path)
        }
        // "the latest rent pic": among the files that clearly match, newest
        // first. Relevance alone put September's receipt above October's.
        let newestWords: Set<String> = ["latest", "newest", "recent", "recently"]
        if !newestWords.isDisjoint(with: all) {
            // Not code: our own source is edited daily and quotes every query.
            let confident = fitting.filter {
                ($0.matchesAll || $0.features.nameMatch >= 0.6 || $0.features.textMatch >= 0.4)
                    && !DirectScan.codeKinds.contains($0.url.pathExtension.lowercased())
            }
            if !confident.isEmpty {
                let rest = fitting.filter { candidate in !confident.contains { $0.url == candidate.url } }
                fitting = confident.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) } + rest
            }
        }
        var chosen = Array(fitting.prefix(limit))
        let urls = fitting.map(\.url)
        let askedKind = await MainActor.run { Set(urls.filter { SearchController.forPip.isAskedKind($0) }) }
        let offKind = await MainActor.run { Set(urls.filter { !SearchController.forPip.fitsAskedKind($0) }) }
        if chosen.count == limit, let best = fitting.first?.score, best > 0 {
            for candidate in fitting.dropFirst(limit).prefix(SearchController.extendedShortlist - limit)
            where candidate.score >= best * 0.8 {
                chosen.append(candidate)
            }
            // Pip described it as the kind asked for: in the list wherever it
            // ranked (a paper whose text barely says "research" came 13th).
            for candidate in fitting.dropFirst(limit) where chosen.count < SearchController.extendedShortlist
                && askedKind.contains(candidate.url) && !chosen.contains(where: { $0.url == candidate.url }) {
                chosen.append(candidate)
            }
            // A kind of file was asked for ("rent receipts"): a list, so every
            // file holding all the words too — photographed receipts score
            // below the described ones, but they're receipts.
            if !askedKind.isEmpty, fitting.first?.matchesAll == true {
                for candidate in fitting.dropFirst(limit) where chosen.count < SearchController.extendedShortlist
                    && candidate.matchesAll && !offKind.contains(candidate.url)
                    && !chosen.contains(where: { $0.url == candidate.url }) {
                    chosen.append(candidate)
                }
            }
        }
        if !chosen.isEmpty {
            await SearchController.forPip.remember(shown: chosen)
            return chosen.map(\.url)
        }
        // The fallback's Spotlight and index hits skip the engine's filter:
        // our own repo's us_gold.json came back for a flight question.
        return await legacyFind(all, limit: limit).filter { !DirectScan.isExcluded($0.path) }
    }

    /// The finder Pip used before the shared engine: names, the index,
    /// Spotlight and meaning, scored here. Kept as the fallback.
    private static func legacyFind(_ all: [String], limit: Int) async -> [URL] {

        // Split the request into what the file is called and what kind it is.
        var wanted = Set<String>()
        for word in all {
            if let extensions = QueryParse.kinds[word] { wanted.formUnion(extensions) }
        }
        var words = all.filter { QueryParse.kinds[$0] == nil }
        if words.isEmpty { words = all }        // "find my pdf": nothing else to go on
        // Abbreviations expanded: names match both, contents only the full words.
        let expanded = words.map { Tokens.abbreviations[$0] ?? $0 }
        let phrase = expanded.joined(separator: " ")
        let extra = expanded.filter { !words.contains($0) }
        words.append(contentsOf: extra)

        var scores: [URL: Double] = [:]
        func keep(_ url: URL, _ score: Double) {
            guard wanted.isEmpty || wanted.contains(url.pathExtension.lowercased()) else { return }
            scores[url] = max(scores[url] ?? 0, score)
        }

        // Names, by walking the usual folders — scored on the name without
        // its extension, so the extension can't match anything.
        let named = await DirectScan.matches(words: words, in: DirectScan.commonFolders, limit: 60)
        for candidate in named {
            let stem = candidate.url.deletingPathExtension().lastPathComponent
            var score = Fuzzy.score(words: words, against: stem)
            // A name holding one word of a five-word query ("attention.py"
            // for "attention is all you need") is a weak match, however well
            // that one word matches.
            if expanded.count >= 3, Fuzzy.literalOverlap(expanded, in: stem.lowercased()) < 0.5 {
                score = min(score, 0.6)
            }
            keep(candidate.url, score)
        }

        // Contents and titles, from everything already read. A document's
        // own title ("Applied Task 4 – Relational Algebra") is often the
        // best name it has.
        let hits = await ContentStore.shared.search(words: expanded, limit: 30)
        let scaled = BM25.normaliseExternal(hits.map(\.score))
        for (hit, score) in zip(hits, scaled) {
            var best = score * 0.8
            if let title = hit.title {
                best = max(best, Fuzzy.score(words: expanded, against: title))
            }
            // The words together, or every one of them in the document, beat
            // a name holding one of them (capped at 0.6 above).
            if hit.phrase && expanded.count >= 2 { best = max(best, 1.0) }
            else if hit.allWords && expanded.count >= 2 { best = max(best, 0.9) }
            keep(hit.url, best)
        }

        // Spotlight, for contents and titles the stages above haven't seen.
        for (url, score) in await spotlight(phrase: phrase, words: expanded) {
            keep(url, score)
        }

        // Meaning, for queries long enough to have some.
        if expanded.count >= 2 {
            let meaning = await SemanticIndex.shared.search(phrase, limit: 10)
            for match in meaning where match.similarity >= 0.45 {
                let closeness: Double = min(max((match.similarity - 0.35) / 0.45, 0), 1)
                keep(match.url, closeness * 0.75)
            }
        }

        // Ties go to the most recently modified file rather than to whatever
        // order a dictionary happens to iterate in.
        var ranked: [Ranked] = []
        for (url, score) in scores where score > 0.3 && FileManager.default.fileExists(atPath: url.path) {
            ranked.append(Ranked(url: url, score: score, modified: modified(url)))
        }
        ranked.sort { left, right in
            if abs(left.score - right.score) > 0.01 { return left.score > right.score }
            return left.modified > right.modified
        }
        return ranked.prefix(limit).map { $0.url }
    }

    /// Asks Spotlight for files whose own title contains the phrase (strong)
    /// or whose text contains every word (weaker). Two seconds at most; on any
    /// trouble it simply contributes nothing.
    static func spotlight(phrase: String, words: [String]) async -> [(URL, Double)] {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: #"["*\\]"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let title = clean(phrase)
        let terms = Array(words.map(clean).filter { $0.count >= 3 }.prefix(5))
        guard !title.isEmpty else { return [] }

        var out: [(URL, Double)] = []
        let byTitle = "kMDItemTitle == \"*\(title)*\"cd"
        for path in await mdfind(byTitle) { out.append((URL(fileURLWithPath: path), 1.0)) }
        if !terms.isEmpty {
            let byText = terms.map { "kMDItemTextContent == \"\($0)*\"cd" }.joined(separator: " && ")
            // Every word of a longer query inside one document is strong
            // evidence — stronger than one of those words in a file name.
            let strength = terms.count >= 3 ? 0.9 : terms.count == 2 ? 0.7 : 0.5
            for path in await mdfind(byText) { out.append((URL(fileURLWithPath: path), strength)) }
        }
        return out
    }

    /// Runs `mdfind` over the home folder, off the main thread, for at most
    /// two seconds, skipping Library and app bundles.
    private static func mdfind(_ query: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                process.arguments = ["-onlyin", NSHomeDirectory(), query]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: [])
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: deadline)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                let library = NSHomeDirectory() + "/Library/"
                let paths = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { !$0.hasPrefix(library) && !$0.contains(".app/") && !$0.contains("/.") }
                continuation.resume(returning: Array(paths.prefix(30)))
            }
        }
    }

    private struct Ranked {
        let url: URL
        let score: Double
        let modified: Date
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }
}
