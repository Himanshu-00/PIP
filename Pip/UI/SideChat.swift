import AppKit
import SwiftUI

/// Click to ask's answer panel beside what was marked (right, else left,
/// else below). Non-activating; key only when the field is clicked; goes on
/// Esc or a click elsewhere.
@MainActor
final class SideChat {

    static let shared = SideChat()

    /// What the panel needs from the rest of the app.
    struct Services {
        /// One line in the notch after an action.
        let notify: (NotchEvent) -> Void
    }

    struct Chip: Identifiable {
        let id = UUID()
        let title: String
        /// An SF Symbol shown before the title.
        var icon: String? = nil
        let run: () -> Void
    }

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        /// "From the picture and a web search": built from what went with
        /// the question, never from the model's words.
        var source: String?
        /// The question asked for an explanation (laid out like Pip's).
        var explains: Bool { question == "Explain simply" || PipExplanation.expects(question) }
    }

    final class Model: ObservableObject {
        @Published var title: String
        /// Where it came from: "1706.03762v7.pdf · Preview", "YouTube · Safari".
        @Published var subtitle = ""
        /// What was clicked, for the header (a file's icon for a file).
        @Published var thumbnail: NSImage?
        var thumbnailIsIcon = false
        /// The mic is on.
        @Published var listening = false
        @Published var lines: [String]
        /// Pip's own line about it, or nil.
        @Published var note: String?
        /// Waiting for that line: a quiet "…".
        @Published var looking = false
        @Published var chips: [Chip] = []
        @Published var turns: [Turn] = []

        init(title: String, lines: [String]) {
            self.title = title
            self.lines = lines
        }

        var busy: Bool { looking || turns.last.map { $0.answer == nil } ?? false }
    }

    /// Called when the panel goes away.
    var onDismiss: (() -> Void)?

    private var panel: SidePanel?
    private(set) var model: Model?
    /// Where the chat and the picture's glass rim sit in the panel.
    private var stage: Stage?
    /// The chat's own frame on screen (AppKit coordinates): the panel also
    /// holds the rim, so its frame is bigger than the chat.
    private var chatFrame: NSRect = .zero
    private var answer: ClickAnswer?
    private var anchor: CGRect = .zero
    /// Selected text: where the drag ended (Quartz), or nil for a picture.
    private var pointer: CGPoint?
    /// Chosen once per answer, so a taller panel doesn't hop sides.
    private var side: Side?
    private enum Side { case right, left, below, above, corner }
    private var monitors: [Any] = []
    private var scrollTap: CFMachPort?
    private var scrollSource: CFRunLoopSource?
    private var services: Services?
    /// The app it was clicked in, read before this app takes focus.
    private var appName: String?
    /// The mic button's listener, made the first time it's pressed.
    private var voice: VoiceInput?

    /// The mockup's width (340 until 2026-11-21): four chips fit on one row.
    static let width: CGFloat = 440
    private static let gap: CGFloat = 20
    /// Between selected text and the chat under it: close, like a reply.
    private static let textGap: CGFloat = 10

    // MARK: - Showing

    /// `anchor` is the marked area, in Quartz screen coordinates.
    /// `near`: for selected text, where the selecting drag ended — the chat
    /// opens just below the text there (above it when there's no room).
    func show(_ answer: ClickAnswer, beside anchor: CGRect, services: Services, near pointer: CGPoint? = nil) {
        close()
        self.answer = answer
        self.anchor = anchor
        self.pointer = pointer
        self.side = nil
        self.services = services
        let model = Model(title: answer.title, lines: answer.lines)
        model.chips = chips(for: answer)
        let front = NSWorkspace.shared.frontmostApplication
        appName = front == NSRunningApplication.current ? nil : front?.localizedName
        model.subtitle = Self.subtitle(for: answer, app: appName)
        (model.thumbnail, model.thumbnailIsIcon) = Self.thumbnail(for: answer.target)
        self.model = model

        // One window for the chat and, round a picture, its glass rim:
        // Liquid Glass is clear only in the key window, so as two windows
        // the rim was always the frosted fallback.
        let stage = Stage()
        if case .image = answer.target { stage.rimRadius = PictureGlass.radius(round: anchor) }
        self.stage = stage
        let chat = SideChatView(model: model, onAsk: { [weak self] question in self?.ask(question) },
                                onMic: { [weak self] in self?.toggleMic() },
                                onClose: { [weak self] in self?.dismiss() },
                                onHeight: { [weak self] height in
                                    guard let self, abs(stage.chatHeight - height) > 0.5 else { return }
                                    stage.chatHeight = height
                                    self.placeSoon()
                                })
        let panel = SidePanel(content: SideStageView(stage: stage, chat: chat))
        self.panel = panel
        place()
        appear(panel)
        // Liquid Glass is clear only in the active app's key window.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        installMonitors()
        ActivityLog.write(.system, "click: side chat — \(answer.title)")

        switch answer.target {
        case .file(let url):
            suggestTidy(for: url)
        case .image:
            // No automatic caption: the panel waits for a question
            // (owner, 2026-11-11). What Vision saw still goes with it.
            break
        case .region(let image):
            look(at: image)
        case .text:
            break
        }
    }

    /// The instant answer, once it's ready: the panel opens at once with
    /// just its title (Vision can take seconds to start), this fills it in.
    func update(_ answer: ClickAnswer) {
        guard let model, self.answer?.title == answer.title || self.answer.map({ Self.sameTarget($0.target, answer.target) }) == true
        else { return }
        self.answer = answer
        model.chips = chips(for: answer)
        if model.title != answer.title { model.title = answer.title }
        let subtitle = Self.subtitle(for: answer, app: appName)
        if model.subtitle != subtitle { model.subtitle = subtitle }
        // A picture has no lines: no automatic caption.
        if case .image = answer.target {} else { model.lines = answer.lines }
        placeSoon()
    }

    /// The page or file it's in, then the app: "1706.03762v7.pdf · Preview",
    /// "YouTube · Safari" (a site at the end of a title stands for the page).
    private static func subtitle(for answer: ClickAnswer, app: String?) -> String {
        var parts: [String] = []
        if case .file(let url) = answer.target {
            parts.append(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        } else if let title = answer.source {
            let pieces = title.components(separatedBy: " - ")
            let site = pieces.count > 1 ? pieces.last?.trimmingCharacters(in: .whitespaces) : nil
            let place = site.flatMap { !$0.isEmpty && $0.count <= 20 ? $0 : nil }
                ?? title.components(separatedBy: " — ").first?.trimmingCharacters(in: .whitespaces) ?? title
            if !place.isEmpty, place != app { parts.append(place) }
        }
        if let app { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    private static func thumbnail(for target: ClickToAsk.Target) -> (NSImage?, Bool) {
        switch target {
        case .image(let image, _), .region(let image), .text(_, let image):
            return (NSImage(cgImage: image, size: .zero), false)
        case .file(let url):
            return (NSWorkspace.shared.icon(forFile: url.path), true)
        }
    }

    // MARK: - Mic

    /// The mic button: listens like Pip's talk key (Apple's recogniser, on
    /// the Mac), ends after a pause or a second press, and asks what it heard.
    private func toggleMic() {
        guard let model else { return }
        if let voice, voice.isListening {
            voice.release()
            return
        }
        guard !model.busy else { return }
        Task { [weak self] in
            guard await VoiceInput.requestPermission(), let self, self.model === model else { return }
            let voice = self.voice ?? VoiceInput()
            self.voice = voice
            voice.onCommand = { [weak self] words in
                guard let self, self.model === model else { return }
                if model.listening { model.listening = false }
                self.ask(words)
            }
            voice.onNothingHeard = { if model.listening { model.listening = false } }
            voice.listenForCommand(endOnSilence: true)
            if model.listening != voice.isListening { model.listening = voice.isListening }
            ActivityLog.write(.voice, "click: side chat listening" + (voice.isListening ? "" : " — couldn't start the mic"))
        }
    }

    private static func sameTarget(_ a: ClickToAsk.Target, _ b: ClickToAsk.Target) -> Bool {
        switch (a, b) {
        case (.image(let x, _), .image(let y, _)), (.region(let x), .region(let y)), (.text(_, let x), .text(_, let y)): return x === y
        case (.file(let x), .file(let y)): return x == y
        default: return false
        }
    }

    func dismiss() {
        let wasShowing = panel != nil
        close()
        if wasShowing { onDismiss?() }
    }

    private func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        unlockScrolling()
        if let voice, voice.isListening { voice.cancel() }
        if let panel {
            panel.orderOut(nil)
            ClickGlass.releaseFocus()
        }
        panel = nil
        model = nil
        stage = nil
        answer = nil
    }

    /// `place` after SwiftUI has taken in the change (straight after measured
    /// the old content).
    private func placeSoon() {
        guard !placePending else { return }
        placePending = true
        DispatchQueue.main.async { [weak self] in
            self?.placePending = false
            self?.place()
        }
    }
    private var placePending = false

    /// Beside the marked area: right, else left, else below, else above —
    /// never over it — on the screen it's on, kept inside that screen.
    func place() {
        guard let panel, let stage else { return }
        let height = min(stage.chatHeight, 640)
        let mark = Quartz.cocoa(anchor)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: mark.midX, y: mark.midY)) }
            ?? NSScreen.screens.first { $0.frame.intersects(mark) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame.insetBy(dx: 8, dy: 8) else { return }
        let width = Self.width

        if side == nil, pointer != nil {
            // Text: under its last line, where your eyes and pointer are;
            // above its first line when there's no room. Beside a wide
            // block of text there rarely is, and it landed far away.
            side = mark.minY - Self.textGap - height >= visible.minY ? .below : .above
        }
        if side == nil {
            if mark.maxX + Self.gap + width <= visible.maxX { side = .right }
            else if mark.minX - Self.gap - width >= visible.minX { side = .left }
            else if mark.minY - Self.gap - height >= visible.minY { side = .below }
            else if mark.maxY + Self.gap + height <= visible.maxY { side = .above }
            // Bigger than the room round it (a full-screen image): a corner.
            else { side = .corner }
        }
        var origin: NSPoint
        switch side ?? .corner {
        case .right:  origin = NSPoint(x: mark.maxX + Self.gap, y: mark.maxY - height)
        case .left:   origin = NSPoint(x: mark.minX - Self.gap - width, y: mark.maxY - height)
        case .below:
            origin = NSPoint(x: pointer.map { Quartz.cocoa(CGRect(origin: $0, size: .zero)).minX - 24 } ?? mark.midX - width / 2,
                             y: mark.minY - (pointer == nil ? Self.gap : Self.textGap) - height)
        case .above:
            origin = NSPoint(x: pointer.map { Quartz.cocoa(CGRect(origin: $0, size: .zero)).minX - 24 } ?? mark.midX - width / 2,
                             y: mark.maxY + (pointer == nil ? Self.gap : Self.textGap))
        case .corner: origin = NSPoint(x: visible.maxX - width, y: visible.maxY - height)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - height)
        let chat = NSRect(origin: origin, size: NSSize(width: width, height: height))
        chatFrame = chat
        // The window: the chat, and the rim round the picture if there is one.
        var frame = chat
        let rim = stage.rimRadius != nil ? mark.insetBy(dx: -PictureGlass.rimReach, dy: -PictureGlass.rimReach) : nil
        if let rim { frame = frame.union(rim.insetBy(dx: -4, dy: -4)) }
        frame = frame.integral
        // Window-local, top-left origin, for SwiftUI.
        func local(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        stage.size = frame.size
        stage.chatOrigin = local(chat).origin
        stage.picture = rim != nil ? local(mark) : nil
        guard panel.frame.integral != frame else { return }
        panel.setFrame(frame, display: true)
    }

    /// A short fade; with Reduce Motion, just there. (It slid 8 pt away
    /// from the mark too, until the rim round the picture shared the
    /// window: the rim slid with it.)
    private func appear(_ panel: NSPanel) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Going away

    private func installMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.dismiss()
            return nil
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(global) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel != nil, !self.chatFrame.contains(NSEvent.mouseLocation) else { return }
                self.dismiss()
            }
        }) { monitors.append(global) }
        lockScrolling()
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            if event.window !== self?.panel { self?.dismiss() }
            return event
        }) { monitors.append(local) }
    }

    // MARK: - Scroll lock

    /// Holds the page under the panel still (event tap), so the mark stays put.
    private func lockScrolling() {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard scrollTap == nil,
              let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: sideChatScrollTap,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        scrollTap = tap
        scrollSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), scrollSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func unlockScrolling() {
        guard let tap = scrollTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let scrollSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), scrollSource, .commonModes) }
        CFMachPortInvalidate(tap)
        scrollTap = nil
        scrollSource = nil
    }

    /// From the tap: whether to swallow this event.
    fileprivate func handleScroll(_ type: CGEventType) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS gave the wheel back (main thread busy): let it.
            return false
        case .scrollWheel:
            guard let panel else { return false }
            return panel.isVisible && !chatFrame.contains(NSEvent.mouseLocation)
        default:
            return false
        }
    }

    // MARK: - Chips

    /// Picture labels (Apple's classifier) that mean a dish or ingredient.
    private static let foodWords: Set<String> = [
        "food", "meal", "dish", "dessert", "baked goods", "bread", "cake", "cookie", "pastry", "pie",
        "pizza", "burger", "hamburger", "sandwich", "salad", "soup", "pasta", "noodles", "sushi",
        "curry", "rice", "steak", "meat", "chicken", "seafood", "fish", "breakfast", "snack",
        "fruit", "vegetable", "egg", "cheese", "taco", "dumpling", "pancake", "waffle", "ice cream",
    ]

    private func chips(for answer: ClickAnswer) -> [Chip] {
        var list: [Chip] = []
        func ask(_ question: String, icon: String? = nil) -> Chip {
            Chip(title: question, icon: icon) { [weak self] in self?.ask(question) }
        }
        // In order of priority: one row, and what doesn't fit is dropped
        // from the end (`ChipRow`).
        switch answer.target {
        case .image(let image, _):
            // Food: a recipe is the obvious next question, so it's first.
            if answer.labels.contains(where: Self.foodWords.contains) { list.append(ask("Recipe", icon: "fork.knife")) }
            list.append(ask("What is this?"))
            // From the picture itself (photo vectors), so it's there even
            // when Vision gave no labels — without them it used to vanish.
            // ("Find similar on my Mac" and "Save it" until 2026-11-21.)
            list.append(Chip(title: "Find similar", icon: "magnifyingglass") { [weak self] in self?.findSimilar(to: image) })
            list.append(Chip(title: "Save image", icon: "arrow.down.to.line") { [weak self] in self?.save(image) })
            if !answer.text.isEmpty { list.append(copyChip(answer.text)) }
            list.append(ask("Explain simply"))
        case .file(let url):
            list.append(ask("What's inside?"))
            list.append(Chip(title: "Open", icon: "arrow.up.forward") { [weak self] in
                NSWorkspace.shared.open(url)
                self?.dismiss()
            })
        case .text(let text, _):
            list.append(ask("Summarise"))
            list.append(ask("Explain simply"))
            if let match = answer.match {
                list.append(Chip(title: "Open \(match.lastPathComponent)", icon: "arrow.up.forward") { [weak self] in
                    NSWorkspace.shared.open(match)
                    self?.dismiss()
                })
            }
            list.append(copyChip(text))
        case .region:
            list.append(ask("What is this?"))
            if !answer.text.isEmpty { list.append(copyChip(answer.text)) }
        }
        return list
    }

    private func copyChip(_ text: String) -> Chip {
        Chip(title: "Copy text", icon: "doc.on.doc") { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.services?.notify(.copied(summary: "\(text.split(whereSeparator: \.isWhitespace).count) words"))
            self?.dismiss()
        }
    }

    /// The picture's labels, or failing that its first words.
    /// Photos on the Mac that look like the picture, as chips to open —
    /// or a plain "no" when none is close.
    private func findSimilar(to image: CGImage) {
        guard let model, !model.busy else { return }
        model.turns.append(Turn(question: "Find similar", answer: nil))
        placeSoon()
        Task { [weak self] in
            let found = await PhotoVectors.shared.similar(to: image, limit: 12)
                .filter { $0.similarity >= Self.similarAt && FileManager.default.fileExists(atPath: $0.url.path) }
            guard let self, self.model === model else { return }
            ActivityLog.write(.system, "click: similar photos — \(found.count)"
                              + (found.first.map { String(format: ", best %.2f %@", $0.similarity, $0.url.lastPathComponent) } ?? ""))
            guard !found.isEmpty else {
                self.finish("No, nothing similar on your Mac.", source: "From the photos on your Mac", in: model)
                return
            }
            let shown = found.prefix(3)
            model.chips.insert(contentsOf: shown.map { match in
                Chip(title: "Open \(match.url.lastPathComponent)", icon: "photo") { [weak self] in
                    NSWorkspace.shared.open(match.url)
                    self?.dismiss()
                }
            }, at: 0)
            self.finish(found.count == 1 ? "Yes, one photo looks like it." : "Yes, \(found.count) photos look like it.",
                        source: "From the photos on your Mac", in: model)
        }
    }

    /// MobileCLIP similarity that counts as "looks like it" (measured 2026-11-11).
    private static let similarAt: Float = 0.78


    /// Into Downloads, where the download tidy then offers a name and folder.
    private func save(_ image: CGImage) {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clicked image \(stamp).png")
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        do {
            try data?.write(to: url)
            services?.notify(.pipReplied(text: "Saved to Downloads"))
            ActivityLog.write(.system, "click: saved image → \(url.lastPathComponent)")
        } catch {
            services?.notify(.failed(what: "Couldn't save the image"))
        }
        dismiss()
    }

    /// Rename it / Where should it go?, from the download tidy's suggestion
    /// (a file read and one search), added once it's worked out.
    private func suggestTidy(for url: URL) {
        let tidy = FileTidy()
        Task { [weak self] in
            await tidy.prepare(for: url)
            guard let self, let model = self.model, case .file(let shown)? = self.answer?.target, shown == url
            else { return }
            var extra: [Chip] = []
            if let name = tidy.suggestion?.newName {
                extra.append(Chip(title: "Rename it", icon: "pencil") { [weak self] in
                    let (message, _) = DailyTools.rename(url, to: name)
                    self?.services?.notify(.pipReplied(text: message))
                    self?.dismiss()
                })
            }
            if let folder = tidy.suggestion?.folder, folder.path != url.deletingLastPathComponent().path {
                extra.append(Chip(title: "Where should it go?", icon: "folder") { [weak self] in
                    guard let self, let model = self.model else { return }
                    model.turns.append(Turn(question: "Where should it go?",
                                            answer: "In \(folder.lastPathComponent)\nFiles like it are in \(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).",
                                            source: "From where files like it are kept"))
                    model.chips.insert(Chip(title: "Move to \(folder.lastPathComponent)", icon: "folder") { [weak self] in
                        let (message, _) = DailyTools.move(url, to: folder.path)
                        self?.services?.notify(.pipReplied(text: message))
                        self?.dismiss()
                    }, at: 0)
                    self.place()
                })
            }
            guard !extra.isEmpty else { return }
            model.chips.insert(contentsOf: extra, at: min(1, model.chips.count))
            self.place()
        }
    }

    // MARK: - Pip

    private static var brainReady: Bool { LocalBrain.isDownloaded }
    private static var canLook: Bool { LocalBrain.isDownloaded && LocalBrain.shared.canSee }

    /// The one-line look for images and areas; a quiet "…" meanwhile.
    private func look(at image: CGImage) {
        guard Self.canLook, let model else { return }
        model.looking = true
        placeSoon()
        Task { [weak self] in
            let line = try? await LocalBrain.shared.look(at: image, question: "Describe this in one sentence.",
                                                         maxTokens: 60)
            guard let self, self.model === model else { return }
            model.looking = false
            model.note = line.map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
            self.placeSoon()
        }
    }

    /// A chip or the field: answered here, with what was clicked attached.
    private func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model, let answer else { return }
        guard !model.busy else {
            ActivityLog.write(.system, "click: \"\(trimmed.prefix(40))\" ignored — still answering"
                              + (model.looking ? " (first look)" : ""))
            return
        }
        ActivityLog.write(.system, "click: asked \"\(trimmed.prefix(40))\"")
        model.turns.append(Turn(question: trimmed, answer: nil))
        placeSoon()
        guard Self.brainReady else {
            finish("Pip's brain isn't downloaded yet — ask him anything in his window once and he'll fetch it.",
                   in: model)
            return
        }
        let started = Date()
        Task { [weak self] in
            let reply: String
            // What went with the question, for the answer's source note.
            var used: [String] = []
            do {
                switch answer.target {
                case .image(let image, _), .region(let image):
                    if Self.canLook {
                        let found = await Self.webContext(for: trimmed, answer: answer)
                        used = ["the picture"]
                        if !answer.text.isEmpty { used.append("the text in it") }
                        if answer.source != nil { used.append("the window title") }
                        if !found.isEmpty { used.append("a web search") }
                        reply = try await LocalBrain.shared.look(
                            at: image, question: Self.context(for: answer) + found + "\n\n" + Self.instruction(trimmed),
                            maxTokens: 260)
                        break
                    }
                    fallthrough
                default:
                    used = Self.sources(for: answer)
                    let messages: [[String: Any]] = [
                        ["role": "system", "content": "You are Pip, a helpful assistant on a Mac. Answer briefly and plainly. "
                            + "Use only what you're given; say so if it isn't enough."],
                        ["role": "user", "content": Self.context(for: answer) + "\n\n" + Self.instruction(trimmed)],
                    ]
                    reply = try await LocalBrain.shared.chat(messages: messages, tools: []).content
                }
            } catch {
                reply = "I couldn't answer that: \(error.localizedDescription)"
                used = []
            }
            guard let self else { return }
            ActivityLog.write(.system, "click: answered \"\(trimmed.prefix(40))\" in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            self.finish(Self.clean(reply), source: Self.fromNote(used), in: model)
        }
    }

    /// What `context(for:)` gives the text model, in words.
    private static func sources(for answer: ClickAnswer) -> [String] {
        switch answer.target {
        case .image, .region:
            var used: [String] = []
            if !answer.labels.isEmpty { used.append("the picture's labels") }
            if !answer.text.isEmpty { used.append("the text in it") }
            if answer.source != nil { used.append("the window title") }
            return used
        case .text: return ["the selected text"]
        case .file: return answer.text.isEmpty ? ["the file's details"] : ["the file's details", "its text"]
        }
    }

    /// "From the picture, the text in it and a web search".
    private static func fromNote(_ used: [String]) -> String? {
        guard let last = used.last else { return nil }
        let rest = used.dropLast()
        return "From " + (rest.isEmpty ? last : rest.joined(separator: ", ") + " and " + last)
    }

    private func finish(_ reply: String, source: String? = nil, in model: Model) {
        guard self.model === model, let last = model.turns.indices.last else { return }
        model.turns[last].answer = reply.isEmpty ? "I couldn't make that out." : reply
        model.turns[last].source = reply.isEmpty ? nil : source
        // Only the last few exchanges stay in view.
        if model.turns.count > 3 { model.turns.removeFirst(model.turns.count - 3) }
        placeSoon()
    }

    /// The model's full instruction for a chip: the answer on line one, then a
    /// sentence or two.
    private static func instruction(_ question: String) -> String {
        switch question {
        case "Summarise": return "Summarise this. " + replyShape
        case "Explain simply": return "Explain this simply, for someone new to it. " + explainShape
        case "What's inside?": return "What is this file, and what's in it? " + replyShape
        case "What is this?": return "What is this? " + replyShape
        case "Recipe": return "On the first line, just the dish's name. Then a short ingredient list and numbered steps. "
            + "No introduction."
        default:
            if PipExplanation.expects(question) { return question + "\n(" + explainShape + ")" }
            return question + "\n(" + replyShape + " Use steps or a list only if I asked for them.)"
        }
    }

    private static let replyShape = "Reply like this: on the first line, only the answer itself in 8 words or fewer, "
        + "with no full stop. Then, on a new line, one or two plain sentences. Don't start with \"Based on\" or "
        + "\"It seems\", and don't say how you found out."

    /// The same shape as Pip's explanations (his system prompt), drawn by
    /// `ExplanationLayout`.
    private static let explainShape = "Reply like this: on the first line, the answer in one sentence; then one "
        + "or two plain sentences; then up to three points, each on its own line starting with \"- \". Put at "
        + "most one key phrase in **bold**. Don't start with \"Based on\" or \"It seems\", and don't say how "
        + "you found out."

    /// A reply as headline and body: its first line when that's short (as
    /// asked), else its first sentence. An opening "Based on the picture,"
    /// or "It seems that" goes, in case the model wrote one anyway.
    static func shape(_ reply: String) -> (headline: String, body: String) {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(
            of: #"(?i)^(based on [^,.\n]{0,80},|from (the|what) [^,.\n]{0,60},|it (seems|looks|appears)( like| that)?)\s*"#,
            with: "", options: .regularExpression)
        if let first = text.first, first.isLowercase { text = first.uppercased() + text.dropFirst() }
        var headline = text
        var body = ""
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        if lines.count == 2, lines[0].split(whereSeparator: \.isWhitespace).count <= 10 {
            headline = String(lines[0])
            body = String(lines[1])
        } else if let end = text.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            headline = String(text[..<end.lowerBound])
            body = String(text[end.upperBound...])
        }
        headline = headline.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*-:. ").union(.whitespaces))
        return (headline.isEmpty ? text : headline, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Final words only: anything inside think tags goes (rules: never show
    /// the model's reasoning).
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For who/what/where questions: the page title searched on the web (only
    /// the title and question are sent).
    private static func webContext(for question: String, answer: ClickAnswer) async -> String {
        let asks = ["who", "what", "where", "which", "name", "tell me", "search", "find out", "more about"]
        let lowered = question.lowercased()
        guard let title = answer.source.map(pageTitle), !title.isEmpty,
              asks.contains(where: lowered.contains) else { return "" }
        // "Who is she?" is answered by the title; anything else, by both.
        let query = lowered.hasPrefix("who") ? title : title + " " + question
        // Three results, title and snippet only. The search takes 1–2 s;
        // what made answers slow (15 s, against 5 without) was the model
        // reading 1,800 characters of results with addresses first.
        guard let results = try? await WebAccess.results(for: query), !results.isEmpty else { return "" }
        let lines = results.prefix(3).map { "- \($0.title): \(String($0.snippet.prefix(160)))" }
        ActivityLog.write(.system, "click: searched the web for \"\(query.prefix(80))\"")
        return "\n\nWeb search for «\(query)»:\n" + lines.joined(separator: "\n")
    }

    /// A window title without the app or site at its end: "Song - YouTube"
    /// → "Song"; "Page — Brave" → "Page".
    private static func pageTitle(_ title: String) -> String {
        var parts = title.components(separatedBy: " - ")
        if parts.count > 1, (parts.last?.count ?? 0) <= 20 { parts.removeLast() }
        return parts.joined(separator: " - ")
            .components(separatedBy: " — ").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? title
    }

    static func context(for answer: ClickAnswer) -> String {
        let text = String(answer.text.prefix(2_400))
        switch answer.target {
        case .file(let url):
            let lines = answer.lines.joined(separator: "\n")
            return "About the file \(url.path):\n\(lines)" + (text.isEmpty ? "" : "\nIt begins:\n\(text)")
        case .image, .region:
            let shows = answer.labels.isEmpty ? "" : " It shows: \(answer.labels.prefix(6).joined(separator: ", "))."
            let page = answer.source.map { " It's in a window titled «\($0)»." } ?? ""
            // A guess from a face named the wrong person, confidently.
            let people = " Never identify a person from their face or looks. Name someone only if the window title, "
                + "text in the picture or the web results below say who it is; otherwise say the picture alone doesn't tell."
            return "About this picture from my screen.\(shows)\(page)" + (text.isEmpty ? "" : " Text in it: \(text)") + people
        case .text:
            return "About this text from my screen:\n«\(text)»"
        }
    }
}

/// Borderless, non-activating, key while shown (for its glass); above the
/// dim. Holds the chat and the picture's rim; clear elsewhere, where clicks
/// go through.
private final class SidePanel: NSPanel {

    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: SideChat.width, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: content)
        // Sized only by `SideChat.place` (left to SwiftUI, the window grew
        // off screen and the two fought over its frame).
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: SideChat.width, height: 200)
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Where things sit in the panel, window-local with a top-left origin.
final class Stage: ObservableObject {
    @Published var size: CGSize = .zero
    @Published var chatOrigin: CGPoint = .zero
    /// The picture, when the panel draws its rim.
    @Published var picture: CGRect?
    var rimRadius: CGFloat?
    /// The chat's laid-out height (an estimate until the first layout).
    var chatHeight: CGFloat = 160
}

private struct SideStageView: View {

    @ObservedObject var stage: Stage
    let chat: SideChatView

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let picture = stage.picture, let radius = stage.rimRadius {
                PictureRim(picture: picture, radius: radius)
            }
            chat.offset(x: stage.chatOrigin.x, y: stage.chatOrigin.y)
        }
        .frame(width: stage.size.width, height: stage.size.height, alignment: .topLeading)
    }
}

