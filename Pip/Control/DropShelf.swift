import AppKit
import Combine

/// Files parked in the notch: references by path (gone when the file is),
/// checked when the panel opens, at most 20, kept across restarts.
@MainActor
final class DropShelf: ObservableObject {

    static let shared = DropShelf()

    struct Item: Identifiable, Equatable {
        let url: URL
        var id: URL { url }
    }

    @Published private(set) var items: [Item] = []

    private let limit = 20
    private let location = AppFolders.support.appendingPathComponent("drop-shelf.json")

    private init() {
        let paths = (try? Data(contentsOf: location)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        items = paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { Item(url: URL(fileURLWithPath: $0)) }
    }

    /// Adds files to the end, skipping ones already here. Folders too: a
    /// folder dragged into Finder or an upload box is as useful as a file.
    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url.path))
        let fresh = urls.map(\.standardizedFileURL)
            .filter { !known.contains($0.path) && FileManager.default.fileExists(atPath: $0.path) }
        guard !fresh.isEmpty else { return }
        var next = items + fresh.map { Item(url: $0) }
        if next.count > limit { next.removeFirst(next.count - limit) }
        set(next)
        ActivityLog.write(.system, "drop shelf: kept \(fresh.map(\.lastPathComponent).joined(separator: ", ")) "
                          + "(\(next.count) on the shelf)")
    }

    func remove(_ url: URL, why: String) {
        guard items.contains(where: { $0.url == url }) else { return }
        set(items.filter { $0.url != url })
        ActivityLog.write(.system, "drop shelf: \(url.lastPathComponent) left — \(why)")
    }

    /// Files moved or deleted since they were parked leave the shelf.
    func refresh() {
        let present = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if present.count != items.count { set(present) }
    }

    private func set(_ next: [Item]) {
        guard next != items else { return }
        items = next
        do {
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(next.map(\.url.path)).write(to: location, options: .atomic)
        } catch {
            ActivityLog.write(.error, "drop shelf: couldn't save — \(error.localizedDescription)")
        }
    }
}
