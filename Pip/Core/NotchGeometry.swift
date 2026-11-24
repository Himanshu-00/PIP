import AppKit

/// Everything we need to know about the physical notch of a given display.
struct NotchMetrics: Equatable {
    /// Exact size of the hardware notch, in points.
    var notchSize: CGSize
    /// Frame of the display, in AppKit screen coordinates.
    var screenFrame: CGRect
    /// True when the display actually has a notch (built-in 14"/16" MacBook Pro, 15" Air, ...).
    var hasHardwareNotch: Bool
}

enum NotchGeometry {

    /// Used ONLY on displays without a hardware notch — an external monitor, or
    /// an older Mac. On your 14" the real notch is measured at runtime and this
    /// value is never read, which is why changing it appears to do nothing.
    /// Close to a real 14" MacBook Pro notch at default "More Space"-ish scaling.
    static let simulatedNotch = CGSize(width: 195, height: 32)

    /// Debug / preview offset. 0 = island sits exactly on the hardware notch (invisible).
    /// Set it to e.g. 44 to float the island *below* the real notch so you can see it.
    static var verticalOffset: CGFloat = 0

    /// Width of the strip either side of the notch in the compact state.
    /// This is where the compactLeading artwork lives.
    static var compactInset: CGFloat = 34

    /// Width of the strip either side of the notch for transient events.
    /// Wider than `compactInset` because a percentage has to fit.
    static var eventInset: CGFloat = 46

    /// How long a *fast-moving* pointer must stay on the notch before the
    /// island opens. This exists so sliding across to a menu bar item doesn't
    /// trigger it — not to make deliberate hovering feel sluggish.
    static var hoverDelay: TimeInterval = 0.26

    /// A pointer that has slowed to below this (points per second) inside the
    /// trigger zone has arrived rather than passed through, so it opens almost
    /// at once. Aiming at something and stopping is the tell.
    static var arrivalSpeed: CGFloat = 320

    /// Delay used once the pointer is judged to have arrived.
    static var arrivalDelay: TimeInterval = 0.05

    /// Prefer the built-in display that actually has a notch.
    static func notchedScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Measures the real notch instead of hard-coding numbers, so this stays correct
    /// across every display scaling mode ("Larger Text" ... "More Space") and every model.
    static func metrics(for screen: NSScreen) -> NotchMetrics {
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top

        var width: CGFloat = 0
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The two auxiliary areas are the menu bar strips either side of the notch.
            width = frame.width - left.width - right.width
        }

        let hasNotch = topInset > 0 && width > 0
        let size = hasNotch
            ? CGSize(width: width.rounded(), height: topInset.rounded())
            : simulatedNotch

        return NotchMetrics(notchSize: size, screenFrame: frame, hasHardwareNotch: hasNotch)
    }
}
