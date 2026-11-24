import AppKit
import ScreenCaptureKit

/// Screenshots for Pip (ScreenCaptureKit, Screen Recording permission),
/// his own window left out.
@MainActor
enum ScreenCapture {

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Target {
        /// Everything on the main display.
        case screen
        /// Just the front window of the app you were using.
        case frontWindow
    }

    /// - Parameter menuBar: false leaves the menu bar off a whole-screen
    ///   picture. Pip, asked a flight's date, read the menu-bar clock
    ///   ("November 6") instead of the ticket.
    static func capture(_ target: Target, menuBar: Bool = true) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt (once); the permission takes effect
            // after the user allows it.
            CGRequestScreenCaptureAccess()
            throw Failure(message: "I need Screen Recording permission to see your screen. Allow Pip "
                          + "in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then ask again.")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ourselves = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }

        let filter: SCContentFilter
        let size: CGSize
        switch target {
        case .frontWindow:
            let pid = TargetApp.current?.processIdentifier
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
                    && $0.frame.width > 80 && $0.frame.height > 80
            }
            // The biggest of that app's normal windows is the one in use.
            guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else {
                return try await capture(.screen, menuBar: menuBar)
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
        case .screen:
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
                throw Failure(message: "I couldn't find a display to look at.")
            }
            filter = SCContentFilter(display: display, excludingApplications: ourselves, exceptingWindows: [])
            size = CGSize(width: display.width, height: display.height)
            if !menuBar, let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == mainID
            }) {
                let bar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
                let below = CGRect(x: 0, y: bar, width: size.width, height: size.height - bar)
                return try await capture(filter: filter, size: below.size, sourceRect: below)
            }
        }

        return try await capture(filter: filter, size: size)
    }

    /// One rectangle of the screen, in Quartz points (top-left origin), at
    /// full Retina resolution — small text in it has to be readable. Our own
    /// windows are left out. For click to ask.
    static func capture(rect: CGRect) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw Failure(message: "Screen Recording permission is off.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else {
            throw Failure(message: "That spot isn't on a display.")
        }
        let clipped = rect.intersection(display.frame)
        let ourselves = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ourselves, exceptingWindows: [])
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.backingScaleFactor ?? 2

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = clipped.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = max(1, Int(clipped.width * scale))
        configuration.height = max(1, Int(clipped.height * scale))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func capture(filter: SCContentFilter, size: CGSize, sourceRect: CGRect? = nil) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        if let sourceRect { configuration.sourceRect = sourceRect }
        // Points, not Retina pixels: the picture is shrunk for the model
        // anyway, and half the pixels is a faster capture.
        configuration.width = max(1, Int(size.width))
        configuration.height = max(1, Int(size.height))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
