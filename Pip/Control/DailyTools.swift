import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Everyday jobs for Pip (notes, clipboard, screenshots, files and
/// folders), each returning a short sentence for the model.
@MainActor
enum DailyTools {

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    // MARK: - Notes

    static func newNote(title: String, body: String) async -> String {
        let html = "<h1>\(escapeHTML(title))</h1>" + escapeHTML(body).replacingOccurrences(of: "\n", with: "<br>")
        let script = "tell application \"Notes\" to make new note with properties {body:\(literal(html))}"
        let result = await AppleScript.run(script)
        return result.ok ? "Made a note: \(title.isEmpty ? "untitled" : title)."
            : "Couldn't make the note — allow Pip to control Notes in Privacy & Security ▸ Automation."
    }

    // MARK: - Clipboard

    static func readClipboard() -> String {
        // A password or one-time code: not read, not sent to the model.
        guard !ClipboardWatch.isPrivate(.general) else { return "What's copied is marked private (a password), so I won't read it." }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return "The clipboard has no text."
        }
        return "Clipboard: " + String(text.prefix(3000))
    }

    // MARK: - Screenshots

    /// Saves a screenshot to the Desktop (Pip's own window left out).
    static func saveScreenshot(window: Bool) async -> (message: String, file: URL?) {
        do {
            let image = try await ScreenCapture.capture(window ? .frontWindow : .screen)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let file = home.appendingPathComponent("Desktop/Screenshot \(formatter.string(from: .now)).png")
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return ("Couldn't save the screenshot.", nil) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return ("Couldn't save the screenshot.", nil) }
            return ("Saved a screenshot to the Desktop: \(file.lastPathComponent) — path: \(file.path)", file)
        } catch {
            return (error.localizedDescription, nil)
        }
    }

    // MARK: - Files and folders

    /// "desktop", "documents", "downloads", "home", or a path inside the home folder.
    static func place(_ text: String) -> URL? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        switch lowered {
        case "", "desktop": return home.appendingPathComponent("Desktop")
        case "documents": return home.appendingPathComponent("Documents")
        case "downloads": return home.appendingPathComponent("Downloads")
        case "home": return home
        default:
            // "Downloads/PIPL": from the home folder, like "~/Downloads/PIPL".
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let full = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") ? trimmed : "~/" + trimmed
            // Links resolved first: one in Downloads can point anywhere.
            let url = URL(fileURLWithPath: (full as NSString).expandingTildeInPath).standardizedFileURL
                .resolvingSymlinksInPath()
            return url.path.hasPrefix(home.path + "/") && !isOffLimits(url) ? url : nil
        }
    }

    /// Never written into or taken from: ~/Library, hidden and developer
    /// folders (search's own exclusions), the URL itself checked as a folder.
    static func isOffLimits(_ url: URL) -> Bool {
        // Apps, and anything inside one: moving or changing an app is what
        // macOS's App Management permission guards, and Pip never needs it.
        if url.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) { return true }
        return DirectScan.isExcluded(url.appendingPathComponent("x").path)
    }

    static func createFolder(name: String, in location: String) -> (message: String, file: URL?) {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return ("What should the folder be called?", nil) }
        guard let parent = place(location) else { return ("I can only make folders inside your home folder.", nil) }
        let folder = parent.appendingPathComponent(cleaned)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return ("Made the folder \(cleaned) — path: \(folder.path)", folder)
        } catch {
            return ("Couldn't make the folder: \(error.localizedDescription)", nil)
        }
    }

    static func move(_ file: URL, to location: String) -> (message: String, file: URL?) {
        guard !isOffLimits(file) else { return (Self.leftAlone(file), nil) }
        guard let folder = place(location) else { return ("I can only move things within your home folder.", nil) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(file.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return ("There's already a \(file.lastPathComponent) there.", nil)
        }
        do {
            try FileManager.default.moveItem(at: file, to: destination)
            return ("Moved \(file.lastPathComponent) — path: \(destination.path)", destination)
        } catch {
            return ("Couldn't move it: \(error.localizedDescription)", nil)
        }
    }

    /// Copies a file into a folder, never overwriting ("name 2.png" if taken).
    /// Returns the copy's own path, so it can be renamed next.
    static func copy(_ file: URL, to location: String) -> (message: String, file: URL?) {
        guard !isOffLimits(file) else { return (Self.leftAlone(file), nil) }
        guard let folder = place(location) else { return ("I can only copy things within your home folder.", nil) }
        let manager = FileManager.default
        let stem = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var destination = folder.appendingPathComponent(file.lastPathComponent)
        var number = 2
        while manager.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            number += 1
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.copyItem(at: file, to: destination)
            return ("Copied \(file.lastPathComponent) — path: \(destination.path)", destination)
        } catch {
            return ("Couldn't copy it: \(error.localizedDescription)", nil)
        }
    }

    /// Renames a file where it is. Keeps the extension when the new name
    /// has none ("2026-10-15 rent" → "2026-10-15 rent.png"); never overwrites.
    static func rename(_ file: URL, to name: String) -> (message: String, file: URL?) {
        guard !isOffLimits(file) else { return (Self.leftAlone(file), nil) }
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return ("What should it be called?", nil) }
        let ext = file.pathExtension
        if !ext.isEmpty, (cleaned as NSString).pathExtension.lowercased() != ext.lowercased() {
            cleaned += "." + ext
        }
        let destination = file.deletingLastPathComponent().appendingPathComponent(cleaned)
        guard destination.path != file.path else { return ("It's already called that.", file) }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return ("There's already a file called \(cleaned) there.", nil)
        }
        do {
            try FileManager.default.moveItem(at: file, to: destination)
            return ("Renamed to \(cleaned) — path: \(destination.path)", destination)
        } catch {
            return ("Couldn't rename it: \(error.localizedDescription)", nil)
        }
    }

    /// Where a collection folder goes: the given path, else beside most of the
    /// files. An existing folder is reused, whatever its capitals.
    static func collectionFolder(named name: String, near files: [URL]) -> URL? {
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.contains("/") || cleaned.hasPrefix("~") { return place(cleaned) }
        if ["desktop", "documents", "downloads"].contains(cleaned.lowercased()) { return place(cleaned) }
        let homeParts = home.standardizedFileURL.pathComponents
        var counts: [String: Int] = [:]
        for file in files {
            let parts = file.standardizedFileURL.pathComponents
            guard parts.count > homeParts.count + 1, Array(parts.prefix(homeParts.count)) == homeParts else { continue }
            counts[parts[homeParts.count], default: 0] += 1
        }
        let top = counts.max { $0.value < $1.value }?.key ?? "Documents"
        let parent = home.appendingPathComponent(top)
        let wanted = cleaned.replacingOccurrences(of: ":", with: "-")
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
            .first { $0.lastPathComponent.lowercased() == wanted.lowercased()
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let folder = existing ?? parent.appendingPathComponent(wanted)
        return isOffLimits(folder) ? nil : folder
    }

    /// Copies (or moves) every file into the folder, making it if needed. A
    /// name already taken gets " 2", " 3"… — nothing is ever overwritten.
    static func collect(_ files: [URL], into folder: URL, move: Bool) -> (message: String, file: URL?) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return ("Couldn't make the folder: \(error.localizedDescription)", nil)
        }
        var done = 0
        var failed = 0
        var moves: [(from: URL, to: URL)] = []
        for file in files where !isOffLimits(file) {
            let stem = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            var destination = folder.appendingPathComponent(file.lastPathComponent)
            var number = 2
            while manager.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
                number += 1
            }
            do {
                if move {
                    try manager.moveItem(at: file, to: destination)
                    moves.append((file, destination))
                } else {
                    try manager.copyItem(at: file, to: destination)
                }
                done += 1
            } catch {
                failed += 1
            }
        }
        // Moves can be put back ("undo"); copies leave the originals anyway.
        UndoLog.record("Moved \(moves.count) files into \(folder.lastPathComponent)", moves: moves)
        let verb = move ? "Moved" : "Copied"
        let problem = failed > 0 ? " (\(failed) couldn't be \(move ? "moved" : "copied"))" : ""
        return ("\(verb) \(done) file\(done == 1 ? "" : "s") into \(folder.lastPathComponent)\(problem) — path: \(folder.path)",
                folder)
    }

    /// To the Trash, not deleted — it can be put back.
    static func trash(_ file: URL) -> String {
        guard !isOffLimits(file) else { return Self.leftAlone(file) }
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            return "Moved \(file.lastPathComponent) to the Trash."
        } catch {
            return "Couldn't move it to the Trash: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    /// Why a file was refused (an app, or a private folder), for the model.
    private static func leftAlone(_ file: URL) -> String {
        file.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") })
            ? "Not done: \(file.lastPathComponent) is an app — I don't move, rename or delete apps."
            : "Not done: \(file.lastPathComponent) is in a private folder I don't touch."
    }

    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