/// Laid out as `Mockups/click-to-ask-panel.html`: header, question bubble,
/// headline answer, source note, one row of chips, field with mic.
private struct SideChatView: View {

    @ObservedObject var model: SideChat.Model
    let onAsk: (String) -> Void
    let onMic: () -> Void
    let onClose: () -> Void
    /// The panel's own height, as laid out: the window is placed from it.
    /// Not affected by the window's size, so resizing can't loop.
    let onHeight: (CGFloat) -> Void

    /// The answers scroll past this; the panel stays on screen.
    private static let maxBody: CGFloat = 420
    /// The answers' own height, measured. Inside SwiftUI only: the window
    /// is resized from `SideChat` after changes, never from here.
    @State private var bodyHeight: CGFloat = 0

    private var hasAnswers: Bool {
        !model.lines.isEmpty || model.note != nil || model.looking || !model.turns.isEmpty
    }

    /// "What is this?" only until something has been asked.
    private var shownChips: [SideChat.Chip] {
        model.turns.isEmpty ? model.chips : model.chips.filter { $0.title != "What is this?" }
    }

    private var placeholder: String {
        if model.listening { return "Listening…" }
        return model.turns.isEmpty ? "Ask anything…" : "Ask a follow-up…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SideHeader(model: model, onClose: onClose)

            // As tall as the answers up to `maxBody`, scrolled to the newest.
            if hasAnswers {
                ScrollView(.vertical) {
                    answers.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bodyHeight = $0 }
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.never)
                .frame(height: min(max(bodyHeight, 1), Self.maxBody))
                .padding(.top, 14)
            }

