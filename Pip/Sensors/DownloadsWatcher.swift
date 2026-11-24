import AppKit

/// Announces finished downloads in ~/Downloads: part-files are skipped and a
/// file counts once its size stops changing. Design notes: Docs/history/Sensors.md.
@MainActor
final class DownloadsWatcher: ObservableObject {

    /// The most recent finished download, for as long as the island shows it.
    @Published private(set) var latest: URL?

    var onFinished: ((URL) -> Void)?

    /// Extensions of downloads still in progress.
    private static let partial: Set<String> = [
        "crdownload", "download", "part", "partial", "tmp", "temp", "opdownload", "!ut"
    ]

    private let folder = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Downloads")

    private var watcher: DirectoryWatcher?
    private var known: Set<String> = []
    private var settling: Set<String> = []

    func start() {
        guard watcher == nil else { return }
        // What's there at launch isn't announced.
        known = Set(contents().map(\.lastPathComponent))
        watcher = DirectoryWatcher(url: folder) { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    func stop() {
        watcher?.close()
        watcher = nil
        settling.removeAll()
    }

    func clearLatest() { latest = nil }

    // MARK: - Scanning

    private func contents() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    private func scan() {
        let current = contents()
        let names = Set(current.map(\.lastPathComponent))

        for url in current {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            guard !known.contains(name),
                  !settling.contains(name),
                  // Folders have no size to settle on.
                  !isDirectory,
                  !Self.partial.contains(url.pathExtension.lowercased())
            else { continue }

            settling.insert(name)
            waitUntilSettled(url)
        }

        // Forget names that are gone (part-files renamed).
        known.formIntersection(names)
        known.formUnion(names.subtracting(settling))
    }

    /// Done once its size holds for 0.5 s (up to 60 tries).
    private func waitUntilSettled(_ url: URL, attempt: Int = 0) {
        let size = Self.size(of: url)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let name = url.lastPathComponent

                guard FileManager.default.fileExists(atPath: url.path) else {
                    self.settling.remove(name)      // renamed or cancelled
                    return
                }

                let now = Self.size(of: url)
                if now != size || now == 0, attempt < 60 {
                    self.waitUntilSettled(url, attempt: attempt + 1)
                    return
                }

                self.settling.remove(name)
                self.known.insert(name)
                self.latest = url
                self.onFinished?(url)
            }
        }
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
