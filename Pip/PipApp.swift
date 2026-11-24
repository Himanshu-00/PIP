import SwiftUI

@main
struct PipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app is an LSUIElement (no Dock icon, no windows of its own).
        // Everything lives in the borderless notch panel created by AppDelegate.
        Settings { EmptyView() }
    }
}
