import AppKit

/// The apps installed in the usual folders: for "open Safari" without the
/// model (`find`), the app tool, and the app rows Pip shows while you type.
/// Listed at most once a minute (a few ms).
@MainActor
enum InstalledApps {

    private static var cached: [URL] = []
    private static var listedAt = Date.distantPast

    static var all: [URL] {
        if Date().timeIntervalSince(listedAt) > 60 {
            cached = list()
            listedAt = Date()
        }
        return cached
    }

    /// /Applications (and one level of folders in it), /System/Applications,
    /// ~/Applications, and their Utilities.
    private static func list() -> [URL] {
        let manager = FileManager.default
        var folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
        folders += ((try? manager.contentsOfDirectory(at: folders[0], includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.isEmpty && $0.lastPathComponent != "Utilities" }
        var seen = Set<String>()
        return folders.flatMap { (try? manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "app" && seen.insert(name($0)).inserted }
    }

    static func name(_ app: URL) -> String { app.deletingPathExtension().lastPathComponent.lowercased() }

    /// The apps' own names, as written ("Google Chrome").
    private static var names: [String] { all.map { $0.deletingPathExtension().lastPathComponent } }

    /// Everyday names that aren't the app's own name.
    private static let aliases: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome",
        "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
        "settings": "System Settings", "system preferences": "System Settings",
        "word": "Microsoft Word", "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint",
        "outlook": "Microsoft Outlook", "teams": "Microsoft Teams", "edge": "Microsoft Edge",
        "brave": "Brave Browser", "app store": "App Store", "finder": "Finder",
        "activity monitor": "Activity Monitor", "terminal": "Terminal",
    ]

    /// The installed app's name for what was said, or nil if nothing fits well.
    static func find(_ spoken: String) -> String? {
        let names = self.names
        let wanted = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        guard wanted.count >= 2 else { return nil }
        if let alias = aliases[wanted], alias == "Finder" || names.contains(alias) { return alias }
        if let exact = names.first(where: { $0.lowercased() == wanted }) { return exact }
        // "photoshop" → "Adobe Photoshop 2025": every word said is in the name,
        // and only one app fits.
        let words = wanted.split(separator: " ").map(String.init)
        let fits = names.filter { name in
            let lowered = name.lowercased()
            return words.allSatisfy { lowered.contains($0) }
        }
        guard wanted.count >= 3, fits.count == 1 else { return nil }
        return fits[0]
    }

    /// An open app for what was said: its exact name, the start of its
    /// name, or an everyday alias. Stricter than "contains", so "go to it"
    /// doesn't switch to an app that happens to have "it" in its name.
    static func running(_ spoken: String) -> String? {
        let wanted = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        guard wanted.count >= 2 else { return nil }
        let open = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        if let exact = open.first(where: { $0.lowercased() == wanted }) { return exact }
        if let alias = aliases[wanted], open.contains(alias) { return alias }
        guard wanted.count >= 3 else { return nil }
        let starts = open.filter { $0.lowercased().hasPrefix(wanted) }
        return starts.count == 1 ? starts[0] : nil
    }


    /// Apps whose name is the text, starts with it, or has a word starting
    /// with it ("code" → Visual Studio Code); best first, shorter names first.
    static func matching(_ text: String, limit: Int) -> [URL] {
        let wanted = text.lowercased().replacingOccurrences(of: ".app", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard wanted.count >= 2 else { return [] }
        let alias = aliases[wanted]?.lowercased()
        let ranked = all.compactMap { app -> (URL, Int)? in
            let name = name(app)
            if name == wanted || name == alias { return (app, 0) }
            if name.hasPrefix(wanted) { return (app, 1) }
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if words.contains(where: { $0.hasPrefix(wanted) }) { return (app, 2) }
            return nil
        }
        return ranked.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : name($0.0).count < name($1.0).count }
            .prefix(limit).map(\.0)
    }
}
