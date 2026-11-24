import AppKit

/// Lets an `NSMenuItem` run a closure (carried in `representedObject`).
final class MenuAction {

    let run: () -> Void

    init(run: @escaping () -> Void) {
        self.run = run
    }

    /// One long-lived instance: menu items hold their target weakly.
    static let dispatcher = Dispatcher()

    final class Dispatcher: NSObject {
        @objc func fire(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuAction)?.run()
        }
    }
}
