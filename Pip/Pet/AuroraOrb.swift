import AppKit
import QuartzCore
import SwiftUI

/// Pip's body while thinking: 48 baked aurora frames flipped by Core
/// Animation. Plays only on screen; still with Reduce Motion.
struct AuroraOrb: NSViewRepresentable {

    /// Loaded on first use (about 20 MB decoded) and kept.
    static let frames: [CGImage] = (0..<48).compactMap { index in
        let name = String(format: "aurora-%02d", index)
        guard let url = Bundle.main.url(forResource: name, withExtension: "png")
                ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Aurora"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    static var available: Bool { frames.count == 48 }

    /// Shown while Pip is thinking.
    var visible: Bool

    func makeNSView(context: Context) -> AuroraOrbView { AuroraOrbView() }

    func updateNSView(_ view: AuroraOrbView, context: Context) {
        view.setVisible(visible)
    }
}

final class AuroraOrbView: NSView {

    /// Three waves, each the aurora seen through its own soft band that
    /// crosses the orb left to right and fades in and out as it goes.
    private struct Wave {
        let aurora = CALayer()
        let band = CAGradientLayer()
    }

    /// Holds the waves; faded out as a whole when he stops thinking.
    private let holder = CALayer()
    private let waves = (0..<3).map { _ in Wave() }
    private var visible = false
    private var stopWork: DispatchWorkItem?
    /// The width the waves were started at (they're measured in orb widths).
    private var laidOutWidth: CGFloat = 0

    /// One wave's crossing, in seconds; they start a third of this apart.
    private static let crossing: CFTimeInterval = 3.6
    private static let fadeAway: CFTimeInterval = 1.0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // A band two orbs wide: soft edge, opaque middle, soft edge.
        let black = NSColor.black.cgColor, clear = NSColor.clear.cgColor
        for wave in waves {
            wave.aurora.contentsGravity = .resizeAspect
            wave.aurora.contents = AuroraOrb.frames.first
            wave.aurora.opacity = 0
            wave.band.colors = [clear, clear, black, black, clear, clear]
            wave.band.locations = [0, 0.12, 0.42, 0.58, 0.88, 1]
            wave.band.startPoint = CGPoint(x: 0, y: 0.5)
            wave.band.endPoint = CGPoint(x: 1, y: 0.5)
            wave.band.anchorPoint = CGPoint(x: 0, y: 0.5)
            wave.aurora.mask = wave.band
            holder.addSublayer(wave.aurora)
        }
        layer?.addSublayer(holder)
    }

    required init?(coder: NSCoder) { nil }

    func setVisible(_ show: Bool) {
        guard show != visible else { return }
        visible = show
        stopWork?.cancel()
        if show {
            holder.removeAnimation(forKey: "fadeAway")
            holder.opacity = 1
            start()
            return
        }
        // Done thinking: the waves fade out together, then everything stops.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = holder.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = Self.fadeAway
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.opacity = 0
        CATransaction.commit()
        holder.add(fade, forKey: "fadeAway")
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeAway + 0.05, execute: work)
    }

    private func start() {
        guard window != nil, waves[0].aurora.animation(forKey: "frames") == nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Still: the aurora shown whole, no waves.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            waves[0].aurora.mask = nil
            waves[0].aurora.opacity = 1
            CATransaction.commit()
            return
        }
        let width = max(bounds.width, 1)
        let now = CACurrentMediaTime()
        for (index, wave) in waves.enumerated() {
            let begin = now + Self.crossing * Double(index) / Double(waves.count)
            // The aurora's own drift, each wave a little out of step.
            let frames = CAKeyframeAnimation(keyPath: "contents")
            frames.values = AuroraOrb.frames
            frames.calculationMode = .discrete
            frames.duration = 3
            frames.repeatCount = .infinity
            frames.timeOffset = Double(index)
            wave.aurora.add(frames, forKey: "frames")
            // Across, left to right: from fully off the left to fully off the right.
            let across = CABasicAnimation(keyPath: "position.x")
            across.fromValue = -1.9 * width
            across.toValue = 0.9 * width
            across.duration = Self.crossing
            across.repeatCount = .infinity
            across.beginTime = begin
            across.fillMode = .backwards
            wave.band.add(across, forKey: "across")
            // And each wave fades in as it arrives and out as it leaves.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.85, 0.85, 0]
            fade.keyTimes = [0, 0.3, 0.7, 1]
            fade.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear),
                                    CAMediaTimingFunction(name: .easeIn)]
            fade.duration = Self.crossing
            fade.repeatCount = .infinity
            fade.beginTime = begin
            fade.fillMode = .backwards
            wave.aurora.add(fade, forKey: "fade")
        }
    }

    /// Nothing animates while he isn't thinking.
    private func stop() {
        for wave in waves { wave.aurora.removeAllAnimations(); wave.band.removeAllAnimations() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waves[0].aurora.mask = waves[0].band
        waves[0].aurora.opacity = 0
        holder.opacity = 1
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.frame = bounds
        for wave in waves {
            wave.aurora.frame = bounds
            wave.aurora.contentsScale = window?.backingScaleFactor ?? 2
            wave.band.bounds = CGRect(x: 0, y: 0, width: bounds.width * 2, height: bounds.height)
            wave.band.position = CGPoint(x: -1.9 * bounds.width, y: bounds.height / 2)
        }
        CATransaction.commit()
        // The crossing is measured in orb widths: restart only at a new size.
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            if visible, bounds.width > 0 { stop(); start() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        if visible { start() }
    }
}
