import AppKit
import ApplicationServices
import Vision

/// The picture under a click, whole: Accessibility first (overlays,
/// Chromium's big buttons), else by looking (Vision rectangles), and on a
/// PDF page the drawing round the click (`figure`).
enum PictureFinder {

    struct Picture {
        /// In Quartz screen points (top-left origin).
        var rect: CGRect
        var image: CGImage
        /// The title of the window it's in — a browser's is the page's
        /// ("早瀬ノエル × 冨岡 愛 - 恋する惑星 - YouTube"). What the picture
        /// is of often says less than where it is.
        var source: String?
    }

    static func find(at point: CGPoint) async -> Picture? {
        guard let screen = NSScreen.screens.map(Quartz.frame).first(where: { $0.contains(point) }) else { return nil }
        var frame = await Task.detached(priority: .userInitiated) {
            pictureFrame(at: point, screen: screen)
        }.value
        // Vision can hang (`ClickAnswer.within`): then no picture, not no answer.
        if frame == nil { frame = await ClickAnswer.within(4) { await byLooking(at: point, screen: screen) } ?? nil }
        guard let rect = frame?.intersection(screen).integral, rect.width >= 16, rect.height >= 16 else { return nil }
        do {
            let title = window(at: point)?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return Picture(rect: rect, image: try await ScreenCapture.capture(rect: rect),
                           source: title?.isEmpty == false ? title : nil)
        } catch {
            ActivityLog.write(.error, "click: capture failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Asks Chrome-family browsers to build their Accessibility tree while armed.
    static func wakeWebAccessibility() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: - By looking

    /// No picture from Accessibility: the rectangles Vision sees in the
    /// window under the click; the smallest that holds the click, is at
    /// least 80 × 60 pt and looks like a picture.
    private static func byLooking(at point: CGPoint, screen: CGRect) async -> CGRect? {
        // A page first: the rectangles in a diagram are its boxes, not it.
        if let page = await Task.detached(priority: .userInitiated, operation: { page(at: point) }).value {
            let visible = page.visible.intersection(screen)
            if !visible.isEmpty, let shot = try? await ScreenCapture.capture(rect: visible),
               let found = await Task.detached(priority: .userInitiated, operation: {
                   figure(in: shot, size: visible.size,
                          at: CGPoint(x: point.x - visible.minX, y: point.y - visible.minY), gap: 12 * page.zoom)
               }).value {
                ActivityLog.write(.system, "click: found on the page — \(Int(found.width))×\(Int(found.height))")
                return found.offsetBy(dx: visible.minX, dy: visible.minY)
            }
        }
        guard let window = window(at: point)?.frame.intersection(screen), !window.isEmpty,
              let shot = try? await ScreenCapture.capture(rect: window) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> CGRect? in
            let request = VNDetectRectanglesRequest()
            request.maximumObservations = 0
            request.minimumSize = 0.05
            request.minimumAspectRatio = 0.1
            request.quadratureTolerance = 8
            request.minimumConfidence = 0.4
            guard (try? VNImageRequestHandler(cgImage: shot).perform([request])) != nil else { return nil }
            let boxes = (request.results ?? []).map { found -> CGRect in
                // Normalised, bottom-left origin → screen points.
                let box = found.boundingBox
                return CGRect(x: window.minX + box.minX * window.width,
                              y: window.minY + (1 - box.maxY) * window.height,
                              width: box.width * window.width, height: box.height * window.height).integral
            }
            let candidates = boxes
                .filter { $0.contains(point) && $0.width >= 80 && $0.height >= 60
                    && $0.width * $0.height < window.width * window.height * 0.9 }
                .sorted { $0.width * $0.height < $1.width * $1.height }
            let scale = CGFloat(shot.width) / window.width
            for box in candidates {
                let crop = CGRect(x: (box.minX - window.minX) * scale, y: (box.minY - window.minY) * scale,
                                  width: box.width * scale, height: box.height * scale)
                guard let part = shot.cropping(to: crop) else { continue }
                let colours = colourCount(part)
                if colours >= 30 {
                    ActivityLog.write(.system, "click: found by looking — \(Int(box.width))×\(Int(box.height)), \(colours) colours")
                    return box
                }
            }
            ActivityLog.write(.system, "click: nothing picture-like by looking — \(boxes.count) rectangles, \(candidates.count) round the click")
            return nil
        }.value
    }

    // MARK: - On a page

    /// The page under the click, if the app says there is one (Preview's
    /// PDFs): the part of it on show, and how big it's drawn (1 = a US
    /// Letter page at its own size) — gaps on the page scale with it.
    private static func page(at point: CGPoint) -> (visible: CGRect, zoom: CGFloat)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success,
              var element = found else { return nil }
        // Up from the click: the page, then the scroll area it shows in.
        // Preview often answers with the group that holds the pages, not
        // the page — then it's the child under the click.
        var page: CGRect?
        var scroll: CGRect?
        for _ in 0..<8 {
            let role = role(of: element)
            if page == nil {
                if role == "AXPage" {
                    page = frame(of: element)
                } else {
                    let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
                    page = children.lazy.filter { self.role(of: $0) == "AXPage" }
                        .compactMap { frame(of: $0) }.first { $0.contains(point) }
                }
            }
            if role == kAXScrollAreaRole as String { scroll = frame(of: element); break }
            guard let parent: AXUIElement = attribute(element, kAXParentAttribute) else { break }
            element = parent
        }
        guard let whole = page else {
            ActivityLog.write(.system, "click: no page under the click")
            return nil
        }
        let visible = whole.insetBy(dx: 2, dy: 2)
        return (scroll.map(visible.intersection) ?? visible, min(max(whole.width / 612, 0.75), 3))
    }

    /// The drawing round a click on a page, out to the blank paper (text set
    /// aside, the figure's labels kept). Nil on text or blank paper.
    private static func figure(in shot: CGImage, size: CGSize, at point: CGPoint, gap: CGFloat) -> CGRect? {
        let w = Int(size.width), h = Int(size.height), g = max(Int(gap), 4)
        guard w >= 80, h >= 60 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(shot, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The paper's colour: the commonest (4 bits a channel).
        var counts = [Int: Int]()
        for i in stride(from: 0, to: pixels.count, by: 16) {
            counts[Int(pixels[i] >> 4) << 8 | Int(pixels[i + 1] >> 4) << 4 | Int(pixels[i + 2] >> 4), default: 0] += 1
        }
        guard let paper = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let red = (paper >> 8) * 17, green = (paper >> 4 & 15) * 17, blue = (paper & 15) * 17
        var ink = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            ink[i] = max(abs(Int(pixels[i * 4]) - red), abs(Int(pixels[i * 4 + 1]) - green),
                         abs(Int(pixels[i * 4 + 2]) - blue)) > 28
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: shot).perform([request])
        let lines = (request.results ?? []).map { found -> CGRect in
            let box = found.boundingBox
            return CGRect(x: box.minX * CGFloat(w), y: (1 - box.maxY) * CGFloat(h),
                          width: box.width * CGFloat(w), height: box.height * CGFloat(h))
        }
        var drawn = ink
        for line in lines {
            let box = line.insetBy(dx: -2, dy: -2).integral
            for y in max(Int(box.minY), 0)..<max(min(Int(box.maxY), h), 0) {
                for x in max(Int(box.minX), 0)..<max(min(Int(box.maxX), w), 0) { drawn[y * w + x] = false }
            }
        }
        // Summed, so "anything in this box" is four lookups.
        func sums(_ map: [Bool]) -> [Int32] {
            var table = [Int32](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var row: Int32 = 0
                for x in 0..<w {
                    if map[y * w + x] { row += 1 }
                    table[(y + 1) * (w + 1) + x + 1] = table[y * (w + 1) + x + 1] + row
                }
            }
            return table
        }
        func any(_ table: [Int32], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Bool {
            let a = max(x0, 0), b = max(y0, 0), c = min(x1, w), d = min(y1, h)
            guard c > a, d > b else { return false }
            return table[d * (w + 1) + c] - table[b * (w + 1) + c] - table[d * (w + 1) + a] + table[b * (w + 1) + a] > 0
        }
        let all = sums(ink), table = sums(drawn)
        var x0 = Int(point.x) - g, x1 = Int(point.x) + g, y0 = Int(point.y) - g, y1 = Int(point.y) + g
        // A click on the white inside a figure: the nearest drawing counts.
        if !any(all, x0, y0, x1, y1) {
            guard any(table, x0 - 3 * g, y0 - 3 * g, x1 + 3 * g, y1 + 3 * g) else { return nil }
            while !any(table, x0, y0, x1, y1) { x0 -= 1; x1 += 1; y0 -= 1; y1 += 1 }
        }
        var grew = true
        while grew {
            grew = false
            if x0 > 0, any(table, x0 - g, y0, x0, y1) { x0 -= 1; grew = true }
            if x1 < w, any(table, x1, y0, x1 + g, y1) { x1 += 1; grew = true }
            if y0 > 0, any(table, x0, y0 - g, x1, y0) { y0 -= 1; grew = true }
            if y1 < h, any(table, x0, y1, x1, y1 + g) { y1 += 1; grew = true }
        }
        // Back in to the drawing's own edges.
        while x1 - x0 > 1, !any(table, x0, y0, x0 + 1, y1) { x0 += 1 }
        while x1 - x0 > 1, !any(table, x1 - 1, y0, x1, y1) { x1 -= 1 }
        while y1 - y0 > 1, !any(table, x0, y0, x1, y0 + 1) { y0 += 1 }
        while y1 - y0 > 1, !any(table, x0, y1 - 1, x1, y1) { y1 -= 1 }
        var rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        guard rect.width >= 60, rect.height >= 40 else { return nil }
        // Its labels: lines in it, and ones no wider than it just outside
        // ("Inputs" under an arrow, a caption). Twice, for a label of two lines.
        for _ in 0..<2 {
            let near = rect.insetBy(dx: -CGFloat(g), dy: -CGFloat(g))
            for line in lines where line.intersects(near) && line.minX >= near.minX && line.maxX <= near.maxX {
                rect = rect.union(line)
            }
        }
        rect = rect.insetBy(dx: -6, dy: -6).intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard rect.width >= 80, rect.height >= 60, rect.width * rect.height < CGFloat(w * h) * 0.85 else { return nil }
        return rect
    }

    /// Distinct colours (4 bits a channel) in a 24 × 24 copy: a photo has
    /// many, a panel, button or block of text a handful. (Measured on
    /// screenshots: panels and bars 13, a diagram 35, photos 75–177.)
    private static func colourCount(_ image: CGImage) -> Int {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var seen = Set<Int>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            seen.insert(Int(pixels[index] >> 4) << 8 | Int(pixels[index + 1] >> 4) << 4 | Int(pixels[index + 2] >> 4))
        }
        return seen.count
    }

    /// The frontmost ordinary window (not ours) under the point: its frame,
    /// and its title (readable with Screen Recording, which click to ask has).
    private static func window(at point: CGPoint) -> (frame: CGRect, title: String)? {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != own,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(point) else { continue }
            return (frame, info[kCGWindowName as String] as? String ?? "")
        }
        return nil
    }

