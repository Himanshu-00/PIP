import AppKit

/// Sound and apps, as thin wrappers returning a short sentence for the model.
/// `TargetApp` remembers the app you were using before Pip's panel.
@MainActor
enum MacControl {

    // MARK: - Sound

    static func setVolume(_ percent: Int) async -> String {
        let level = min(max(percent, 0), 100)
        let result = await AppleScript.run("set volume output volume \(level) without output muted")
        return result.ok ? "Volume set to \(level)%." : "Couldn't change the volume."
    }

    /// Louder or quieter by a step, in one script (read and set together).
    static func nudgeVolume(up: Bool, by step: Int = 12) async -> String {
        let change = up ? "+ \(step)" : "- \(step)"
        let script = """
            set v to (output volume of (get volume settings)) \(change)
            if v > 100 then set v to 100
            if v < 0 then set v to 0
            set volume output volume v without output muted
            return v
            """
        let result = await AppleScript.run(script)
        guard result.ok else { return "Couldn't change the volume." }
        return "Volume \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))%."
    }

    static func setMuted(_ muted: Bool) async -> String {
        let result = await AppleScript.run("set volume output muted \(muted)")
        return result.ok ? (muted ? "Muted." : "Unmuted.") : "Couldn't change mute."
    }

    // MARK: - Apps

    static func app(named name: String) -> NSRunningApplication? {
        let wanted = name.lowercased().trimmingCharacters(in: .whitespaces)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { $0.localizedName?.lowercased() == wanted }
            ?? apps.first { ($0.localizedName?.lowercased() ?? "").contains(wanted) }
    }

    static func quitApp(_ name: String) -> String {
        guard let app = app(named: name) else { return "\(name) isn't open." }
        return app.terminate() ? "Quit \(app.localizedName ?? name)." : "\(name) didn't quit."
    }

    /// Opens an installed app by name only (exact, then containing), from the
    /// app folders.
    static func openApp(_ name: String) async -> String {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, !wanted.contains("/"), !wanted.contains("~") else { return "Which app? Give me its name." }
        let apps = InstalledApps.all
        let named = InstalledApps.name
        guard let app = apps.first(where: { named($0) == wanted }) ?? apps.first(where: { named($0).contains(wanted) })
        else { return "Couldn't find an app called \(name)." }
        do {
            try await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            return "Opened \(app.deletingPathExtension().lastPathComponent)."
        } catch {
            return "Couldn't open \(name): \(error.localizedDescription)"
        }
    }

    static func switchTo(_ name: String) -> String {
        guard let app = app(named: name) else { return "\(name) isn't open — open it with the app tool." }
        app.activate()
        TargetApp.current = app
        return "Switched to \(app.localizedName ?? name)."
    }
}

// MARK: - The app being worked on

/// The app you were using before Pip took the keyboard.
@MainActor
enum TargetApp {

    static var current: NSRunningApplication?
    private static var observer: Any?

    /// Follows the frontmost app, ignoring DynamicNotch itself.
    static func startTracking() {
        current = frontmostOther()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app != .current, app.activationPolicy == .regular else { return }
                MainActor.assumeIsolated { current = app }
            }
    }

    private static func frontmostOther() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication, front != .current else { return nil }
        return front
    }
}

// MARK: - Apple Music

/// Plays music in Apple Music: your playlist, else the song found via
/// Apple's public search, from your library or opened and played through
/// Accessibility (the one place Pip drives another app, owner's request).
enum MusicPlayer {

