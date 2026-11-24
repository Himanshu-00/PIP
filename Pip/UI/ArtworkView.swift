import SwiftUI

/// Album art as a rounded square, sized inside before the clip (or the clip
/// rounds an oversized image).
struct ArtworkView: View {

    let image: NSImage?
    var size: CGFloat
    var cornerRadius: CGFloat
    var glyphSize: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.34), Color(white: 0.17)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: glyphSize, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(
            // Hairline rim so dark album art doesn't dissolve into the black island.
            shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        )
    }
}