    // MARK: - Accessibility

    /// Synchronous IPC to the app under the click: call off the main thread.
    private static func pictureFrame(at point: CGPoint, screen: CGRect) -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        // A busy app answers late; a click shouldn't wait seconds for it.
        AXUIElementSetMessagingTimeout(system, 1.0)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success,
              let hit = found else {
            ActivityLog.write(.system, "click: Accessibility has nothing at the click")
            return nil
        }
        func usable(_ element: AXUIElement) -> CGRect? {
            guard isPicture(element), let frame = frame(of: element),
                  frame.width >= 32, frame.height >= 32,
                  frame.width * frame.height < screen.width * screen.height * 0.95 else { return nil }
            return frame
        }

        // The element and its parents.
        var lineage = [hit]
        while lineage.count < 6, let parent: AXUIElement = attribute(lineage[lineage.count - 1], kAXParentAttribute) {
            lineage.append(parent)
        }
        if let frame = lineage.prefix(4).lazy.compactMap(usable).first { return frame }

        // Under each parent, nearest first: an image covering the click.
        var visited = Set<AXUIElement>()
        var seen = 0
        var roles = Set<String>()
        for ancestor in lineage {
            var queue = [ancestor]
            while !queue.isEmpty, seen < 400 {
                let element = queue.removeFirst()
                guard visited.insert(element).inserted else { continue }
                seen += 1
                if let frame = usable(element), frame.contains(point) { return frame }
                roles.insert(role(of: element) ?? "?")
                let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
                queue += children.filter { child in frame(of: child).map { $0.contains(point) } ?? true }
            }
        }

        // A picture behind a button, which Chromium doesn't show inside.
        let clickable = [kAXButtonRole as String, "AXLink"]
        if let button = lineage.prefix(4).first(where: { clickable.contains(role(of: $0) ?? "") }),
           let frame = frame(of: button), frame.width >= 100, frame.height >= 80,
           frame.width * frame.height < screen.width * screen.height * 0.6 {
            ActivityLog.write(.system, "click: no image element — taking the \(Int(frame.width))×\(Int(frame.height)) button round it")
            return frame
        }
        ActivityLog.write(.system, "click: no image element — under it "
                          + lineage.map { role(of: $0) ?? "?" }.joined(separator: " < ")
                          + "; looked through \(seen): " + roles.sorted().joined(separator: ", "))
        return nil
    }

    /// An image, or a video (browsers describe `<video>` as a group).
    private static func isPicture(_ element: AXUIElement) -> Bool {
        if role(of: element) == kAXImageRole as String { return true }
        let description: String = attribute(element, kAXRoleDescriptionAttribute) ?? ""
        if description.lowercased().contains("video") { return true }
        let classes: [String] = attribute(element, "AXDOMClassList") ?? []
        return classes.contains { $0.lowercased().contains("video") }
    }

    private static func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute)
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