    static func play(_ what: String) async -> String {
        let query = what.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let resumed = await AppleScript.run(#"tell application "Music" to play"#)
            return resumed.ok ? "Playing." : "I couldn't start Music."
        }
        // 1. Your own music, not a particular song: "my songs", "my album
        // songs", "my library" — the library, not a random catalogue song.
        let asked = Self.plain(query)
        if Self.libraryWords.contains(asked) {
            let library = await AppleScript.run(#"tell application "Music" to play library playlist 1"#)
            return library.ok ? "Playing your library." : Self.noPermission
        }

        // 2. A playlist of yours: by name, spelling aside ("favorite songs"
        // is your "Favourite Songs" — exact names missed it).
        guard let playlists = await playlistNames() else { return Self.noPermission }
        if let playlist = Self.playlist(asked, in: playlists) {
            let played = await AppleScript.run("""
            tell application "Music" to play (first user playlist whose name is "\(quote(playlist))")
            """)
            return played.ok ? "Playing your playlist \(playlist)." : Self.noPermission
        }

        // Which song: Apple's search if it matches what was said, else a web search
        // for the real title first.
        var song = await lookUp(query)
        if let found = song, !Self.resembles(found, query) {
            ActivityLog.write(.tool, "music: \(found.title) by \(found.artist) doesn't look like \"\(query)\" — asking the web")
            song = nil
        }
        if song == nil { song = await titleFromWeb(query) }
        let title = song?.title ?? query
        // 3. In your library: play it (the same artist, when the web said).
        let track = await AppleScript.run("""
        tell application "Music"
            set hits to (search library playlist 1 for "\(quote(title))")
            repeat with hit in hits
                if "\(quote(song?.artist ?? ""))" is "" or (artist of hit contains "\(quote(song?.artist ?? ""))") then
                    play hit
                    return (name of hit) & "|" & (artist of hit)
                end if
            end repeat
            return "none"
        end tell
        """)
        guard track.ok else { return Self.noPermission }
        let parts = track.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        if parts.count == 2 { return "Playing \(parts[0]) by \(parts[1])." }

        // 4. Not yours: the exact song in Apple Music, and its Play pressed.
        if let song, let page = song.page {
            _ = await MainActor.run { NSWorkspace.shared.open(page) }
            if await pressPlay(on: song.title) { return "Playing \(song.title) by \(song.artist)." }
            return "I opened \(song.title) by \(song.artist) in Apple Music — it didn't start, so press play."
        }
        var link = URLComponents(string: "music://music.apple.com/search")
        link?.queryItems = [URLQueryItem(name: "term", value: query)]
        if let url = link?.url { _ = await MainActor.run { NSWorkspace.shared.open(url) } }
        return "I couldn't find \(query) for sure, so I opened Apple Music's search for it."
    }

    /// Presses Play on the song's row in Music (Accessibility, off main, ≤ 8 s).
    private static func pressPlay(on title: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            for _ in 0..<16 {
                Thread.sleep(forTimeInterval: 0.5)
                guard let music = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first
                else { continue }
                let app = AXUIElementCreateApplication(music.processIdentifier)
                AXUIElementSetMessagingTimeout(app, 1)
                if let play = playButton(beside: title, in: app) {
                    let pressed = AXUIElementPerformAction(play, kAXPressAction as CFString) == .success
                    ActivityLog.write(.tool, "music: pressed Play on \(title) in Music — \(pressed ? "ok" : "failed")")
                    return pressed
                }
            }
            ActivityLog.write(.tool, "music: no Play button beside \(title) in Music")
            return false
        }.value
    }

