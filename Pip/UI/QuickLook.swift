import AppKit
import QuickLookUI

/// Space-bar preview from a non-key panel: activates, makes the panel key,
/// and becomes Quick Look's data source.
@MainActor
final class QuickLook: NSObject {

    static let shared = QuickLook()

    private var urls: [URL] = []

    /// Previews a file, or closes the preview if it's already showing it.
    func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible, urls.first == url {
            panel.orderOut(nil)
            return
        }

        urls = [url]

        // Quick Look needs the app frontmost, as Finder does.
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
}

extension QuickLook: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!,
                                  previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            urls.indices.contains(index) ? urls[index] as NSURL : nil
        }
    }
}

extension QuickLook: QLPreviewPanelDelegate {
    /// Lets Escape close the panel rather than falling through to the island,
    /// which would close the shelf behind it and leave the preview orphaned.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!,
                                  handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53 else { return false }
        MainActor.assumeIsolated { panel.orderOut(nil) }
        return true
    }
}
