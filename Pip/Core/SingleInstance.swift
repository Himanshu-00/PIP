import AppKit

/// Makes sure only one copy of the app is ever running.
///
/// This matters more than it sounds. The app is `.accessory` — no Dock icon, no
/// window — so a copy left over from an earlier run is completely invisible.
/// Xcode's Stop kills the process *it* launched and nothing else, so a session
/// of ⌘R, ⌘., ⌘R quietly accumulates orphans, each with its own hotkey
/// registrations and its own event monitors.
///
/// The symptom is bizarre and hard to trace: shortcuts fire twice, permissions
/// look granted but behave as though they aren't (the copy holding the grant
/// isn't the copy you're testing), and quitting from the menu bar appears not
/// to work because another instance immediately takes over the menu bar item.
@MainActor
enum SingleInstance {

    /// Terminates every other copy, politely first and then not.
    static func claim() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current.processIdentifier

        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }

        others.forEach { $0.terminate() }

        // An accessory app with no windows usually goes at once, but a copy
        // stuck in a modal (an open panel, a permission prompt) will ignore the
        // quit event. Those get one second, then no more choices.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for app in others where !app.isTerminated {
                app.forceTerminate()
            }
        }
    }

}
