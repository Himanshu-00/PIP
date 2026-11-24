import AppKit
import SwiftUI

/// A real NSView for clicks and hover in the island, where SwiftUI gestures
/// don't fire.
struct ClickableArea: NSViewRepresentable {

    var onClick: () -> Void
    var onHover: (Bool) -> Void
    /// Double-click, when the view wants one. Left nil, a double-click is two
    /// ordinary clicks, which is what most of the island wants.
    var onDoubleClick: (() -> Void)?
    /// Right-click, reported in screen coordinates so the caller can put a
    /// menu where the pointer is.
    var onRightClick: ((NSPoint) -> Void)?
    /// A file to drag out, with its picture (one view owns every mouse gesture).
    var dragPayload: (() -> (url: URL, image: NSImage?)?)?
    /// Where a press landed, in this view's top-left coordinates — before
    /// any click, right-click or drag it starts. For one area laid over
    /// several targets (the screenshot shelf), so it can tell which.
    var onPress: ((CGPoint) -> Void)?
    /// Where the pointer is while inside, top-left coordinates; nil when it
    /// leaves. Hover for an area with several targets.
    var onPointer: ((CGPoint?) -> Void)?
    /// Scroll-wheel or trackpad movement, in points. Unset, scrolling passes
    /// through to whatever is behind.
    var onScroll: ((CGFloat) -> Void)?
    /// A drag this area started has ended: whether something took it, and
    /// whether ⌥ was held when it was let go. For the drop shelf, where a
    /// file dragged somewhere leaves the shelf unless ⌥ keeps it.
    var onDragEnded: ((_ accepted: Bool, _ optionHeld: Bool) -> Void)?

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: ClickView) {
        view.onClick = onClick
        view.onHover = onHover
        view.onDoubleClick = onDoubleClick
        view.onRightClick = onRightClick
        view.dragPayload = dragPayload
        view.onPress = onPress
        view.onPointer = onPointer
        view.onScroll = onScroll
        view.onDragEnded = onDragEnded
    }
}

final class ClickView: NSView {

    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onDoubleClick: (() -> Void)?
    var onRightClick: ((NSPoint) -> Void)?
    var dragPayload: (() -> (url: URL, image: NSImage?)?)?
    var onPress: ((CGPoint) -> Void)?
    var onPointer: ((CGPoint?) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onDragEnded: ((Bool, Bool) -> Void)?

    /// `event`'s position with the origin at the top left, like SwiftUI's.
    private func topLeft(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
    }

    /// The island belongs to an accessory app that is rarely active, and
    /// without this the first click would be spent activating it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Swallow it: accepting mouseDown is what makes us eligible for the
        // matching mouseUp.
        onPress?(topLeft(event))
    }

    override func mouseUp(with event: NSEvent) {
        // Only fire if the pointer is still inside — dragging off a button and
        // releasing should cancel, the way every other button on the system does.
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }

        // With a double-click handler, the single click waits for a possible second.
        guard let onDoubleClick else { onClick(); return }
        if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
            onDoubleClick()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingClick = nil
            self?.onClick()
        }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval,
                                      execute: work)
    }

    /// A drag cancels the click that started it.
    override func mouseDragged(with event: NSEvent) {
        guard let dragPayload, let payload = dragPayload() else { return }
        guard !dragging else { return }

        pendingClick?.cancel()
        pendingClick = nil
        dragging = true

        let item = NSDraggingItem(pasteboardWriter: payload.url as NSURL)
        let picture = payload.image ?? NSWorkspace.shared.icon(forFile: payload.url.path)
        item.setDraggingFrame(dragFrame(for: picture, at: convert(event.locationInWindow, from: nil)),
                              contents: picture)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// The picture's size, no bigger than this view or a thumbnail, centred
    /// under the pointer. Not `bounds`: when this view covers a whole row,
    /// that would stretch one thumbnail across all of them.
    private func dragFrame(for picture: NSImage, at point: NSPoint) -> NSRect {
        let limit = NSSize(width: min(bounds.width, 120), height: min(bounds.height, 80))
        let size = picture.size
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(limit.width / size.width, limit.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: point.x - fitted.width / 2, y: point.y - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onRightClick else { return super.rightMouseDown(with: event) }
        onPress?(topLeft(event))
        onRightClick(NSEvent.mouseLocation)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let onScroll else { return super.scrollWheel(with: event) }
        // Trackpads scroll sideways; mouse wheels only up and down.
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        onScroll(event.hasPreciseScrollingDeltas ? delta : delta * 10)
    }

    private var pendingClick: DispatchWorkItem?
    private var dragging = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
        onPointer?(topLeft(event))
    }
    override func mouseMoved(with event: NSEvent) {
        guard let onPointer else { return super.mouseMoved(with: event) }
        onPointer(topLeft(event))
    }
    override func mouseExited(with event: NSEvent) {
        onHover(false)
        onPointer?(nil)
    }
}

extension ClickView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext)
    -> NSDragOperation {
        // Copy, never move. The shelf is a view onto the screenshot folder and
        // has no business letting a drag relocate the original out of it.
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt point: NSPoint,
                         operation: NSDragOperation) {
        dragging = false
        onDragEnded?(operation != [], NSEvent.modifierFlags.contains(.option))
    }
}
