import AppKit

/// What click to ask says about a target, from the fast path only: the
/// index, Accessibility, and the Neural Engine's text reader and picture
/// labels. No language model here — that's the card's optional vision line.
struct ClickAnswer {

    let target: ClickToAsk.Target
    /// One line: the file's name, or what kind of thing was clicked.
    var title: String
    /// One to three lines of answer.
    var lines: [String]
    /// What the picture shows (images, regions, image files).
    var labels: [String] = []
    /// The words in it: OCR'd, read through Accessibility, or a file's text.
    var text = ""
    /// A file on the Mac that the clicked text names.
    var match: URL?
    /// The title of the window it was in (a browser's page title).
    var source: String?

    /// What the panel shows before `make` is done: what kind of thing, no lines yet.
    static func pending(_ target: ClickToAsk.Target) -> ClickAnswer {
        switch target {
        case .image:  return ClickAnswer(target: target, title: "Image", lines: [])
        case .region: return ClickAnswer(target: target, title: "Area", lines: [])
        case .text(let text, _):
            return ClickAnswer(target: target, title: text.split(whereSeparator: \.isWhitespace).count > 25 ? "Paragraph" : "Text",
                               lines: [], text: text)
        case .file(let url): return ClickAnswer(target: target, title: url.lastPathComponent, lines: [])
        }
    }

    static func make(for target: ClickToAsk.Target) async -> ClickAnswer {
        switch target {
        case .file(let url):
            return await file(url, target: target)
        case .image(let image, _), .region(let image):
            let described = await within(5) { await TextExtractor.describe(image) }
            let (labels, text) = described ?? ([], "")
            var lines: [String] = []
            if !labels.isEmpty { lines.append("Shows " + labels.prefix(5).joined(separator: ", ")) }
            if let first = firstUseful(text) { lines.append("“\(first)”") }
            // Vision not answering: no lines — Pip's own look says what it is.
            if described != nil, lines.isEmpty { lines.append("Nothing I can name or read here.") }
            let isImage: Bool
            if case .image = target { isImage = true } else { isImage = false }
            // What kind of thing, for the side chat's header: "Diagram",
            // "Photo". ("Photo · person in a suit" until 2026-11-21; what it
            // shows is the answer's job now.)
            let title = kind(of: labels) ?? (isImage ? "Image" : "Area")
            return ClickAnswer(target: target, title: title, lines: lines, labels: labels, text: text)
        case .text(let text, _):
            let words = text.split(whereSeparator: \.isWhitespace).count
            var answer = ClickAnswer(target: target, title: words > 25 ? "Paragraph" : "Text",
                                     lines: [String(text.prefix(220)).replacingOccurrences(of: "\n", with: " ")],
                                     text: text)
            if let found = await fileNamed(in: text) {
                answer.match = found
                answer.lines.append("On your Mac: \(found.lastPathComponent)")
            }
            return answer
        }
    }

    /// `work`'s result, or nil after `seconds` (Vision's compiler service can
    /// hang for good; the work is left running).
    static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task { once.finish(await work()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.finish(nil)
            }
        }
    }

    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

        func finish(_ value: T?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    // MARK: - Files

    private static func file(_ url: URL, target: ClickToAsk.Target) async -> ClickAnswer {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                                        .localizedTypeDescriptionKey])
        let date = values?.contentModificationDate.map {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)
        }
        if values?.isDirectory == true {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") }.count ?? 0
            let meta = ["Folder", "\(count) item\(count == 1 ? "" : "s")", date].compactMap { $0 }.joined(separator: " · ")
            return ClickAnswer(target: target, title: url.lastPathComponent, lines: [meta])
        }

        var lines: [String] = []
        var labels: [String] = []
        var text = ""
        let isImage = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"].contains(url.pathExtension.lowercased())
        if isImage, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 1600,
           ] as CFDictionary) {
            (labels, text) = await TextExtractor.describe(image)
            if !labels.isEmpty { lines.append("Shows " + labels.prefix(5).joined(separator: ", ")) }
        } else {
            // From the index; read now (and stored, as usual) if it isn't there.
            var title: String?
            var headings: [String] = []
            if let record = await ContentStore.shared.record(path: url.path, modified: nil, anyDate: true) {
                title = record.title
                text = record.text
                headings = record.headings?.split(separator: "\n").map(String.init) ?? []
            } else {
                let candidate = Candidate(url: url, displayName: url.lastPathComponent,
                                          modified: values?.contentModificationDate, lastOpened: nil,
                                          useCount: 0, whereFrom: nil)
                let extracted = await TextExtractor().texts(for: [candidate])[url]
                title = extracted?.title
                text = extracted?.text ?? ""
                headings = extracted?.headings ?? []
            }
            if let title, !title.isEmpty, title != url.deletingPathExtension().lastPathComponent {
                lines.append(title)
            }
            if !headings.isEmpty {
                lines.append(headings.prefix(4).joined(separator: " · "))
            }
        }
        if lines.count < 2, let first = firstUseful(text) { lines.append("“\(first)”") }

        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        lines.append([values?.localizedTypeDescription, size, date].compactMap { $0 }.joined(separator: " · "))
        return ClickAnswer(target: target, title: url.lastPathComponent, lines: Array(lines.suffix(3)),
                           labels: labels, text: text)
    }

    /// Picture labels (Apple's classifier) that say what kind of picture it
    /// is, in the order they win; any other label means a photo.
    private static let kinds: [(label: String, name: String)] = [
        ("diagram", "Diagram"), ("chart", "Chart"), ("graph", "Chart"), ("map", "Map"),
        ("screenshot", "Screenshot"), ("document", "Document"), ("handwriting", "Handwriting"),
        ("text", "Text"), ("illustration", "Illustration"), ("drawing", "Drawing"),
        ("cartoon", "Illustration"), ("painting", "Painting"), ("poster", "Poster"), ("logo", "Logo"),
    ]

    /// "Diagram", "Photo", … — nil when there are no labels.
    static func kind(of labels: [String]) -> String? {
        guard !labels.isEmpty else { return nil }
        let lowered = Set(labels.map { $0.lowercased() })
        return kinds.first { lowered.contains($0.label) }?.name ?? "Photo"
    }

    /// The first line that reads like a sentence rather than a header.
    private static func firstUseful(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count >= 20 }
            .map { String($0.prefix(140)) }
    }

    // MARK: - A file named in text

    /// "Invoice_0425", "report-final.pdf": words that look like file names.
    /// Ordinary words aren't looked up — every sentence would "find" a file.
    private static func fileNamed(in text: String) async -> URL? {
        let pattern = #"[\p{L}\p{N}][\p{L}\p{N}_\-]*(?:[_\-][\p{L}\p{N}]+)+(?:\.[A-Za-z0-9]{2,5})?|[\p{L}\p{N}][\p{L}\p{N}_\- ]*\.(?:pdf|docx?|xlsx?|pptx?|key|pages|numbers|txt|md|csv|png|jpe?g|heic|zip)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        let names = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 4 }
        for name in names.prefix(3) {
            let stem = (name as NSString).deletingPathExtension.lowercased()
            let found = await FileFinder.find(name, limit: 1)
            if let url = found.first,
               url.deletingPathExtension().lastPathComponent.lowercased().contains(stem) {
                return url
            }
        }
        return nil
    }
}
