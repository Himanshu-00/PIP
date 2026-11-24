import AppKit
import ApplicationServices
import QuartzCore

/// Click to ask (⌥⇧A): click a picture or drag over text, and it goes to the
/// side chat. Read-only; while armed (10 s at most) an event tap holds back
/// clicks and Esc. The notch's green dot shows it's armed — no pointer marks.
@MainActor
final class ClickToAsk {

    static let shared = ClickToAsk()

    /// Shows or clears the hint in the notch.
    var onHint: ((String?) -> Void)?
    /// A picture was found and is marked on screen (already disarmed).
    var onPicture: ((PictureFinder.Picture) -> Void)?
    /// Text was found (no picture there) and is marked on screen.
    var onText: ((TextFinder.Found) -> Void)?

    private(set) var isArmed = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timeout: DispatchWorkItem?
    /// Looking for a picture: further clicks are swallowed and ignored.
    private var finding = false

    private var dims: [DimOverlay] = []

    private static let armedFor: TimeInterval = 10
    /// Empty: the notch shows only the green dot (text was cropped by the
    /// real notch). Problems still say a few words.
    private static let hint = ""

    /// Pressing the shortcut again while armed cancels.
    func toggle() {
        isArmed ? disarm(reason: "shortcut") : arm()
    }

    /// Selected text: straight to the chat. The app already shows the
    /// selection, so nothing is dimmed or marked.
    private func ask(about text: TextFinder.Found) {
        clearOverlays()
        ActivityLog.write(.system, "click: asked about selected text, \(text.text.count) characters")
        onText?(text)
    }

    func arm() {
        guard !isArmed else { return }
        // Both are needed later (what's under the pointer, and a look at
        // it); asking up front beats a click that silently does nothing.
        guard AXIsProcessTrusted() else {
            onHint?("Needs Accessibility access")
            ActivityLog.write(.system, "click: not armed — no Accessibility permission")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            onHint?("Needs Screen Recording access")
            ActivityLog.write(.system, "click: not armed — no Screen Recording permission")
            return
        }

        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: clickToAskTap,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            ActivityLog.write(.error, "click: couldn't create the event tap")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        clearOverlays()
        isArmed = true
        finding = false
        onHint?(Self.hint)
        restartTimeout()
        // Before Pip takes focus: it asks the app that's in front.
        PictureFinder.wakeWebAccessibility()
        pressedAt = nil
        selecting = false
        ActivityLog.write(.system, "click: armed")
    }

    /// Stops listening. What's found stays until
    /// `clearOverlays`.
    func disarm(reason: String) {
        guard isArmed else { return }
        isArmed = false
        finding = false

        timeout?.cancel()
        timeout = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        ClickGlass.releaseFocus()
        onHint?(nil)
        ActivityLog.write(.system, "click: disarmed (\(reason))")
    }

    /// Takes the dim and the mark away: the answer was dismissed.
    func clearOverlays() {
        dims.forEach { $0.orderOut(nil) }
        dims = []
    }