            if !shownChips.isEmpty {
                ChipRow(chips: shownChips, width: SideChat.width - 32, dimmed: model.busy)
                    .padding(.top, 14)
            }

            HStack(spacing: 8) {
                AskField(placeholder: placeholder, onSubmit: onAsk)
                MicButton(listening: model.listening, action: onMic)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .padding(.top, 12)
        }
        .padding(16)
        .frame(width: SideChat.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(SideGlass())
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { onHeight($0) }
        .environment(\.colorScheme, .dark)
    }

    /// The instant answer (a file's details, the selected text), Pip's own
    /// line, and the questions and answers since.
    private var answers: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.lines.isEmpty || model.note != nil || model.looking {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .legible()
                    }
                    if let note = model.note {
                        Text(SideTurnView.rich(note))
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                            .legible()
                    } else if model.looking {
                        SideTurnView.quietDots
                    }
                }
            }
            ForEach(model.turns) { turn in
                SideTurnView(turn: turn, compact: turn.id != model.turns.last?.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Text over glass: white with a very soft shadow, readable over a white
/// page as well as over a dark video.
private extension View {
    func legible() -> some View {
        shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 0.5)
    }
}

/// Thumbnail, what it is, where it's from, and ✕.
private struct SideHeader: View {

    @ObservedObject var model: SideChat.Model
    let onClose: () -> Void
    @State private var closeHover = false

    var body: some View {
        HStack(spacing: 12) {
            if let image = model.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: model.thumbnailIsIcon ? .fit : .fill)
                    .padding(model.thumbnailIsIcon ? 4 : 0)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .legible()
                if !model.subtitle.isEmpty {
                    Text(model.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .legible()
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(closeHover ? 0.22 : 0.14)))
                .overlay(ClickableArea(onClick: onClose, onHover: { closeHover = $0 }))
        }
    }
}

