import AppKit
import Combine
import SwiftUI

/// Pip's orb breathing with your voice while he listens (Core Animation,
/// 30 updates a second, only while active; off with Reduce Motion).
struct VoicePulse<Content: View>: NSViewRepresentable {

    var active: Bool
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> PulseHost<Content> { PulseHost(rootView: content) }

    func updateNSView(_ view: PulseHost<Content>, context: Context) {
        view.rootView = content
        view.active = active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

final class PulseHost<Content: View>: NSHostingView<Content> {

    private var levels: AnyCancellable?
    private var brightness: CIFilter?

    var active = false {
        didSet {
            guard active != oldValue else { return }
            active ? start() : stop()
        }
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layerUsesCoreImageFilters = true
    }

    @MainActor required init?(coder: NSCoder) { nil }

    private func start() {
        brightness = CIFilter(name: "CIColorControls")
        levels = VoiceActivity.shared.$level
            .throttle(for: .milliseconds(33), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] level in
                MainActor.assumeIsolated { self?.show(level) }
            }
    }

    private func stop() {
        levels = nil
        show(0)
        layer?.filters = nil
        brightness = nil
    }

    private func show(_ level: Double) {
        guard let layer else { return }
        let amount = CGFloat(min(max(level, 0), 1))
        let scale = 1 + 0.06 * amount
        // About the middle: a view's layer turns round its corner.
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CATransform3DMakeTranslation(middle.x, middle.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -middle.x, -middle.y, 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.033)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        layer.transform = transform
        if let brightness {
            brightness.setValue(0.05 * amount, forKey: kCIInputBrightnessKey)
            layer.filters = [brightness]
        }
        CATransaction.commit()
    }
}
