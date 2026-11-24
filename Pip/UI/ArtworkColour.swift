import AppKit
import SwiftUI

/// The island's tint from album art: the most saturated grid cell that
/// isn't too dark or pale.
enum ArtworkColour {

    private static var cache: [String: NSColor] = [:]

    static func accent(from image: NSImage, key: String) -> Color {
        if let cached = cache[key] { return Color(nsColor: cached) }
        let colour = extract(from: image) ?? .white
        if cache.count > 60 { cache.removeAll() }
        cache[key] = colour
        return Color(nsColor: colour)
    }

    private static func extract(from image: NSImage) -> NSColor? {
        let side = 16
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var best: (score: CGFloat, colour: NSColor)?
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = CGFloat(pixels[index]) / 255
            let green = CGFloat(pixels[index + 1]) / 255
            let blue = CGFloat(pixels[index + 2]) / 255

            let highest = max(red, green, blue)
            let lowest = min(red, green, blue)
            let saturation = highest == 0 ? 0 : (highest - lowest) / highest

            // Skip near-black and near-white: both are common in cover art and
            // neither reads as "the colour of this album".
            guard highest > 0.22, lowest < 0.94 else { continue }

            let score = saturation * 1.6 + highest * 0.4
            if best == nil || score > best!.score {
                best = (score, NSColor(red: red, green: green, blue: blue, alpha: 1))
            }
        }

        guard let winner = best?.colour else { return nil }
        return lift(winner)
    }

    /// The island is black, so a dark or washed-out accent disappears into it.
    /// Push everything to a floor of brightness and saturation.
    private static func lift(_ colour: NSColor) -> NSColor {
        guard let converted = colour.usingColorSpace(.deviceRGB) else { return colour }
        var hue: CGFloat = 0, saturation: CGFloat = 0
        var brightness: CGFloat = 0, alpha: CGFloat = 0
        converted.getHue(&hue, saturation: &saturation,
                         brightness: &brightness, alpha: &alpha)
        return NSColor(hue: hue,
                       saturation: min(max(saturation, 0.55), 0.95),
                       brightness: min(max(brightness, 0.78), 1.0),
                       alpha: 1)
    }
}
