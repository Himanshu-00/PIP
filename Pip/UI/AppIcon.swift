import AppKit

/// Icon for whichever app is producing the audio, cached because this is read
/// from a SwiftUI body and would otherwise hit the filesystem every redraw.
@MainActor
enum AppIcon {

    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }

        var image = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first?
            .icon

        if image == nil,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }

        if let image { cache[bundleID] = image }
        return image
    }
}