    /// The Play button in the same row as a text reading `title`.
    private static func playButton(beside title: String, in app: AXUIElement) -> AXUIElement? {
        func text(_ element: AXUIElement, _ key: String) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, key as CFString, &value)
            return (value as? String) ?? ""
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            return (value as? [AXUIElement]) ?? []
        }
        let wanted = title.lowercased()
        // From the window, not the whole app (menus), and a large budget:
        // with 3,000 it gave up in the sidebar and carousels before the
        // song rows (Neverland, Favorite: "no Play button").
        var window: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &window)
        var queue = [window.map { $0 as! AXUIElement } ?? app]
        var seen = 0
        while !queue.isEmpty, seen < 20_000 {
            let element = queue.removeFirst()
            seen += 1
            let kids = children(element)
            // A group of siblings holding both the title and a Play button: the row.
            let hasTitle = kids.contains { text($0, kAXRoleAttribute) == "AXStaticText"
                && text($0, kAXValueAttribute).lowercased() == wanted }
            if hasTitle, let play = kids.first(where: { text($0, kAXRoleAttribute) == "AXButton"
                && [text($0, kAXTitleAttribute), text($0, kAXDescriptionAttribute)].contains("Play") }) {
                return play
            }
            queue += kids
        }
        return nil
    }

    /// Your playlists' names, or nil when Music can't be reached.
    private static func playlistNames() async -> [String]? {
        let names = await AppleScript.run(#"tell application "Music" to get name of every user playlist"#)
        guard names.ok else { return nil }
        return names.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ", ")
    }

    /// The playlist meant by `asked` (already `plain`): the same name, or
    /// one containing the other.
    private static func playlist(_ asked: String, in names: [String]) -> String? {
        names.first { plain($0) == asked }
            ?? names.first { !asked.isEmpty && plain($0).count >= 3 && (plain($0).contains(asked) || asked.contains(plain($0))) }
    }

    /// The songs in one of your playlists, or your library — a few named
    /// in the answer, or all of them saved to a note. "List my favourite
    /// songs and save them to Notes" had no tool (2026-11-12).
    static func list(_ which: String, toNotes: Bool) async -> String {
        let asked = plain(which)
        var source = "library playlist 1"
        var title = "Your library"
        if !libraryWords.contains(asked) {
            guard let names = await playlistNames() else { return noPermission }
            guard let name = playlist(asked, in: names) else {
                return "You have no playlist called \(which). Yours: \(names.prefix(8).joined(separator: ", "))."
            }
            source = "first user playlist whose name is \"\(quote(name))\""
            title = name
        }
        // One Apple Event per song: capped at 500 so a big library answers
        // in seconds.
        let result = await AppleScript.run("""
        tell application "Music"
            set p to (\(source))
            set n to count of tracks of p
            if n > 500 then
                set m to 500
            else
                set m to n
            end if
            set out to (n as text) & linefeed
            repeat with i from 1 to m
                set t to track i of p
                set out to out & (name of t) & " — " & (artist of t) & linefeed
            end repeat
            return out
        end tell
        """)
        guard result.ok else { return noPermission }
        var lines = result.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let count = Int(lines.isEmpty ? "0" : lines.removeFirst()) ?? lines.count
        guard count > 0 else { return "\(title) has no songs." }
        if toNotes {
            let more = count > lines.count ? "\n…and \(count - lines.count) more" : ""
            let body = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + more
            let saved = await DailyTools.newNote(title: "\(title) — songs", body: body)
            return saved.hasPrefix("Made") ? "Saved \(lines.count) songs from \(title) to Notes." : saved
        }
        return "\(title) has \(count) songs, including " + lines.prefix(6).joined(separator: "; ") + "."
    }

    /// Lower case, British spellings folded, and the words around a name
    /// dropped: "My Favourite Songs playlist" → "favorite".
    static func plain(_ text: String) -> String {
        var words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let folds = ["favourite": "favorite", "favourites": "favorites", "colour": "color", "colours": "colors"]
        words = words.map { folds[$0] ?? $0 }
        words.removeAll { ["my", "the", "a", "playlist", "songs", "song", "music", "some"].contains($0) }
        return words.joined(separator: " ")
    }

    /// "Play my songs", "my album songs", "my library" (after `plain`).
    private static let libraryWords: Set<String> = ["", "album", "albums", "library", "all", "everything", "my"]

    /// Whether Apple's match is plausibly what was said: at least half the
    /// words said (besides "by", "the"…) are in its title or artist, near
    /// enough — "bohemian rap city by queen" ~ Bohemian Rhapsody by Queen.
    static func resembles(_ song: Song, _ query: String) -> Bool {
        let said = plain(query).split(separator: " ").map(String.init).filter { $0 != "by" && $0.count > 1 }
        guard !said.isEmpty else { return true }
        let theirs = plain(song.title + " " + song.artist).split(separator: " ").map(String.init)
        func near(_ a: String, _ b: String) -> Bool {
            a == b || (a.count >= 3 && b.count >= 3 && (a.hasPrefix(String(b.prefix(3))) || b.hasPrefix(String(a.prefix(3)))))
        }
        let hits = said.filter { word in theirs.contains { near(word, $0) } }.count
        return Double(hits) / Double(said.count) >= 0.5
    }

    private static let noPermission =
        "I couldn't reach Music — allow Pip to control it in System Settings ▸ Privacy & Security ▸ Automation."

    /// For inside an AppleScript string.
    private static func quote(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    struct Song { let title: String; let artist: String; let page: URL? }

    /// The song a web search says this is: its top results' titles, cleaned
    /// of site names ("… - YouTube", "(Official Video)", "Lyrics"), each
    /// tried on Apple's song search until one matches.
    static func titleFromWeb(_ query: String) async -> Song? {
        guard let results = try? await WebAccess.results(for: query + " song"), !results.isEmpty else { return nil }
        for result in results.prefix(5) {
            var title = result.title
            for noise in [#"\s*[|–—-]\s*(YouTube|Spotify|Apple Music|Wikipedia|Genius|Lyrics|Shazam|AZLyrics)\b.*$"#,
                          #"\s*[\(\[][^\)\]]*(official|lyrics?|audio|video|visuali[sz]er)[^\)\]]*[\)\]]"#,
                          #"\s*\b(lyrics|song by|on apple music)\b"#] {
                title = title.replacingOccurrences(of: noise, with: "", options: [.regularExpression, .caseInsensitive])
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard title.count >= 2 else { continue }
            if let song = await lookUp(title) {
                ActivityLog.write(.tool, "music: web says \"\(query)\" is \"\(title)\"")
                return song
            }
        }
        return nil
    }

    /// The best match on Apple's public song search (iTunes Search API):
    /// a web search, like Pip's others — no account, nothing personal sent
    /// beyond the words asked for. Nil offline or with no match.
    static func lookUp(_ query: String) async -> Song? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: query), URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let title = first["trackName"] as? String, let artist = first["artistName"] as? String
        else { return nil }
        // Opened in the Music app rather than the browser.
        let page = (first["trackViewUrl"] as? String).flatMap {
            URL(string: $0.replacingOccurrences(of: "https://", with: "music://"))
        }
        ActivityLog.write(.tool, "music: \"\(query)\" is \(title) by \(artist)")
        return Song(title: title, artist: artist, page: page)
    }
}

// MARK: - AppleScript

/// One-line AppleScripts via `osascript`.
enum AppleScript {
    /// Off the main thread: a script waiting on another app can take seconds.
    static func run(_ source: String) async -> (ok: Bool, output: String) {
        let result = await shell("/usr/bin/osascript", ["-e", source])
        return (result.status == 0, result.output)
    }

    /// Runs a command off the main thread.
    static func shell(_ path: String, _ arguments: [String],
                      timeout: TimeInterval = 8) async -> (status: Int32, output: String) {
        await Task.detached(priority: .userInitiated) {
            ScriptBridge.run(path, arguments, timeout: timeout)
        }.value
    }
}
