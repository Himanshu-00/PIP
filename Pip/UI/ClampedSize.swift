import SwiftUI

/// Width and height animated separately, each with its own spring and a
/// floor it can't go below (so overshoot never shows the real notch).
struct ClampedWidth: Animatable, ViewModifier {
    var width: CGFloat
    let minimum: CGFloat

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(width: max(width, minimum))
    }
}

struct ClampedHeight: Animatable, ViewModifier {
    var height: CGFloat
    let minimum: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: max(height, minimum))
    }
}

extension Animation {
    /// Height leads: the island drops open first. Tighter and better damped —
    /// vertical travel is short, and a wobble there reads as a glitch.
    static var islandHeight: Animation {
        .spring(response: 0.30, dampingFraction: 0.78)
    }

    /// Width follows, looser and bouncier. It travels furthest, so this is
    /// where elasticity is visible without becoming silly.
    static var islandWidth: Animation {
        .spring(response: 0.40, dampingFraction: 0.66)
    }
}

extension View {
    /// Height first so its animation is scoped to it alone, then width on top
    /// with its own. Applying one animation to both would collapse them back
    /// into a single curve.
    func islandSize(_ size: CGSize, notLessThan minimum: CGSize) -> some View {
        self
            .modifier(ClampedHeight(height: size.height, minimum: minimum.height))
            .animation(.islandHeight, value: size.height)
            .modifier(ClampedWidth(width: size.width, minimum: minimum.width))
            .animation(.islandWidth, value: size.width)
    }
}
