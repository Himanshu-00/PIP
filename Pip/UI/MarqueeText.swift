import SwiftUI

/// Scrolls long titles horizontally, pausing at the start like iOS does.
struct MarqueeText: View {

    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    var color: Color = .white
    var spacing: CGFloat = 34
    var speed: Double = 26   // points per second

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var shouldScroll: Bool { textWidth > containerWidth + 1 }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: spacing) {
                label
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: MarqueeWidthKey.self, value: inner.size.width)
                        }
                    )
                if shouldScroll { label }
            }
            .offset(x: offset)
            .frame(width: geo.size.width, alignment: .leading)
            .onPreferenceChange(MarqueeWidthKey.self) { width in
                textWidth = width
                containerWidth = geo.size.width
                restart()
            }
            .onChange(of: geo.size.width) { _, _ in
                containerWidth = geo.size.width
                restart()
            }
        }
        .frame(height: 17)
        .clipped()
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private func restart() {
        offset = 0
        guard shouldScroll else { return }
        let distance = textWidth + spacing
        withAnimation(.linear(duration: distance / speed).delay(1.4).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