/// One question and its answer: the question as a small bubble on the
/// right, then the answer's headline, a line or two, and where it's from.
/// Earlier turns are the same, smaller.
private struct SideTurnView: View {

    let turn: SideChat.Turn
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 48)
                Text(turn.question)
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, compact ? 4 : 6)
                    // Outline only, like the search bar.
                    .overlay(bubble.strokeBorder(.white.opacity(0.22), lineWidth: 1))
                    .legible()
            }
            .padding(.bottom, compact ? 8 : 10)

            if let answer = turn.answer, let explanation = PipExplanation.parse(answer, expected: turn.explains) {
                ExplanationLayout(explanation: explanation,
                                  headlineSize: compact ? 15 : 17, bodySize: compact ? 13 : 14, bodyOpacity: 0.92)
                    .textSelection(.enabled)
                    .legible()
                sourceNote
            } else if let answer = turn.answer {
                let (headline, body) = SideChat.shape(answer)
                Text(headline)
                    .font(.system(size: compact ? 15 : 20, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .legible()
                if !body.isEmpty {
                    Text(Self.rich(body))
                        .font(.system(size: compact ? 13 : 14))
                        .lineSpacing(2)
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .legible()
                        .padding(.top, 4)
                }
                sourceNote
            } else {
                Self.quietDots
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var sourceNote: some View {
        if let source = turn.source {
            Label(source, systemImage: "info.circle")
                .font(.system(size: compact ? 11 : 11.5))
                .foregroundStyle(.white.opacity(0.6))
                .legible()
                .padding(.top, 8)
        }
    }

    /// Fully rounded, a capsule.
    private var bubble: Capsule { Capsule(style: .continuous) }


    /// The model writes **bold** now and then: shown as bold, not stars.
    static func rich(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static var quietDots: some View {
        ThinkingText(fontSize: 13).fixedSize().opacity(0.8)
    }
}

/// Clear Liquid Glass with a black tint (32%; the screen behind is already
/// dimmed), lit top edge and hairline. Older macOS: a
/// near-solid dark fill.
private struct SideGlass: View {

    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.clear.tint(.black.opacity(0.32)), in: shape)
                .environment(\.controlActiveState, .key)
                .overlay(shape.strokeBorder(LinearGradient(stops: [
                    .init(color: .white.opacity(0.45), location: 0),
                    .init(color: .white.opacity(0.16), location: 0.2),
                    .init(color: .white.opacity(0.12), location: 1),
                ], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        } else {
            shape.fill(Color(white: 0.08).opacity(0.96))
                .overlay(shape.strokeBorder(Color.white.opacity(IslandStyle.hairline), lineWidth: 1))
        }
    }
}

/// The chips on one row, never two: in order of priority, and those that
/// don't fit the width are left off the end. (They wrapped onto a second
/// row until 2026-11-21.)
private struct ChipRow: View {

    let chips: [SideChat.Chip]
    let width: CGFloat
    let dimmed: Bool
    /// The chips' shared glass (`GlassChipGroup`).
    @Namespace private var glass

    private static let spacing: CGFloat = 6

    var body: some View {
        GlassChipGroup(spacing: Self.spacing) {
            HStack(spacing: Self.spacing) {
                ForEach(Self.fitting(chips, in: width)) { chip in
                    ChipButton(title: chip.title, icon: chip.icon, glass: glass, action: chip.run)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: chips.map(\.title))
        .opacity(dimmed ? 0.5 : 1)
    }

    /// The first chips that fit in `width`, measured from their text.
    private static func fitting(_ chips: [SideChat.Chip], in width: CGFloat) -> [SideChat.Chip] {
        let font = NSFont.systemFont(ofSize: ChipButton.fontSize, weight: .medium)
        var used: CGFloat = 0
        var shown: [SideChat.Chip] = []
        for chip in chips {
            let text = ceil((chip.title as NSString).size(withAttributes: [.font: font]).width)
            let chipWidth = text + ChipButton.padding * 2 + (chip.icon == nil ? 0 : ChipButton.iconWidth + ChipButton.iconGap)
            let next = used + (shown.isEmpty ? 0 : spacing) + chipWidth
            guard next <= width else { break }
            used = next
            shown.append(chip)
        }
        return shown
    }
}

private struct ChipButton: View {

    static let fontSize: CGFloat = 12
    static let padding: CGFloat = 10
    static let iconWidth: CGFloat = 13
    static let iconGap: CGFloat = 5

    let title: String
    let icon: String?
    let glass: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Self.iconGap) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .medium))
                    .frame(width: Self.iconWidth)
            }
            Text(title)
                .font(.system(size: Self.fontSize, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, Self.padding)
        .frame(height: 28)
        // Outline only, like the search bar; it brightens on hover.
        .contentShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(hovering ? 0.4 : 0.22), lineWidth: 1))
        .animation(.easeOut(duration: 0.14), value: hovering)
        .overlay(ClickableArea(onClick: action, onHover: { hovering = $0 }))
    }
}

