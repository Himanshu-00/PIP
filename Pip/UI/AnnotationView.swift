import SwiftUI

/// The crop editor, in a real window (the island closes when the pointer leaves).
struct AnnotationView: View {

    let url: URL
    let image: NSImage

    @State private var crop: CGRect?
    /// The gesture in progress, in normalised coordinates.
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            canvas
            Divider().overlay(.white.opacity(0.1))
            toolbar
        }
        .background(Color(white: 0.11))
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            // The image is laid out to fit, so the drawing surface is the
            // image's frame rather than the view's — otherwise a drag in the
            // letterboxed margin would start a crop outside the picture.
            let frame = fitted(in: geometry.size)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.3)

                Image(nsImage: image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)

                if let box = liveCrop {
                    cropOverlay(box, in: frame)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        dragStart = dragStart ?? normalise(value.startLocation, in: frame)
                        dragEnd = normalise(value.location, in: frame)
                    }
                    .onEnded { _ in commitDrag() }
            )
        }
    }

    private var liveCrop: CGRect? {
        guard let dragStart, let dragEnd else { return crop }
        return CGRect(x: min(dragStart.x, dragEnd.x),
                      y: min(dragStart.y, dragEnd.y),
                      width: abs(dragEnd.x - dragStart.x),
                      height: abs(dragEnd.y - dragStart.y))
    }

    private func commitDrag() {
        defer { dragStart = nil; dragEnd = nil }
        // A tap rather than a drag clears the crop, which is the obvious way
        // to undo one.
        if let box = liveCrop, box.width > 0.02, box.height > 0.02 {
            crop = box
        } else {
            crop = nil
        }
    }

    /// Everything outside the crop dimmed.
    private func cropOverlay(_ box: CGRect, in frame: CGRect) -> some View {
        let rect = CGRect(x: frame.minX + box.minX * frame.width,
                          y: frame.minY + box.minY * frame.height,
                          width: box.width * frame.width,
                          height: box.height * frame.height)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.black.opacity(0.55))
                .reverseMask {
                    Rectangle().frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            Rectangle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Geometry

    /// Where the image actually sits, letterboxed inside the view.
    private func fitted(in size: CGSize) -> CGRect {
        let aspect = image.size.width / max(image.size.height, 1)
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2,
                      y: (size.height - height) / 2,
                      width: width, height: height)
    }

    private func normalise(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: ((point.x - frame.minX) / frame.width).clamped(),
                y: ((point.y - frame.minY) / frame.height).clamped())
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Drag to crop")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.45))

            button("Reset", symbol: "arrow.uturn.backward", enabled: crop != nil) {
                crop = nil
            }

            Spacer(minLength: 12)

            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
            }

            button("Copy", symbol: "doc.on.doc") { copy() }
            button("Save a Copy", symbol: "square.and.arrow.down", prominent: true) { save() }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private func button(_ title: String,
                        symbol: String,
                        active: Bool = false,
                        enabled: Bool = true,
                        prominent: Bool = false,
                        action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(prominent ? .black.opacity(0.85)
                         : .white.opacity(enabled ? (active ? 1 : 0.72) : 0.3))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            Capsule().fill(prominent ? .white.opacity(0.92)
                           : .white.opacity(active ? IslandStyle.controlHover
                                            : IslandStyle.controlFill)))
        .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0
                                                       : IslandStyle.controlStroke),
                                        lineWidth: 1))
        .opacity(enabled ? 1 : 0.5)
        .onTapGesture { if enabled { action() } }
    }

    // MARK: - Output

    private var flattened: NSImage? {
        Annotation.render(image, crop: crop)
    }

    private func copy() {
        guard let result = flattened else { return flash("Couldn't render that") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([result])
        flash("Copied")
    }

    /// Saves beside the original, never over it.
    private func save() {
        guard let result = flattened,
              let tiff = result.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return flash("Couldn't render that") }

        let base = url.deletingPathExtension().lastPathComponent
        var destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(base) cropped.png")
        var attempt = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = url.deletingLastPathComponent()
                .appendingPathComponent("\(base) cropped \(attempt).png")
            attempt += 1
        }

        do {
            try png.write(to: destination)
            flash("Saved as \(destination.lastPathComponent)")
        } catch {
            flash("Couldn't save")
        }
    }

    private func flash(_ text: String) {
        note = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if note == text { note = nil }
        }
    }
}

private extension CGFloat {
    func clamped() -> CGFloat { Swift.min(Swift.max(self, 0), 1) }
}

private extension View {
    /// Punches a hole in a shape, for the crop dimming.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .topLeading) { mask().blendMode(.destinationOut) }
                .compositingGroup()
        }
    }
}
