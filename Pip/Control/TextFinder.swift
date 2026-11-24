import AppKit
import ApplicationServices
import Vision

/// The text a drag selected: the app's own words (Accessibility), else the
/// swept band read off the screen (Chromium doesn't say).
enum TextFinder {

    struct Found {
        /// In Quartz screen points (top-left origin).
        var rect: CGRect
        var text: String
        var image: CGImage
        var source: String?
        /// Where the drag that selected it ended (Quartz): the chat opens there.
        var pointer: CGPoint? = nil
    }

    /// Longer than this is a whole document, not what was clicked.
    private static let longest = 2_000

    /// Text already selected in the app in front, with where it is on
    /// screen — taken as is when the shortcut is pressed, no click needed.
    static func selection() async -> Found? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = app.processIdentifier
        let hit = await Task.detached(priority: .userInitiated) { () -> (rect: CGRect, text: String)? in
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.5)
            guard let focused: AXUIElement = attribute(element, kAXFocusedUIElementAttribute) else { return nil }
            let text = (attribute(focused, kAXSelectedTextAttribute) as String? ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var rect: CGRect?
            var range = CFRange()
            if let value: AXValue = attribute(focused, kAXSelectedTextRangeAttribute),
               AXValueGetValue(value, .cfRange, &range) {
                rect = bounds(in: focused, of: NSRange(location: range.location, length: range.length))
            }
            guard let rect = rect ?? frame(of: focused) else { return nil }
            return (rect, String(text.prefix(longest)))
        }.value
        guard let hit else { return nil }
        let rect = hit.rect.insetBy(dx: -6, dy: -4).integral
        guard rect.width >= 8, rect.height >= 8, let image = try? await ScreenCapture.capture(rect: rect) else { return nil }
        let title = windowTitle(at: CGPoint(x: rect.midX, y: rect.midY))
        return Found(rect: rect, text: hit.text, image: image, source: title)
    }

    /// The whole lines a drag swept, read off the screen.
    static func read(from start: CGPoint, to end: CGPoint) async -> Found? {
        guard let screen = NSScreen.screens.map(Quartz.frame).first(where: { $0.contains(end) }) else { return nil }
        let band = CGRect(x: min(start.x, end.x) - 600, y: min(start.y, end.y) - 14,
                          width: abs(end.x - start.x) + 1200, height: abs(end.y - start.y) + 28)
            .intersection(screen).integral
        guard !band.isEmpty, let shot = try? await ScreenCapture.capture(rect: band) else { return nil }
        let lines: [(rect: CGRect, text: String)] = await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: observations.compactMap { observation in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    // Vision's box: 0…1, bottom-left origin → screen points.
                    let box = observation.boundingBox
                    return (CGRect(x: band.minX + box.minX * band.width, y: band.minY + (1 - box.maxY) * band.height,
                                   width: box.width * band.width, height: box.height * band.height), text)
                })
            }
            // Fast: the accurate reader's model often took seconds to load.
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: shot).perform([request]) }
            catch { continuation.resume(returning: []) }
        }
        let top = min(start.y, end.y) - 6, bottom = max(start.y, end.y) + 6
        let left = min(start.x, end.x), right = max(start.x, end.x)
        let multiLine = abs(end.y - start.y) > 12
        let swept = lines.filter { line in
            line.rect.maxY > top && line.rect.minY < bottom
                && (multiLine ? line.rect.maxX > left - 40 && line.rect.minX < right + 40
                              : line.rect.maxX > left && line.rect.minX < right)
        }.sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
        guard !swept.isEmpty else { return nil }
        let rect = swept.dropFirst().reduce(swept[0].rect) { $0.union($1.rect) }
        let text = swept.map(\.text).joined(separator: "\n")
        return Found(rect: rect, text: String(text.prefix(longest)), image: shot,
                     source: windowTitle(at: CGPoint(x: rect.midX, y: rect.midY)))
    }

    private static func bounds(in element: AXUIElement, of range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let argument = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         argument, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(value as! AXValue, .cgRect, &rect)
        // Clipped to the view: a paragraph scrolled half out of sight.
        if let frame = frame(of: element) { rect = rect.intersection(frame) }
        return rect.isEmpty ? nil : rect
    }

    // MARK: - Helpers

    private static func windowTitle(at point: CGPoint) -> String? {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != own,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(point) else { continue }
            let title = (info[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
