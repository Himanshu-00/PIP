import AppKit

/// Conversations as Markdown, one file a day in `Conversations/`: what was
/// said and which tools ran, never their results.
@MainActor
enum ConversationLog {

    private static let enabledKey = "pipSavesConversations"

    /// On unless turned off in the menu.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var folder: URL {
        AppFolders.support.appendingPathComponent("Conversations")
    }

    enum Speaker { case you, pip, tool }

    static func write(_ speaker: Speaker, _ text: String) {
        guard isEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = Date()
        let time = timeFormatter.string(from: now)
        let line: String
        switch speaker {
        case .you:  line = "\n**\(time) · You:** \(trimmed)\n"
        case .pip:  line = "**Pip:** \(trimmed)\n"
        case .tool: line = "> _\(trimmed)_\n"
        }
        append(line, on: now)
    }

    /// Opens the folder in Finder.
    static func reveal() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Deletes every saved conversation.
    static func deleteAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Files

    private static func append(_ text: String, on date: Date) {
        let file = folder.appendingPathComponent(fileFormatter.string(from: date) + ".md")
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let title = "# Conversations with Pip — \(titleFormatter.string(from: date))\n"
                try Data(title.utf8).write(to: file)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            ActivityLog.write(.error, "couldn't save the conversation: \(error.localizedDescription)")
        }
    }

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}
