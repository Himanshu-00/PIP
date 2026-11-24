import AppKit
import PDFKit
@preconcurrency import Vision
import NaturalLanguage

/// Gets the words out of a file, only when a search reaches it, capped.
actor TextExtractor {

    /// Enough to characterise a document, cheap enough to embed.
    private let characterLimit = 4_000
    /// Beyond this many pages, read the front and stop. A thesis and a
    /// three-page memo should cost about the same to look at.
    private let pageLimit = 12

    /// A file's text; the title is kept apart (it's weighed like a name).
    struct Extracted {
        var text: String
        var title: String?
        /// Every section heading in the document, in order — "Abstract",
        /// "3.2 Scaled Dot-Product Attention", "Results". Searched with more
        /// weight than the body: a heading says what a whole section is about.
        var headings: [String] = []
        var isEmpty: Bool { text.isEmpty }
    }

    private var cache: [String: Extracted] = [:]
    /// Insertion order, for oldest-first eviction.
    private var order: [String] = []
    /// Roughly 4 KB of text each, so three hundred entries is about a
    /// megabyte. The sweep can open four hundred files in one search, and an
    /// unbounded dictionary of their contents is a leak with extra steps.
    private let cacheLimit = 300

    /// Files that can't be read, so a failing PDF isn't retried on every
    /// keystroke. Cleared with the cache.
    private var failed: Set<String> = []

    /// Memory, then the disk store, then opening the file.
    func text(for candidate: Candidate) async -> Extracted {
        let key = candidate.cacheKey
        if let hit = cache[key] { return hit }
        if failed.contains(key) { return Extracted(text: "", title: nil) }

        // Disk. `record` checks the modification date itself, so an edited
        // file misses here and falls through to a fresh read.
        if let stored = await ContentStore.shared.record(path: candidate.url.path,
                                                        modified: candidate.modified) {
            let extracted = Extracted(text: stored.text, title: stored.title,
                                      headings: stored.headings?.components(separatedBy: "\n") ?? [])
            remember(key, extracted)
            await ContentStore.shared.touch(path: candidate.url.path)
            return extracted
        }

        let extracted = await Self.extract(candidate,
                                           characterLimit: characterLimit,
                                           pageLimit: pageLimit)
        if extracted.isEmpty {
            failed.insert(key)
            // Bounded too. A folder of four hundred scanned PDFs would
            // otherwise grow this set forever.
            if failed.count > cacheLimit * 2 { failed.removeAll() }
            // Noted as unreadable so the indexer stops picking it.
            await ContentStore.shared.markUnreadable(path: candidate.url.path,
                                                     modified: candidate.modified)
        } else {
            remember(key, extracted)
            await ContentStore.shared.store(path: candidate.url.path,
                                            modified: candidate.modified,
                                            title: extracted.title,
                                            headings: extracted.headings.joined(separator: "\n"),
                                            text: extracted.text)
            // Meaning vectors, detached so they never delay results.
            let path = candidate.url.path
            let modified = candidate.modified
            let title = extracted.title
            let text = extracted.text
            Task.detached(priority: .utility) {
                await SemanticIndex.shared.add(path: path, modified: modified,
                                               title: title, text: text)
            }
        }
        return extracted
    }

    private func remember(_ key: String, _ extracted: Extracted) {
        cache[key] = extracted
        order.append(key)
        if order.count > cacheLimit {
            let evict = order.removeFirst()
            cache.removeValue(forKey: evict)
        }
    }

    /// Many files, four at a time.
    func texts(for candidates: [Candidate], parallel: Int = 4) async -> [URL: Extracted] {
        var out: [URL: Extracted] = [:]
        var index = 0

        while index < candidates.count {
            let slice = candidates[index..<min(index + parallel, candidates.count)]
            await withTaskGroup(of: (URL, Extracted).self) { group in
                for candidate in slice {
                    group.addTask { [self] in (candidate.url, await text(for: candidate)) }
                }
                for await (url, value) in group { out[url] = value }
            }
            index += parallel
        }
        return out
    }

    /// Drops all but a recent working set (when the panel closes).
    func trim(to keep: Int = 40) {
        guard order.count > keep else { return }
        for key in order.prefix(order.count - keep) { cache.removeValue(forKey: key) }
        order.removeFirst(order.count - keep)
        failed.removeAll()
    }

    /// Most of a document (~60,000 characters) for "Ask your files"; never stored.
    static func deepText(of candidate: Candidate) async -> String {
        guard !candidate.isImage else { return "" }
        return await extract(candidate, characterLimit: 60_000, pageLimit: 40).text
    }

    // MARK: - The actual reading

    private static func extract(_ candidate: Candidate,
                                characterLimit: Int,
                                pageLimit: Int) async -> Extracted {
        if candidate.isPDF {
            return await pdf(candidate.url, characterLimit: characterLimit, pageLimit: pageLimit)
        }
        if candidate.isImage {
            // What it says (OCR) and what it shows (labels), from one decode.
            guard let source = CGImageSourceCreateWithURL(candidate.url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return Extracted(text: "", title: nil)
            }
            let words = await ocr(image, characterLimit: characterLimit)
            let labels = await pictureLabels(image)
            let shows = labels.isEmpty ? "" : "Picture of: " + labels.joined(separator: ", ") + ".\n"
            return Extracted(text: shows + words, title: nil, headings: labels)
        }
        // Headings from whatever structure the format has.
        let extension_ = candidate.url.pathExtension.lowercased()
        var body = ""
        var title: String?
        var headings: [String] = []
        if zippedXMLExtensions.contains(extension_) {
            body = zippedXML(candidate.url, characterLimit: characterLimit)
            (title, headings) = officeOutline(candidate.url, extension_: extension_)
        } else if richTextExtensions.contains(extension_) {
            (body, headings) = richTextWithHeadings(candidate.url, characterLimit: characterLimit)
        } else {
            body = plain(candidate.url, characterLimit: characterLimit)
            headings = headingLines(in: rawText(candidate.url), extension_: extension_)
        }
        return Extracted(text: body, title: title ?? heading(in: body), headings: headings)
    }

    /// Formats AppKit can read and a byte-level read can't (.docx is a zip).
    private static let richTextExtensions: Set<String> = [
        "docx", "doc", "rtf", "rtfd", "html", "htm", "odt", "webarchive"
    ]

    /// Office formats that are zipped XML, which `NSAttributedString` can't open.
    private static let zippedXMLExtensions: Set<String> = ["pptx", "xlsx"]

    /// The archive members that hold the words (slides and notes; shared strings).
    private static func archiveMembers(for extension_: String) -> [String] {
        switch extension_ {
        case "pptx": return ["ppt/slides/slide*.xml", "ppt/notesSlides/notesSlide*.xml"]
        case "xlsx": return ["xl/sharedStrings.xml"]
        default:     return []
        }
    }

    /// A zipped-XML document via `unzip -p` to stdout, tags stripped.
    private static func zippedXML(_ url: URL, characterLimit: Int) -> String {
        let members = archiveMembers(for: url.pathExtension.lowercased())
        guard !members.isEmpty else { return "" }

        let result = ScriptBridge.run("/usr/bin/unzip", ["-p", url.path] + members, timeout: 5)
        guard result.status == 0, !result.output.isEmpty else { return "" }

        // Paragraph and row ends become spaces before the tags go, so words
        // either side of a boundary don't get welded into one token.
        var text = result.output
        for boundary in ["</a:p>", "</a:t>", "</si>", "</t>", "<a:br/>"] {
            text = text.replacingOccurrences(of: boundary, with: "\(boundary) ")
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ",
                                         options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&apos;", "'")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return clean(text, limit: characterLimit)
    }

    private static func pdf(_ url: URL, characterLimit: Int, pageLimit: Int) async -> Extracted {
        guard let document = PDFDocument(url: url) else {
            return Extracted(text: "", title: nil)
        }

        // Metadata first, prepended.
        let (header, title) = attributes(of: document)

        var collected = header.isEmpty ? "" : header + ". "
        for index in 0..<min(document.pageCount, pageLimit) {
            guard let page = document.page(at: index), let text = page.string else { continue }
            collected += text + "\n"
            if collected.count >= characterLimit { break }
        }

        var cleaned = clean(collected, limit: characterLimit)
        // Falls back to the first line when the metadata field is absent or
        // was one of the generator's placeholders.
        var bestTitle = title ?? pageOneTitle(document) ?? heading(in: collected)

        // A scan: no text layer, so the first pages are rendered and OCRed.
        guard cleaned.count - header.count < 60 else {
            return Extracted(text: cleaned, title: bestTitle, headings: headings(of: document))
        }

        var scanned = header.isEmpty ? "" : header + ". "
        for index in 0..<min(document.pageCount, 3) {
            guard let page = document.page(at: index),
                  let image = render(page) else { continue }
            scanned += await ocr(image, characterLimit: characterLimit) + "\n"
            if scanned.count >= characterLimit { break }
        }
        cleaned = clean(scanned, limit: characterLimit)
        // A scan's first recognised line is its heading just as much.
        bestTitle = title ?? heading(in: scanned)
        return Extracted(text: cleaned, title: bestTitle, headings: headingLines(in: scanned))
    }

    // MARK: - Headings

    /// The biggest line on page one (a title can wrap); arXiv's sideways stamp
    /// and lines of numbers are skipped.
    private static func pageOneTitle(_ document: PDFDocument) -> String? {
        guard let page = document.page(at: 0), let styled = page.attributedString else { return nil }
        let lines = Array(styledLines(styled).prefix(80))
        var sizes: [CGFloat: Int] = [:]
        for line in lines { sizes[line.size, default: 0] += line.text.count }
        guard let body = sizes.max(by: { $0.value < $1.value })?.key, body > 0 else { return nil }

        let larger = Set(lines.map(\.size)).filter { $0 >= body * 1.2 }.sorted(by: >)
        for size in larger.prefix(3) {
            var parts: [String] = []
            for line in lines {
                if line.size == size {
                    parts.append(line.text)
                } else if !parts.isEmpty {
                    break
                }
            }
            let title = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let letters = title.filter(\.isLetter).count
            guard title.count >= 8, title.count <= 160, letters * 2 >= title.count,
                  title.split(separator: " ").count >= 2,
                  !title.lowercased().hasPrefix("arxiv") else { continue }
            return title
        }
        return nil
    }

    /// A PDF's section headings: its outline, else text larger or bolder than
    /// the body on the first five pages.
    private static func headings(of document: PDFDocument) -> [String] {
        var found: [String] = []
        if let root = document.outlineRoot {
            func walk(_ item: PDFOutline, depth: Int) {
                guard depth < 4, found.count < 200 else { return }
                for index in 0..<item.numberOfChildren {
                    guard let child = item.child(at: index) else { continue }
                    if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !label.isEmpty { found.append(label) }
                    walk(child, depth: depth + 1)
                }
            }
            walk(root, depth: 0)
            if !found.isEmpty { return unique(found) }
        }

        var lines: [StyledLine] = []
        // Styled text is slow to pull from a PDF, so only the first pages —
        // enough for the title and the first sections. Papers and reports
        // with more structure almost always have an outline (used above).
        for index in 0..<min(document.pageCount, 5) {
            guard let page = document.page(at: index), let styled = page.attributedString else { continue }
            lines += styledLines(styled)
        }
        return headings(from: lines)
    }

    /// One line of styled text: its words, font size, and whether it's bold.
    private struct StyledLine {
        let text: String
        let size: CGFloat
        let bold: Bool
    }

    private static func styledLines(_ styled: NSAttributedString) -> [StyledLine] {
        var lines: [StyledLine] = []
        let whole = styled.string as NSString
        var start = 0
        while start < whole.length {
            let range = whole.lineRange(for: NSRange(location: start, length: 0))
            start = range.location + range.length
            let text = whole.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let font = styled.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            lines.append(StyledLine(text: text,
                                    size: (font?.pointSize ?? 0).rounded(),
                                    bold: font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false))
            if lines.count >= 3_000 { break }
        }
        return lines
    }

    /// Lines set larger — or bold at body size — than the text most of the
    /// characters use. The same rule for a PDF, a Word file, RTF or HTML:
    /// it's how every one of them shows a heading.
    private static func headings(from lines: [StyledLine]) -> [String] {
        var sizes: [CGFloat: Int] = [:]
        for line in lines { sizes[line.size, default: 0] += line.text.count }
        guard let body = sizes.max(by: { $0.value < $1.value })?.key, body > 0 else { return [] }
        let found = lines.filter { line in
            looksLikeHeading(line.text) && (line.size >= body * 1.15 || (line.bold && line.size >= body))
        }.map(\.text)
        return unique(found)
    }

    /// Word, RTF, HTML, OpenDocument: the text, plus headings from its styles.
    private static func richTextWithHeadings(_ url: URL, characterLimit: Int) -> (String, [String]) {
        var text = ""
        var headings: [String] = []
        let work = {
            guard let attributed = try? NSAttributedString(
                url: url,
                options: [.characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) else { return }
            text = attributed.string
            headings = Self.headings(from: Self.styledLines(attributed))
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
        return (clean(text, limit: characterLimit), headings)
    }

    /// A deck's slide titles (the first is its title); a workbook's sheet names.
    private static func officeOutline(_ url: URL, extension_: String) -> (title: String?, headings: [String]) {
        switch extension_ {
        case "pptx":
            let result = ScriptBridge.run("/usr/bin/unzip", ["-p", url.path, "ppt/slides/slide*.xml"], timeout: 5)
            guard result.status == 0 else { return (nil, []) }
            // Each title placeholder's shape, then the words inside it.
            var titles: [String] = []
            let shapes = result.output.components(separatedBy: "</p:sp>")
            for shape in shapes where shape.contains("type=\"title\"") || shape.contains("type=\"ctrTitle\"") {
                let words = matches(#"<a:t>([^<]*)</a:t>"#, in: shape).joined(separator: " ")
                let title = WebAccess.decodeEntities(words).trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { titles.append(title) }
            }
            return (titles.first, unique(titles))
        case "xlsx":
            let result = ScriptBridge.run("/usr/bin/unzip", ["-p", url.path, "xl/workbook.xml"], timeout: 5)
            guard result.status == 0 else { return (nil, []) }
            let sheets = matches(#"<sheet [^>]*name="([^"]+)""#, in: result.output).map(WebAccess.decodeEntities)
            return (nil, unique(sheets))
        default:
            return (nil, [])
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// More of a text file than the body keeps (256 KB), for headings: a
    /// section near the end of a long Markdown file or script still counts.
    private static func rawText(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return "" }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Headings in plain text: Markdown, numbered sections, LaTeX, and code
    /// declarations (camelCase split).
    private static func headingLines(in text: String, extension_: String = "") -> [String] {
        var found: [String] = []
        let isCode = codeExtensions.contains(extension_)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if isCode {
                if let name = matches(Self.declaration, in: line).first {
                    let words = ContentStore.searchableName(name)
                    found.append(words == name ? name : "\(name) (\(words))")
                }
            } else if let section = matches(#"^\\(?:sub)*section\*?\{([^}]+)\}"#, in: line).first {
                found.append(section)
            } else if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { found.append(heading) }
            } else if line.range(of: #"^\d+(\.\d+)*\.?\s+[A-Z][^.]{2,80}$"#, options: .regularExpression) != nil,
                      looksLikeHeading(line) {
                found.append(line)
            }
            if found.count >= 200 { break }
        }
        return unique(found)
    }

    /// Source files, whose headings are what they define.
    private static let codeExtensions: Set<String> = [
        "py", "swift", "js", "ts", "jsx", "tsx", "java", "kt", "go", "rs", "rb", "c", "cpp", "h", "hpp",
        "m", "cs", "php", "scala", "dart",
    ]

    /// `class Foo`, `struct Foo`, `def foo`, `func foo`, `function foo`, `fn foo`…
    private static let declaration =
        #"^(?:(?:public|private|internal|fileprivate|open|final|export|default|static|async|pub|abstract)\s+)*(?:class|struct|enum|protocol|interface|trait|def|func|function|fn)\s+([A-Za-z_][A-Za-z0-9_]*)"#

    /// Short, mostly letters, not a sentence.
    private static func looksLikeHeading(_ text: String) -> Bool {
        guard text.count >= 3, text.count <= 120, !text.hasSuffix(".") else { return false }
        let letters = text.filter(\.isLetter).count
        return letters >= 3 && letters * 2 >= text.count
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }.prefix(200).map { $0 }
    }

    /// A PDF page as a bitmap for Vision: twice size, greyscale.
    private static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = Int(box.width * scale)
        let height = Int(box.height * scale)
        // A page with no sensible size, or one large enough to be a plotter
        // drawing, isn't worth the allocation.
        guard width > 64, height > 64, width < 8_000, height < 8_000 else { return nil }

        guard let context = CGContext(data: nil,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }

        // White first. A PDF page doesn't paint its own background, so without
        // this the text is drawn black on black and OCR finds nothing — a
        // failure that looks exactly like a page with nothing on it.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// A PDF's metadata and outline: title, author, keywords, bookmarks.
    private static func attributes(of document: PDFDocument) -> (header: String, title: String?) {
        var parts: [String] = []
        var title: String?

        if let info = document.documentAttributes {
            // Keys are `PDFDocumentAttribute` values, and a surprising number
            // of real PDFs leave them empty or fill them with the name of the
            // program that made the file. Blank and junk both get dropped.
            let fields: [(PDFDocumentAttribute, Bool)] = [
                (.titleAttribute, true),
                (.subjectAttribute, false),
                (.authorAttribute, false),
                (.keywordsAttribute, false),
            ]
            for (key, isTitle) in fields {
                let value: String?
                if let text = info[key] as? String {
                    value = text
                } else if let list = info[key] as? [String] {
                    value = list.joined(separator: ", ")
                } else {
                    value = nil
                }
                guard let value, isUseful(value) else { continue }
                parts.append(value)
                if isTitle { title = value }
            }
        }

        // First few outline entries. A whole table of contents would drown the
        // text that follows it; the top level is the shape of the document.
        if let root = document.outlineRoot {
            var headings: [String] = []
            for index in 0..<min(root.numberOfChildren, 12) {
                guard let label = root.child(at: index)?.label, isUseful(label) else { continue }
                headings.append(label)
            }
            if !headings.isEmpty { parts.append(headings.joined(separator: ". ")) }
        }

        return (parts.joined(separator: ". "), title)
    }

    /// A title from the first line when the metadata has none.
    private static func heading(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines).prefix(6) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A title is a phrase, not a paragraph and not a fragment.
            guard trimmed.count >= 8, trimmed.count <= 120 else { continue }
            // Sentences aren't titles. A line ending in a full stop is prose
            // that happened to be first.
            guard !trimmed.hasSuffix(".") else { continue }
            // Needs actual words. A line of section numbers, a date, or a page
            // header of dashes is not what anyone would search for.
            let letters = trimmed.filter(\.isLetter).count
            guard letters >= trimmed.count / 2 else { continue }
            guard trimmed.split(separator: " ").count >= 2 else { continue }

            return trimmed
        }
        return nil
    }

    /// Rejects junk metadata (app names, paths, the first line Word copies).
    private static func isUseful(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3, trimmed.count < 300 else { return false }
        let lowered = trimmed.lowercased()
        let junk = ["untitled", "microsoft word", "microsoft powerpoint", "pdfcreator",
                    "acrobat", "printed by", "unknown", "document1", ".docx", ".doc",
                    ".indd", ".pages", "/users/", "c:\\",
                    // Generator placeholders (ReportLab writes "(anonymous)").
                    "anonymous", "unspecified", "no title", "untitled document"]
        return !junk.contains { lowered.contains($0) }
    }


    private static func plain(_ url: URL, characterLimit: Int) -> String {
        // Read a window rather than the file. A 2 GB log has the same first
        // four thousand characters as a 2 KB one, and only one of them is worth
        // loading into memory to find that out.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: characterLimit * 4) else { return "" }

        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return "" }
        return clean(text, limit: characterLimit)
    }

    /// The words in one image (Vision, on-device). Also the shelf's "copy text".
    static func text(inImageAt url: URL, limit: Int = 20_000) async -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        return await ocr(image, characterLimit: limit)
    }

    /// A picture that isn't a file — a spot on screen for click to ask:
    /// what it shows and the words in it, both on the Neural Engine.
    static func describe(_ image: CGImage, textLimit: Int = 4_000) async -> (labels: [String], text: String) {
        async let labels = pictureLabels(image)
        async let text = ocr(image, characterLimit: textLimit)
        return await (labels, text)
    }

    /// What a picture shows, as words: Apple's classifier (≥ 30%, up to twelve),
    /// faces as "person"/"selfie", plus close words. Never who.
    private static func pictureLabels(_ image: CGImage) async -> [String] {
        let joined: String = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .utility).async {
                let classify = VNClassifyImageRequest()
                let faces = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([classify, faces])
                } catch {
                    once.finish("")
                    return
                }
                var words: [String] = []
                let ranked = (classify.results ?? []).sorted { $0.confidence > $1.confidence }
                for observation in ranked where observation.confidence >= 0.3 {
                    words.append(observation.identifier.replacingOccurrences(of: "_", with: " "))
                    if words.count >= 12 { break }
                }
                let found = faces.results ?? []
                if !found.isEmpty {
                    words.append(found.count == 1 ? "person" : "people")
                    if found.count == 1, let face = found.first,
                       face.boundingBox.width * face.boundingBox.height > 0.08 {
                        words += ["selfie", "portrait"]
                    }
                }
                once.finish(words.joined(separator: "|"))
            }
        }
        guard !joined.isEmpty else { return [] }
        var labels: [String] = []
        for label in joined.split(separator: "|").map(String.init) {
            for word in [label] + (relatedLabels[label] ?? []) where !labels.contains(word) {
                labels.append(word)
            }
        }
        return labels
    }

    /// Words people use for what the classifier (or a caption) names
    /// differently. Shared with photo captions (`ContentStore.captionLine`).
    static let relatedLabels: [String: [String]] = [
        "kurta": ["suit", "shirt"], "saree": ["sari"], "sari": ["saree"], "tuxedo": ["suit"], "blazer": ["suit", "jacket"], "suit": ["formal"], "necktie": ["tie", "suit"],
        "bow tie": ["tie", "suit"], "gown": ["dress"], "wedding": ["ceremony"], "graduation": ["ceremony"],
        "document": ["paper"], "receipt": ["bill"], "screenshot": ["screen"], "people": ["group"],
        "puppy": ["dog"], "kitten": ["cat"], "automobile": ["car"], "sea": ["beach"], "shore": ["beach"],
    ]

    /// A scanned PDF's first pages with their lines kept, for Pip to answer from.
    static func scannedLines(of url: URL, pages: Int = 3) async -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        var text = ""
        for index in 0..<min(document.pageCount, pages) {
            guard let page = document.page(at: index), let image = render(page) else { continue }
            text += await ocr(image, characterLimit: 4_000, keepLines: true) + "\n"
        }
        return text
    }

    private static func ocr(_ image: CGImage, characterLimit: Int, keepLines: Bool = false) async -> String {
        await withCheckedContinuation { continuation in
            // Vision can report a failure twice; resuming twice would crash.
            let once = ResumeOnce(continuation)

            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let found = request.results as? [VNRecognizedTextObservation]
                else {
                    once.finish("")
                    return
                }
                let lines = found.compactMap { $0.topCandidates(1).first?.string }
                once.finish(keepLines ? String(rows(found).prefix(characterLimit))
                                      : clean(lines.joined(separator: "\n"), limit: characterLimit))
            }
            // .accurate: a handful of files, small screenshot text.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            DispatchQueue.global(qos: .userInitiated).async {
                // Built inside: `VNImageRequestHandler` isn't Sendable.
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do { try handler.perform([request]) }
                catch { once.finish("") }
            }
        }
    }

    /// Recognised text as rows, top to bottom (Vision reads tickets by column).
    private static func rows(_ found: [VNRecognizedTextObservation]) -> String {
        let pieces = found.compactMap { box -> (rect: CGRect, text: String)? in
            box.topCandidates(1).first.map { (box.boundingBox, $0.string) }
        }.sorted { $0.rect.midY > $1.rect.midY }
        var rows: [[(rect: CGRect, text: String)]] = []
        for piece in pieces {
            // Same row: its middle is within half a line of the row's first piece.
            if let first = rows.last?.first, abs(first.rect.midY - piece.rect.midY) < max(first.rect.height, piece.rect.height) / 2 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " | ") }
            .joined(separator: "\n")
    }

    /// Lets exactly one caller resume a continuation.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Never>?

        init(_ continuation: CheckedContinuation<String, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: String) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// Collapses whitespace and truncates.
    private static func clean(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "-\n", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) : collapsed
    }
}
