import AppKit
import SwiftUI

/// The panel's content view: `acceptsFirstMouse` (no wasted first click),
/// and a drop target for the drop shelf (drags from the shelf refused).
final class PanelHostView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A file drag is over the panel (shows "Drop to keep here").
    var onTargeting: ((Bool) -> Void)?
    /// Files were dropped.
    var onDrop: (([URL]) -> Void)?

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func files(in info: NSDraggingInfo) -> [URL] {
        // Our own drags (the shelves) have a source in this app.
        guard info.draggingSource == nil else { return [] }
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                   options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !files(in: sender).isEmpty else { return [] }
        onTargeting?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(in: sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeting?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(in: sender)
        onTargeting?(false)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeting?(false)
    }
}
