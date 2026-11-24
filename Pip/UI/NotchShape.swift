import SwiftUI

/// The island silhouette: square against the top bezel, rounded at the bottom,
/// with the concave "inverted" corners that make it melt into the menu bar —
/// the same trick Apple uses for the notch cutout itself.
struct NotchShape: Shape {

    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topCornerRadius, rect.width / 2))
        let bottom = max(0, min(bottomCornerRadius, rect.width / 2, rect.height))

        var path = Path()
        // Concave top-left, flaring outwards into the menu bar.
        path.move(to: CGPoint(x: rect.minX - top, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + top),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        // Rounded bottom-left.
        path.addQuadCurve(to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        // Rounded bottom-right.
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
        // Concave top-right.
        path.addQuadCurve(to: CGPoint(x: rect.maxX + top, y: rect.minY),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
