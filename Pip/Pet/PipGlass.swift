import SwiftUI
import AppKit

/// The fill of every open panel: black at the notch easing into Liquid
/// Glass (clear style, macOS 26; a dark blur before). The black is in front
/// of the glass.
struct PipGlass: View {

    var shape: NotchShape
    /// The black is solid to this plus `solidTopExtra`.
    var notchHeight: CGFloat

    // (A Debug-only Glass Lab window used to override these live; removed
    // with the testing menu items.)
    private let style = Self.glassStyle
    private let dim = Self.dim
    private let solidTopExtra = Self.solidTopExtra
    private let fadeAt = Self.blendEnd
    private let fadeEnd = Self.fadeEnd
    private let tint = Self.tint

    init(shape: NotchShape, notchHeight: CGFloat) {
        self.shape = shape
        self.notchHeight = notchHeight
    }

    private var solidTop: CGFloat { notchHeight + solidTopExtra }

    static var isLiquid: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The dark layer behind the glass. Tried 0.45, 0.6, and 0.2 under a
    /// black top half; 0.6 hid the lensing the owner wants to see, so 0.35;
    /// 0.25 on 2026-11-20, then none on 2026-11-21 (owner: "remove it").
    static let dim = 0.0
    /// Where the black has fully eased away, as a share of the height.
    static let blendEnd = 1.0
    /// Whether Liquid Glass is drawn (macOS 26).
    static let drawsGlass = true
    /// "clear" (see-through) or "regular" (frosted, Apple's default).
    static let glassStyle = "clear"
    /// Solid black below the notch before the fade starts, in points
    /// (12 until 2026-11-07; the owner tried 18, 30, 50 and settled on 40).
    static let solidTopExtra = 40.0
    /// How much black is left once the fade ends: 0 fades to clear
    /// (0 until 2026-11-07; 0.15 so the bottom stays darker, owner's ask).
    static let fadeEnd = 0.25
    /// Black tint mixed into the glass itself: 0 is none.
    static let tint = 0.0

    /// Solid black to `solidTop`, then a late smootherstep drop (t^2.5) to
    /// nothing at `blendEnd`, in 32 segments.
    static func blend(height: CGFloat, solidTop: CGFloat,
                              fadeAt: CGFloat, fadeEnd: Double) -> [Gradient.Stop] {
        let start = min(solidTop / height, 1)
        let end = max(fadeAt, start)
        var stops: [Gradient.Stop] = [.init(color: .black, location: 0), .init(color: .black, location: start)]
        for step in 1...32 {
            let t = Double(step) / 32
            let eased = pow(t, 2.5)
            stops.append(.init(color: .black.opacity(1 - eased * (1 - fadeEnd)),
                               location: start + (end - start) * t))
        }
        return stops
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                liquid
            } else {
                frosted
            }
        }
        .allowsHitTesting(false)
    }

    @available(macOS 26.0, *)
    private var liquid: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            ZStack {
                if Self.drawsGlass {
                Color.clear
                    .glassEffect(glass, in: shape)
                    // The dark layer goes behind the glass, so the glass
                    // refracts it like anything else behind the window.
                    // (As part of the glass's content it turned it milky.)
                    .background { shape.fill(Color.black.opacity(dim)) }
                    // Always drawn as active, or the glass falls back to a blur when not key.
                    .environment(\.controlActiveState, .key)
                }
                // The notch black goes in FRONT of the glass. Behind it, the
                // glass's own light greyed it out and the real notch showed
                // through.
                shape.fill(LinearGradient(stops: Self.blend(height: height, solidTop: solidTop,
                                                            fadeAt: CGFloat(fadeAt), fadeEnd: fadeEnd),
                                          startPoint: .top, endPoint: .bottom))
            }
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        let base: Glass = style == "regular" ? .regular : .clear
        return tint > 0 ? base.tint(.black.opacity(tint)) : base
    }

    private var frosted: some View {
        GeometryReader { geometry in
            ZStack {
                FrostedGlass()
                LinearGradient(stops: Self.stops(height: geometry.size.height, solidTop: solidTop),
                               startPoint: .top, endPoint: .bottom)
            }
        }
        // Widened by the flares, so their black is part of the same fill;
        // the island's clip trims it to the shape.
        .padding(.horizontal, -shape.topCornerRadius)
    }

    private static func stops(height: CGFloat, solidTop: CGFloat) -> [Gradient.Stop] {
        let total = max(height, 101)
        let blackEnd = min(max(1 - 100 / total, solidTop / total), 1)
        func at(_ fromBottom: CGFloat) -> CGFloat { max(1 - fromBottom / total, blackEnd) }
        return [
            .init(color: .black, location: 0),
            .init(color: .black, location: blackEnd),
            .init(color: tint(0x030304, 0.88), location: at(70)),
            .init(color: tint(0x08080A, 0.70), location: at(36)),
            .init(color: tint(0x0A0A0C, 0.60), location: max(1, blackEnd)),
        ]
    }

    private static func tint(_ hex: UInt32, _ alpha: Double) -> Color {
        PipArt.rgb(hex).opacity(alpha)
    }
}

/// The blur before macOS 26: dark, behind the window.
private struct FrostedGlass: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
