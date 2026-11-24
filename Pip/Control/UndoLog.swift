import Foundation

/// The file changes Pip made, kept on disk so "undo" still works after the
/// app quits or the Mac restarts: organising a folder, fixing names,
/// clearing old screenshots off the Desktop.
///
/// The last 20, newest last, in `undo.json` in Application Support — plain
/// JSON, readable by hand. Each entry is every move it made (from → to); a
/// rename is a move within one folder. Undo puts back the newest entry
/// whose files are still where it left them, and removes folders it made
/// that are now empty.
///
/// The first version kept only the last organise, in memory: quitting lost it.
///
/// Files the app *made* (a compressed or merged PDF, a converted picture)
/// are entries too, with `created` paths: undoing one moves them to the
/// Trash, never deletes them.
@MainActor
enum UndoLog {

    struct Move: Codable {
        let from: String
        let to: String
    }

    struct Entry: Codable {
        let id: UUID
        let date: Date
        /// "Organised Downloads", "Renamed 4 files in Downloads".
        let label: String
        let moves: [Move]
        /// Files this change made; undo puts them in the Trash. Optional,
        /// so entries written before it existed still decode.
        var created: [String]? = nil
    }

    private static let keep = 20

    private static var file: URL {
        AppFolders.support.appendingPathComponent("undo.json")
    }

    private static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private static func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(entries.suffix(keep))) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Notes a change; returns its id, for undoing that one in particular.
    @discardableResult
    static func record(_ label: String, moves: [(from: URL, to: URL)]) -> UUID? {
        guard !moves.isEmpty else { return nil }
        let entry = Entry(id: UUID(), date: Date(), label: label,
                          moves: moves.map { Move(from: $0.from.path, to: $0.to.path) })
        save(load() + [entry])
        return entry.id
    }

    /// Notes files the app made, so "undo" can put them in the Trash.
    @discardableResult
    static func recordCreated(_ label: String, files: [URL]) -> UUID? {
        guard !files.isEmpty else { return nil }
        let entry = Entry(id: UUID(), date: Date(), label: label, moves: [], created: files.map(\.path))
        save(load() + [entry])
        return entry.id
    }

    /// Puts back the newest change (or the one with `id`). One sentence
    /// saying what happened.
    static func undo(id: UUID? = nil) -> String {
        var entries = load()
        let found: Int? = if let id { entries.lastIndex { $0.id == id } } else { entries.indices.last }
        guard let index = found else { return "There's nothing to put back." }
        let entry = entries.remove(at: index)
        save(entries)

        let manager = FileManager.default
        if let created = entry.created, !created.isEmpty {
            var trashed = 0
            for path in created where manager.fileExists(atPath: path) {
                if (try? manager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil { trashed += 1 }
            }
            ActivityLog.write(.system, "undo: \(entry.label) — \(trashed) of \(created.count) moved to the Trash")
            guard trashed > 0 else { return "\(entry.label): that file is gone already." }
            return "Undid “\(entry.label)”: moved \(trashed == 1 ? "it" : "\(trashed) files") to the Trash."
        }
        var back = 0
        // Newest move first, so chains (moved, then renamed) unwind in order.
        for move in entry.moves.reversed()
        where manager.fileExists(atPath: move.to) && !manager.fileExists(atPath: move.from) {
            if (try? manager.moveItem(atPath: move.to, toPath: move.from)) != nil { back += 1 }
        }
        // Folders the change made, now empty.
        for folder in Set(entry.moves.map { ($0.to as NSString).deletingLastPathComponent })
        where !Set(entry.moves.map { ($0.from as NSString).deletingLastPathComponent }).contains(folder) {
            let left = (try? manager.contentsOfDirectory(atPath: folder))?.filter { !$0.hasPrefix(".") } ?? []
            if left.isEmpty { try? manager.removeItem(atPath: folder) }
        }
        ActivityLog.write(.system, "undo: \(entry.label) — \(back) of \(entry.moves.count) put back")
        guard back > 0 else { return "\(entry.label): those files have moved since, so I left them." }
        let when = entry.date.formatted(.relative(presentation: .named))
        return "Undid “\(entry.label)” (\(when)): \(back) file\(back == 1 ? "" : "s") back where they were."
    }
}
