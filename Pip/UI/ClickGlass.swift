import AppKit
import SwiftUI

/// Click to ask's dim: the screen near-black, the picture left bright with
/// soft corners. Click-through; text gets nothing. The path is flipped here.

// MARK: - Dim

/// One screen: black except a hole for the picture.
final class DimOverlay: NSWindow {

    /// Near-opaque: the picture alone on black (owner, 2026-11-11; 45%
    /// dim, then a frosted screen under 25%, came before).
    static let black = 0.92

    private let screenRect: CGRect
    private let dimLayer = CAShapeLayer()

    init(screen: NSScreen) {
        screenRect = Quartz.frame(screen)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = ClickGlass.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(Self.black).cgColor
        dimLayer.opacity = 0
        view.layer?.addSublayer(dimLayer)
        contentView = view
        setFrame(screen.frame, display: false)
    }

    /// A picture: everything goes black but `outline` (Quartz screen
    /// points); its edge is the glass rim (`PictureGlass.rim`).
    func dim(around outline: CGPath) {
        guard let local = local(outline) else { return }
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: screenRect.size))
        path.addPath(local)
        dimLayer.path = path
        show([dimLayer])
    }

    /// Quartz (top-left) → this layer's bottom-left origin.
    private func local(_ path: CGPath) -> CGPath? {
        var toLocal = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -screenRect.minX, ty: screenRect.maxY)
        return path.copy(using: &toLocal)
    }

    private func show(_ layers: [CALayer]) {
        orderFrontRegardless()
        CATransaction.begin()
        CATransaction.setDisableActions(ClickGlass.reduceMotion)
        CATransaction.setAnimationDuration(0.25)
        layers.forEach { $0.opacity = 1 }
        CATransaction.commit()
    }
}

// MARK: - Glass windows

enum ClickGlass {
    /// Above apps and the menu bar; the side chat (`.popUpMenu`) goes above.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Hands focus back to the app that had it — unless the notch panel has
    /// taken it since (⌥F while this was up).
    static func releaseFocus() {
        guard NSApp.isActive, !(NSApp.keyWindow is NotchPanel) else { return }
        NSApp.deactivate()
    }
}

// MARK: - The marks

/// The shapes marked on screen, in Quartz screen points.
enum PictureGlass {

    /// A picture: itself, its corners softened (8% of the short side,
    /// 8…40 pt; 3% up to 14 pt was tried and read too square).
    static func hole(round picture: CGRect) -> CGPath {
        Path(roundedRect: picture, cornerRadius: radius(round: picture), style: .continuous).cgPath
    }


    /// Corner radius for a picture's outline: 8% of its short side, 8…40 pt.
    static func radius(round picture: CGRect) -> CGFloat {
        min(max(min(picture.width, picture.height) * 0.08, 8), 40)
    }

    /// How far the rim reaches out past the picture.
    static let rimReach: CGFloat = 0
    private static let rimOut: CGFloat = rimReach

    /// `over`: how far the band reaches in over the picture.
    fileprivate static func ring(round picture: CGRect, radius: CGFloat, over: CGFloat) -> Path {
        var path = Path(roundedRect: picture.insetBy(dx: -rimOut, dy: -rimOut),
                        cornerRadius: radius + rimOut, style: .continuous)
        path.addPath(Path(roundedRect: picture.insetBy(dx: over, dy: over),
                          cornerRadius: max(radius - over, 2), style: .continuous))
        return path
    }
}

/// A fixed path in the view's own (top-left) coordinates.
private struct FixedShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}

/// A thin frosted Liquid Glass band over the picture's last 2 pt, drawn in
/// the side chat's window. `picture` in the view's coordinates.
struct PictureRim: View {

    let picture: CGRect
    let radius: CGFloat

    var body: some View {
        let outer = FixedShape(path: Path(roundedRect: picture.insetBy(dx: -PictureGlass.rimReach, dy: -PictureGlass.rimReach),
                                          cornerRadius: radius + PictureGlass.rimReach, style: .continuous))
        Group {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular, in: outer)
                    .environment(\.controlActiveState, .key)
            } else {
                outer.fill(.ultraThinMaterial)
            }
        }
        .mask(FixedShape(path: PictureGlass.ring(round: picture, radius: radius, over: 2))
            .fill(style: FillStyle(eoFill: true)))
        .allowsHitTesting(false)
    }
}
