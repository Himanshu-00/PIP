import AppKit
import SwiftUI

/// The line while Pip works: playful words, or what tool he's using, with a
/// soft light passing over (owner's request; overrides the no-word-effects
/// rule). Core Animation; still with Reduce Motion.
struct ThinkingText: NSViewRepresentable {

    /// What he's doing, or nil for the playful turn of words.
    var label: String? = nil
    var fontSize: CGFloat = 15

    func makeNSView(context: Context) -> ThinkingTextView { ThinkingTextView(fontSize: fontSize) }

    func updateNSView(_ view: ThinkingTextView, context: Context) { view.doing = label }
}

final class ThinkingTextView: NSView {

    /// The least time a phrase stays before the next replaces it.
    private static let hold: TimeInterval = 2
    /// The playful turn: calm verbs, each for `turn` seconds.
    private static let playful = ["Thinking…", "Noodling…", "Pondering…", "Mulling it over…", "Tinkering…",
                                  "Brewing…", "Musing…", "Puzzling…", "Cogitating…", "Conjuring…"]
    private static let turn: TimeInterval = 7
    private var turnTimer: Timer?
    private var turnIndex = 0

    /// What Pip is doing (a tool), shown instead of the playful turn.
    var doing: String? {
        didSet {
            guard doing != oldValue else { return }
            show(doing ?? Self.playful[turnIndex])
        }
    }

    private var label = "Thinking…"
    private var shownAt = Date()
    private var waiting: String?

    private let font: NSFont
    private let text = CATextLayer()
    private let light = CAGradientLayer()

    init(fontSize: CGFloat) {
        font = .systemFont(ofSize: fontSize, weight: .regular)
        super.init(frame: .zero)
        wantsLayer = true
        text.font = font
        text.fontSize = fontSize
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .left
        text.truncationMode = .end
        text.string = label
        light.startPoint = CGPoint(x: 0, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 0.5)
        // Mostly dim; one bright band.
        light.colors = [NSColor(white: 1, alpha: 0.45), NSColor(white: 1, alpha: 1), NSColor(white: 1, alpha: 0.45)].map(\.cgColor)
        light.locations = [0, 0.15, 0.3]
        text.mask = light
        layer?.addSublayer(text)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let width = (label as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(width) + 2, height: ceil(font.ascender - font.descender + font.leading))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.contentsScale = window?.backingScaleFactor ?? 2
        text.frame = bounds
        light.frame = text.bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        turnTimer?.invalidate()
        turnTimer = nil
        guard window != nil else { return }
        startLight()
        // The playful turn: only while on screen, and only when he isn't
        // using a tool.
        turnTimer = Timer.scheduledTimer(withTimeInterval: Self.turn, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.doing == nil else { return }
                self.turnIndex = (self.turnIndex + 1) % Self.playful.count
                self.show(Self.playful[self.turnIndex])
            }
        }
    }

    /// The next phrase: now if the current one has had its time, else when
    /// it has (only the latest waits — a quick run of tools shows the last).
    func show(_ next: String) {
        guard next != label else { waiting = nil; return }
        let left = Self.hold - Date().timeIntervalSince(shownAt)
        guard left > 0 else { change(to: next); return }
        let pending = waiting
        waiting = next
        guard pending == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + left) { [weak self] in
            guard let self, let next = self.waiting else { return }
            self.waiting = nil
            self.change(to: next)
        }
    }

    private func change(to next: String) {
        label = next
        shownAt = Date()
        let fade = CATransition()
        fade.type = .fade
        fade.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.8
        text.add(fade, forKey: "words")
        text.string = next
        invalidateIntrinsicContentSize()
    }

    private func startLight() {
        light.removeAllAnimations()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            light.colors = [NSColor(white: 1, alpha: 0.6).cgColor, NSColor(white: 1, alpha: 0.6).cgColor]
            light.locations = [0, 1]
            return
        }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.3, -0.15, 0]
        sweep.toValue = [1, 1.15, 1.3]
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        light.add(sweep, forKey: "sweep")
    }
}
