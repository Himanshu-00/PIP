import AppKit

/// Everything DynamicNotch and Pip do, in a plain text file — one per day in
/// `~/Library/Logs/Pip/` (also readable in the Console app under
/// Log Reports). Kept for 7 days, then deleted (14 kept a fortnight of
/// pasted mail and bookings); "Delete Activity Logs…" clears them.
///
/// What's in it: what you asked, every tool Pip ran (with its arguments and
/// a short piece of its result), anything he was blocked from doing, every
/// "are you sure?" and its answer, brain and voice loading, speeds,
/// downloads, permissions, hotkeys, and errors. What's not: screenshots,
/// full page text, pasted or copied text (only its length), or more than
/// 200 characters of a reply or result. It never leaves the Mac.
///
/// Safe to call from any thread: writes go through one serial queue.
enum ActivityLog {

    enum Category: String {
        case request = "ASK"
        case tool = "TOOL"
        case result = "RESULT"
        case blocked = "BLOCKED"
        case confirm = "CONFIRM"
        case reply = "REPLY"
        case brain = "BRAIN"
        case voice = "VOICE"
        case vision = "VISION"
        case download = "DOWNLOAD"
        case search = "SEARCH"
        case system = "SYSTEM"
        case error = "ERROR"
    }

    static var folder: URL {
        AppFolders.logs
    }

    private static let queue = DispatchQueue(label: "DynamicNotch.ActivityLog", qos: .utility)
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var currentDay = ""
    nonisolated(unsafe) private static var cleaned = false

    /// Writes one line, and echoes it to the Xcode console.
    static func write(_ category: Category, _ message: String) {
        let now = Date()
        let flat = message.replacingOccurrences(of: "\n", with: " ⏎ ")
        // Xcode's console only: NSLog also lands in the system log.
        #if DEBUG
        NSLog("[Pip] \(category.rawValue) \(flat)")
        #endif
        queue.async {
            let day = dayFormatter.string(from: now)
            let line = "\(timeFormatter.string(from: now))  \(category.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(flat)\n"
            if day != currentDay || handle == nil { open(day) }
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }

    /// A shortened copy of long text (tool results, page text).
    static func short(_ text: String, _ limit: Int = 300) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    static func reveal() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let today = folder.appendingPathComponent("activity-\(dayFormatter.string(from: .now)).log")
        if FileManager.default.fileExists(atPath: today.path) {
            NSWorkspace.shared.activateFileViewerSelecting([today])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    // MARK: - Files (on the queue)

    private static func open(_ day: String) {
        try? handle?.close()
        handle = nil
        currentDay = day
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("activity-\(day).log")
        if !manager.fileExists(atPath: file.path) {
            manager.createFile(atPath: file.path, contents: Data("# Pip activity — \(day)\n".utf8))
        }
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
        if !cleaned { cleaned = true; removeOldLogs() }
    }

    private static func removeOldLogs() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in files where file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            if Date.now.timeIntervalSince(modified) > 7 * 86_400 { try? manager.removeItem(at: file) }
        }
    }

    /// Every log file, now; the next line starts a fresh one.
    static func deleteAll() {
        queue.async {
            try? handle?.close()
            handle = nil
            currentDay = ""
            let manager = FileManager.default
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "log" { try? manager.removeItem(at: file) }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
