import AppKit
import SwiftUI

/// Hosts the crop editor in one reused real window.
@MainActor
final class AnnotationWindow: NSObject {

    static let shared = AnnotationWindow()

    private var window: NSWindow?

    func open(_ url: URL) {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return }

        close()

        let size = fittedSize(for: image)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        window.title = url.lastPathComponent
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(white: 0.11, alpha: 1)
        window.minSize = NSSize(width: 480, height: 360)
        window.delegate = self

        // No close callback: the window is `.titled`, so its own close button
        // and ⌘W already do it, and `windowWillClose` clears the reference.
        window.contentView = NSHostingView(rootView: AnnotationView(url: url, image: image))

        window.center()
        // An accessory app has to activate for a window of its own to take the
        // keyboard — the same thing Quick Look needs, for the same reason.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    /// Big enough to work in, never bigger than the screen it opens on.
    private func fittedSize(for image: NSImage) -> NSSize {
        let toolbar: CGFloat = 48
        let visible = (NSScreen.main?.visibleFrame.size
                       ?? NSSize(width: 1440, height: 900))
        let maximum = NSSize(width: visible.width * 0.8,
                             height: visible.height * 0.8 - toolbar)

        var width = min(image.size.width, maximum.width)
        var height = width * image.size.height / max(image.size.width, 1)
        if height > maximum.height {
            height = maximum.height
            width = height * image.size.width / max(image.size.height, 1)
        }
        return NSSize(width: max(width, 480), height: max(height, 300) + toolbar)
    }
}

extension AnnotationWindow: NSWindowDelegate {
    /// Dropping the reference on close matters: `isReleasedWhenClosed` is off
    /// so the window survives being closed, and without this the next open
    /// would reuse a window the user has already dismissed.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
