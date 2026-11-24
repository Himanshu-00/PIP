import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Small jobs on files from the drop shelf: compress or merge PDFs; convert,
/// resize or make a PDF of pictures.
///
/// PDFKit, ImageIO and CoreGraphics only. **The original is never touched**:
/// the result is written next to it with a suffix ("… (compressed).pdf",
/// "… merged.pdf"), a number added if that name is taken. Each result is put
/// on the shelf and recorded in `UndoLog`, so "undo" moves it to the Trash.
///
/// Plain functions on URLs, run off the main thread, so Pip can call them
/// later without the shelf (no Pip tools yet — the tool list stays short).
enum FileActions {

    struct Outcome: Sendable {
        let file: URL?
        /// One line for the shelf ("4.2 MB → 1.1 MB").
        let message: String
    }

    static let imageKinds: Set<String> = ["heic", "heif", "png", "jpg", "jpeg", "tiff", "tif", "gif", "webp", "bmp"]

    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }
    static func isImage(_ url: URL) -> Bool { imageKinds.contains(url.pathExtension.lowercased()) }

    // MARK: - PDF

    /// Re-saves with images as JPEG, downsampled for the screen.
    static func compressPDF(_ url: URL) -> Outcome {
        guard let document = PDFDocument(url: url) else { return Outcome(file: nil, message: "Couldn't open that PDF") }
        let out = free(url.deletingLastPathComponent(), stem(url) + " (compressed)", "pdf")
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard document.write(to: out, withOptions: options) else {
            return Outcome(file: nil, message: "Couldn't write the compressed PDF")
        }
        let before = size(url), after = size(out)
        guard after < before else {
            try? FileManager.default.removeItem(at: out)    // ours, just written, never shown
            return Outcome(file: nil, message: "Already as small as it gets")
        }
        return finish(out, label: "Compressed \(url.lastPathComponent)",
                      message: "\(bytes(before)) → \(bytes(after))")
    }

    /// Every page of each PDF, in the order given.
    static func mergePDFs(_ urls: [URL]) -> Outcome {
        guard urls.count >= 2, let first = urls.first else { return Outcome(file: nil, message: "Needs two PDFs") }
        let merged = PDFDocument()
        for url in urls {
            guard let document = PDFDocument(url: url) else {
                return Outcome(file: nil, message: "Couldn't open \(url.lastPathComponent)")
            }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
        let out = free(first.deletingLastPathComponent(), stem(first) + " merged", "pdf")
        guard merged.write(to: out) else { return Outcome(file: nil, message: "Couldn't write the merged PDF") }
        return finish(out, label: "Merged \(urls.count) PDFs",
                      message: "Merged \(urls.count) PDFs · \(merged.pageCount) pages")
    }

    // MARK: - Pictures

    /// The picture as a JPEG (metadata and orientation kept).
    static func convertToJPG(_ url: URL) -> Outcome {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return Outcome(file: nil, message: "Couldn't read that picture")
        }
        let out = free(url.deletingLastPathComponent(), stem(url), "jpg")
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return Outcome(file: nil, message: "Couldn't write a JPEG") }
        CGImageDestinationAddImageFromSource(destination, source, 0,
                                             [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return Outcome(file: nil, message: "Couldn't write a JPEG") }
        return finish(out, label: "Converted \(url.lastPathComponent) to JPEG",
                      message: "JPEG · \(bytes(size(out)))")
    }

    /// Smaller, in the same format: `longEdge` pixels, or `fraction` of the size.
    static func resize(_ url: URL, longEdge: Int? = nil, fraction: Double? = nil) -> Outcome {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return Outcome(file: nil, message: "Couldn't read that picture") }
        let longest = max(width, height)
        let target = longEdge ?? Int(Double(longest) * (fraction ?? 0.5))
        guard target < longest else { return Outcome(file: nil, message: "Already \(longest) px or smaller") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return Outcome(file: nil, message: "Couldn't resize that picture")
        }
        let type = CGImageSourceGetType(source) ?? UTType.jpeg.identifier as CFString
        let out = free(url.deletingLastPathComponent(), stem(url) + " (\(image.width)×\(image.height))", url.pathExtension)
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else {
            return Outcome(file: nil, message: "Couldn't write the picture")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return Outcome(file: nil, message: "Couldn't write the picture") }
        return finish(out, label: "Resized \(url.lastPathComponent)",
                      message: "\(image.width)×\(image.height) · \(bytes(size(out)))")
    }

    /// One PDF, a page per picture, each page the picture's size.
    static func makePDF(_ urls: [URL]) -> Outcome {
        guard let first = urls.first else { return Outcome(file: nil, message: "No pictures") }
        let document = PDFDocument()
        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 4_000,
                  ] as CFDictionary),
                  let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            else { return Outcome(file: nil, message: "Couldn't read \(url.lastPathComponent)") }
            document.insert(page, at: document.pageCount)
        }
        let name = urls.count == 1 ? stem(first) : stem(first) + " and \(urls.count - 1) more"
        let out = free(first.deletingLastPathComponent(), name, "pdf")
        guard document.write(to: out) else { return Outcome(file: nil, message: "Couldn't write the PDF") }
        return finish(out, label: "Made a PDF of \(urls.count) picture\(urls.count == 1 ? "" : "s")",
                      message: "PDF · \(urls.count) page\(urls.count == 1 ? "" : "s") · \(bytes(size(out)))")
    }

    // MARK: - Helpers

    private static func finish(_ out: URL, label: String, message: String) -> Outcome {
        ActivityLog.write(.system, "file action: \(label) → \(out.lastPathComponent) (\(message))")
        Task { @MainActor in UndoLog.recordCreated(label, files: [out]) }
        return Outcome(file: out, message: message)
    }

    private static func stem(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// `name.ext` in `folder`, or `name 2.ext`, `name 3.ext`… — never an existing file.
    private static func free(_ folder: URL, _ name: String, _ ext: String) -> URL {
        let suffix = ext.isEmpty ? "" : "." + ext
        var candidate = folder.appendingPathComponent(name + suffix)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(number)\(suffix)")
            number += 1
        }
        return candidate
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
