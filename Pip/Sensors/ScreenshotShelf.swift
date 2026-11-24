import AppKit
import ImageIO
import Combine

/// The last few screenshots, in the hover panel, to drag, copy or pin. A view
/// onto the folder macOS saves them in — nothing is copied. Design notes: Docs/history/Sensors.md.
@MainActor
final class ScreenshotShelf: ObservableObject {

    struct Shot: Identifiable, Equatable {
        let url: URL
        let taken: Date
        let thumbnail: NSImage?
        var pinned: Bool = false
        var id: URL { url }

        static func == (lhs: Shot, rhs: Shot) -> Bool {
            lhs.url == rhs.url && lhs.taken == rhs.taken && lhs.pinned == rhs.pinned
        }
    }

    @Published private(set) var shots: [Shot] = []

    /// How many the shelf shows.
    private let limit = 8

    /// How far back it looks.
    private let maximumAge: TimeInterval = 24 * 60 * 60

    private var watcher: DirectoryWatcher?
    private var folder: URL?

    /// Pinned paths: kept whatever their age, across relaunches.
    private var pinnedPaths: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.pinKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.pinKey) }
    }
    private static let pinKey = "shelfPinnedScreenshots"

    // MARK: - Lifecycle

    func start() {
        let folder = Self.saveLocation()
        self.folder = folder
        refresh()

        watcher = DirectoryWatcher(url: folder, debounce: 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        watcher?.close()
        watcher = nil
        shots = []
    }

    // MARK: - Actions

    /// The picture and its file on the clipboard.
    @discardableResult
    func copyImage(_ shot: Shot) -> Bool {
        guard let image = NSImage(contentsOf: shot.url) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([image, shot.url as NSURL])
        return true
    }

    /// The words in the picture on the clipboard (search's OCR).
    func copyText(_ shot: Shot) async -> Bool {
        let text = await TextExtractor.text(inImageAt: shot.url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    func togglePin(_ shot: Shot) {
        var paths = pinnedPaths
        if paths.contains(shot.url.path) {
            paths.remove(shot.url.path)
        } else {
            paths.insert(shot.url.path)
        }
        pinnedPaths = paths
        refresh()
    }

    // MARK: - Where macOS puts them

    /// Where macOS saves screenshots (`com.apple.screencapture location`), else
    /// the Desktop. Safe from any thread.
    nonisolated static func saveLocation() -> URL {
        let desktop = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop")

        guard let raw = UserDefaults(suiteName: "com.apple.screencapture")?
                .string(forKey: "location"),
              !raw.isEmpty
        else { return desktop }

        let expanded = (raw as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("file:")
            ? (URL(string: expanded) ?? desktop)
            : URL(fileURLWithPath: expanded)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return desktop }
        return url
    }

    // MARK: - Reading the folder

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

    private func refresh() {
        guard let folder else { return }

        let keys: Set<URLResourceKey> = [.creationDateKey, .isDirectoryKey, .nameKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []

        let cutoff = Date.now.addingTimeInterval(-maximumAge)

        // A recent image in the folder counts (the "Screenshot" name is localised).
        let pins = pinnedPaths
        let recent = entries.compactMap { url -> Shot? in
            guard Self.imageExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory != true,
                  let created = values.creationDate
            else { return nil }
            let pinned = pins.contains(url.path)
            guard pinned || created > cutoff else { return nil }
            return Shot(url: url, taken: created, thumbnail: nil, pinned: pinned)
        }
        // Pinned first, then newest.
        .sorted { left, right in
            left.pinned == right.pinned ? left.taken > right.taken : left.pinned
        }
        .prefix(limit)

        // Reuse decoded thumbnails.
        let existing = Dictionary(uniqueKeysWithValues: shots.map { ($0.url, $0.thumbnail) })
        shots = recent.map { shot in
            if let thumbnail = existing[shot.url] {
                return Shot(url: shot.url, taken: shot.taken,
                            thumbnail: thumbnail, pinned: shot.pinned)
            }
            return Shot(url: shot.url, taken: shot.taken,
                        thumbnail: Self.thumbnail(for: shot.url), pinned: shot.pinned)
        }
    }

    /// A thumbnail decoded at drawing size (not the full image).
    private static func thumbnail(for url: URL, maximumPixel: Int = 160) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
