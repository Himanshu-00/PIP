import AppKit

/// Cropping a screenshot and baking the crop in (crop only).
enum Annotation {

    /// The cropped picture at the source's pixel size (not `lockFocus`).
    static func render(_ image: NSImage, crop: CGRect?) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let full = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        // The crop arrives normalised with a top-left origin, because that is
        // how the view hands it over; CoreGraphics is bottom-left.
        let box = crop.map { rect in
            CGRect(x: rect.minX * full.width,
                   y: (1 - rect.maxY) * full.height,
                   width: rect.width * full.width,
                   height: rect.height * full.height)
        }?.integral ?? full

        guard box.width >= 1, box.height >= 1,
              let space = source.colorSpace,
              let context = CGContext(data: nil,
                                      width: Int(box.width),
                                      height: Int(box.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // The whole image drawn offset, so the crop doesn't keep the original alive.
        context.draw(source, in: CGRect(x: -box.minX, y: -box.minY,
                                        width: full.width, height: full.height))

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: box.width, height: box.height))
    }
}
