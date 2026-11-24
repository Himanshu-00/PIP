import SwiftUI

/// Action chips as Liquid Glass capsules (macOS 26) in one container, so they
/// merge as they change. Regular glass; prominent chips white-tinted. Clicks
/// via `ClickableArea`. Older macOS: the chip's own background.
struct GlassChipBackground<Fallback: View>: ViewModifier {
    var id: String
    var namespace: Namespace.ID
    var prominent = false
    var hovering = false
    @ViewBuilder var fallback: () -> Fallback

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.10 : 0)))
                .glassEffect(prominent ? .regular.tint(.white.opacity(0.85)) : .regular, in: Capsule())
                .glassEffectID(id, in: namespace)
        } else {
            content.background(fallback())
        }
    }
}

extension View {
    func glassChip<Fallback: View>(id: String, in namespace: Namespace.ID, prominent: Bool = false,
                                   hovering: Bool = false,
                                   fallback: @escaping () -> Fallback) -> some View {
        modifier(GlassChipBackground(id: id, namespace: namespace, prominent: prominent,
                                     hovering: hovering, fallback: fallback))
    }
}

/// One group of chips that share their glass (see `GlassChipBackground`).
struct GlassChipGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