/// The field's mic: starts and stops listening (`SideChat.toggleMic`).
private struct MicButton: View {

    let listening: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: listening ? "mic.fill" : "mic")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(listening ? 1 : 0.85))
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(listening ? 0.3 : (hovering ? 0.2 : 0.14))))
            .overlay(ClickableArea(onClick: action, onHover: { hovering = $0 }))
    }
}

/// The text field: plain AppKit, which makes the panel key when clicked
/// (and only then), so it can be typed into without activating the app.
private struct AskField: NSViewRepresentable {

    let placeholder: String
    let onSubmit: (String) -> Void

    private static let font = NSFont.systemFont(ofSize: 13.5)

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.font
        field.textColor = .white
        field.cell?.lineBreakMode = .byTruncatingTail
        setPlaceholder(on: field)
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        if field.placeholderAttributedString?.string != placeholder { setPlaceholder(on: field) }
    }

    private func setPlaceholder(on field: NSTextField) {
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.58), .font: Self.font])
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSubmit: onSubmit) }

    final class Coordinator: NSObject {
        var onSubmit: (String) -> Void
        init(onSubmit: @escaping (String) -> Void) { self.onSubmit = onSubmit }
        @objc func submit(_ sender: NSTextField) {
            let text = sender.stringValue
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            sender.stringValue = ""
            onSubmit(text)
        }
    }
}

/// The scroll lock's C callback; taps on the main run loop are called on
/// the main thread.
private func sideChatScrollTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<SideChat>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { owner.handleScroll(type) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