    private func restartTimeout() {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.disarm(reason: "timeout") }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armedFor, execute: work)
    }

    /// From the tap. Returns whether to swallow the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turned a slow tap off: stop rather than turn it back on.
            let reason = type == .tapDisabledByTimeout ? "tap too slow — macOS turned it off" : "tap turned off by input"
            DispatchQueue.main.async { [weak self] in self?.disarm(reason: reason) }
            return false
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return false }
            disarm(reason: "esc")
            return true
        case .leftMouseDown:
            // Our own replay of your press (below): through to the app.
            if event.getIntegerValueField(.eventSourceUserData) == Self.replayMark { return false }
            pressedAt = event.location
            selecting = false
            return true
        case .leftMouseDragged:
            if selecting { return false }
            // A drag, not a click: you're selecting text. The press was
            // held back, so it's given to the app now, where it happened,
            // and the drag goes on to it from here.
            guard let start = pressedAt, !finding,
                  hypot(event.location.x - start.x, event.location.y - start.y) >= 6 else { return true }
            selecting = true
            if let press = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                   mouseCursorPosition: start, mouseButton: .left) {
                press.setIntegerValueField(.eventSourceUserData, value: Self.replayMark)
                press.post(tap: .cghidEventTap)
            }
            return true
        case .leftMouseUp:
            if selecting {
                selecting = false
                if let start = pressedAt { selected(from: start, to: event.location) }
                return false
            }
            if !finding { find(at: event.location) }
            return true
        default:
            return false
        }
    }

    /// Marks the press replayed to the app when a drag starts.
    private static let replayMark: Int64 = 0x0C11C4
    /// Where the left button went down while armed, held back from the app.
    private var pressedAt: CGPoint?
    /// A drag is selecting text in the app.
    private var selecting = false

    /// The drag selected text: once the app has finished selecting, its
    /// words (as it says, or read off the screen) go to the chat.
    private func selected(from start: CGPoint, to end: CGPoint) {
        finding = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            var found = await TextFinder.selection()
            if found == nil { found = await TextFinder.read(from: start, to: end) }
            guard let self, self.isArmed else { return }
            self.finding = false
            guard let found else {
                ActivityLog.write(.system, "click: couldn't read the selected text")
                self.onHint?("Couldn't read that")
                self.restartTimeout()
                return
            }
            self.disarm(reason: "found")
            var text = found
            text.pointer = end
            // Where the chat goes: the lines the drag swept. An app that
            // says what's selected but not where gave its whole text area
            // (a whole page), and the chat opened far below the words.
            let swept = CGRect(x: min(start.x, end.x), y: min(start.y, end.y) - 12,
                               width: max(abs(end.x - start.x), 1), height: abs(end.y - start.y) + 24)
            if text.rect.height > swept.height + 60 || !text.rect.insetBy(dx: -40, dy: -40).intersects(swept) {
                text.rect = swept
            }
            ActivityLog.write(.system, "click: text at \(Int(text.rect.minX)),\(Int(text.rect.minY)) \(Int(text.rect.width))×\(Int(text.rect.height))")
            self.ask(about: text)
        }
    }

    #if DEBUG
    /// `-clickAt "x,y"`: that click, without the tap — to check the mark and
    /// the chat on screen.
    func debugClick(at point: CGPoint) {
        PictureFinder.wakeWebAccessibility()
        isArmed = true
        find(at: point)
    }
    #endif

    private func find(at point: CGPoint) {
        finding = true
        ActivityLog.write(.system, "click: at \(Int(point.x)),\(Int(point.y))")
        Task { [weak self] in
            let started = Date()
            let picture = await PictureFinder.find(at: point)
            guard let self, self.isArmed else { return }
            if let picture {
                self.finding = false
                ActivityLog.write(.system, "click: picture \(Int(picture.rect.width))×\(Int(picture.rect.height)) at \(Int(picture.rect.minX)),\(Int(picture.rect.minY)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                self.disarm(reason: "found")
                self.present(picture.rect)
                self.onPicture?(picture)
                return
            }
            self.finding = false
            ActivityLog.write(.system, "click: no picture there")
            self.onHint?("No picture there")
            self.restartTimeout()
        }
    }

    /// Everything black but the picture (the side chat draws its glass rim).
    private func present(_ rect: CGRect) {
        clearOverlays()
        let hole = PictureGlass.hole(round: rect)
        dims = NSScreen.screens.map(DimOverlay.init)
        dims.forEach { $0.dim(around: hole) }
    }
}

/// Screen coordinates: AX and Quartz use a top-left origin, AppKit a
/// bottom-left one. Converted here and nowhere else.
enum Quartz {
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// An AppKit rect (bottom-left origin) in Quartz terms.
    static func rect(fromCocoa rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A Quartz rect in AppKit terms.
    static func cocoa(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A screen's frame in Quartz terms.
    static func frame(_ screen: NSScreen) -> CGRect { rect(fromCocoa: screen.frame) }
}

/// The C callback. Taps added to the main run loop are called on the main
/// thread.
private func clickToAskTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                           userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<ClickToAsk>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { owner.handle(type, event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

// MARK: - What was clicked

extension ClickToAsk {

    enum Target {
        case file(URL)
        /// An image element (a photo in a page, a picture in a document),
        /// captured at its own frame (Quartz points).
        case image(CGImage, CGRect)
        /// Text: read straight from Accessibility when the app exposes it,
        /// else by OCR of the area around the click.
        case text(String, CGImage)
        /// Anything else, or a dragged box.
        case region(CGImage)

        /// One line for the log.
        var summary: String {
            switch self {
            case .file(let url):         return "file \(url.lastPathComponent)"
            case .image(let image, _):   return "image \(image.width)×\(image.height) px"
            case .text(let text, _):     return "text \"\(text.prefix(60).replacingOccurrences(of: "\n", with: " "))\""
            case .region(let image):     return "region \(image.width)×\(image.height) px"
            }
        }
    }
}
