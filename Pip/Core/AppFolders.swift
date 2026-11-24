import Foundation

/// The app's folders: ~/Library/Application Support/Pip, Logs/Pip and
/// Caches/Pip App — not Caches/Pip, which is Python's pip cache (folder names
/// ignore case). Until 2026-11-22 they were called DynamicNotch; the first
/// time each is used, an old one is moved to the new name, so models,
/// indexes, conversations and logs carry over. If the move fails, the old
/// folder keeps being used rather than starting empty.
enum AppFolders {

    static let name = "Pip"
    private static let oldName = "DynamicNotch"

    static let support = folder(in: "Library/Application Support")
    static let logs = folder(in: "Library/Logs")
    static let caches = folder(in: "Library/Caches", named: "Pip App")

    private static func folder(in parent: String, named: String = name) -> URL {
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(parent)
        let new = base.appendingPathComponent(named)
        let old = base.appendingPathComponent(oldName)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: new.path), manager.fileExists(atPath: old.path) else { return new }
        do {
            try manager.moveItem(at: old, to: new)
            return new
        } catch {
            return old
        }
    }
}
