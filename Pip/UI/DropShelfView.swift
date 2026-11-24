import QuickLookThumbnailing
import SwiftUI

/// The drop shelf's row: files parked in the notch (`DropShelf`).
///
/// Built like `ShelfView`, for the same reason: one `ClickableArea` over the
/// whole row works out from the pointer which tile it's on, so click, drag,
/// right-click and the × agree about what's happening. Per-tile areas inside
/// SwiftUI layout stopped taking the mouse there.
///
/// Click = Quick Look. Drag out = into Mail, an upload box or Finder; once
/// something takes it, it leaves the shelf, unless ⌥ is held. The × on the
/// hovered tile removes it; its "…", or a right-click, opens the menu with
/// the quick actions that fit the file (`FileActions`).
struct DropShelfView: View {

    @ObservedObject var shelf: DropShelf
    @ObservedObject private var thumbnails = FileThumbnails.shared
    @State private var pointer: CGPoint?
    @State private var offset: CGFloat = 0
    /// A word over the row after an action ("4.2 MB → 1.1 MB").
    @State private var note: String?
    @State private var working = false
    /// What a press landed on. A box, not state: written and read in the same event.
    @State private var press = Press()
    private final class Press {
        var item: DropShelf.Item?
        var spot: Spot = .body
    }
    private enum Spot { case body, close, more }

    static let rowHeight: CGFloat = 60
    /// The same tile as the screenshot shelf above it.
    private let tileWidth: CGFloat = 96
    private let spacing: CGFloat = 10
    private let inset: CGFloat = 2
    /// The × in a tile's top-right corner, as a square from that corner.
    private let closeSize: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let items = shelf.items
            let stride = tileWidth + spacing
            let content = CGFloat(items.count) * stride - spacing + inset * 2
            let maxOffset = max(0, content - proxy.size.width)
            let scrolled = min(max(offset, 0), maxOffset)
            // The tile under a point, and which part: its ×, its "…", or the rest.
            let hit: (CGPoint) -> (DropShelf.Item, Spot)? = { point in
                let local = point.x + scrolled - inset
                guard local >= 0 else { return nil }
                let index = Int(local / stride)
                let within = local - CGFloat(index) * stride
                guard index < items.count, within <= tileWidth else { return nil }
                let corner = point.y <= closeSize
                let spot: Spot = corner && within >= tileWidth - closeSize ? .close
                    : corner && within <= closeSize ? .more : .body
                return (items[index], spot)
            }
            let hovered = pointer.flatMap { hit($0) }?.0.url

            HStack(spacing: spacing) {
                ForEach(items) { item in
                    tile(item, hovered: hovered == item.url)
                }
            }
            .padding(.horizontal, inset)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: -scrolled)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipped()
            .overlay(ClickableArea(
                onClick: {
                    guard let item = press.item else { return }
                    switch press.spot {
                    case .close: shelf.remove(item.url, why: "removed with ×")
                    case .more:  menu(for: item, at: NSEvent.mouseLocation)
                    case .body:  QuickLook.shared.show(item.url)
                    }
                },
                onHover: { _ in },
                onRightClick: { point in
                    guard let item = press.item else { return }
                    menu(for: item, at: point)
                },
                dragPayload: {
                    guard let item = press.item, press.spot == .body else { return nil }
                    return (item.url, NSWorkspace.shared.icon(forFile: item.url.path))
                },
                onPress: { point in
                    let found = hit(point)
                    press.item = found?.0
                    press.spot = found?.1 ?? .body
                },
                onPointer: { point in
                    if pointer != point { pointer = point }
                },
                onScroll: { delta in
                    let next = min(max(scrolled - delta, 0), maxOffset)
                    if next != offset { offset = next }
                },
                onDragEnded: { accepted, optionHeld in
                    guard accepted, !optionHeld, let item = press.item else { return }
                    shelf.remove(item.url, why: "dragged out")
                }))
        }
        .frame(height: Self.rowHeight)
        .overlay(alignment: .center) {
            if let note = working ? "Working…" : note {
                Text(note)
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.12)) { note = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard note == text else { return }
            withAnimation(.easeOut(duration: 0.25)) { note = nil }
        }
    }

    /// Runs a `FileActions` job off the main thread; the result joins the shelf.
    private func run(_ job: @escaping @Sendable () -> FileActions.Outcome) {
        guard !working else { return }
        working = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated, operation: job).value
            working = false
            if let file = outcome.file { shelf.add([file]) }
            flash(outcome.message)
        }
    }

    /// A preview of the file (a PDF's first page, the picture, a video's
    /// frame), or its icon when it has none; the name on a fade at the foot.
    private func tile(_ item: DropShelf.Item, hovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let preview = thumbnails.image(for: item.url)
        return ZStack(alignment: .bottomLeading) {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: tileWidth, height: Self.rowHeight)
            } else {
                Color.white.opacity(IslandStyle.surfaceFill)
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 30, height: 30)
                    .frame(width: tileWidth, height: Self.rowHeight - 14)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(height: 26)
            Text(item.url.lastPathComponent)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
        }
        .frame(width: tileWidth, height: Self.rowHeight)
        .clipShape(shape)
        .hoverGlow(hovered, cornerRadius: 10)
        .brightness(hovered ? 0.03 : 0)
        .overlay(alignment: .topLeading) {
            if hovered {
                Image(systemName: "ellipsis")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(.black.opacity(0.6)))
                    .padding(3)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovered {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(.black.opacity(0.6)))
                    .padding(3)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func menu(for item: DropShelf.Item, at point: NSPoint) {
        let menu = NSMenu()
        let url = item.url
        let pdfs = shelf.items.map(\.url).filter(FileActions.isPDF)
        let pictures = shelf.items.map(\.url).filter(FileActions.isImage)
        if FileActions.isPDF(url) {
            menu.addItem(entry("Compress") { run { FileActions.compressPDF(url) } })
            if pdfs.count >= 2 {
                menu.addItem(entry("Merge \(pdfs.count) PDFs on the Shelf") { run { FileActions.mergePDFs(pdfs) } })
            }
            menu.addItem(.separator())
        } else if FileActions.isImage(url) {
            if !["jpg", "jpeg"].contains(url.pathExtension.lowercased()) {
                menu.addItem(entry("Convert to JPEG") { run { FileActions.convertToJPG(url) } })
            }
            menu.addItem(entry("Resize to 50%") { run { FileActions.resize(url, fraction: 0.5) } })
            menu.addItem(entry("Resize to 1600 px") { run { FileActions.resize(url, longEdge: 1_600) } })
            menu.addItem(entry("Make PDF") { run { FileActions.makePDF([url]) } })
            if pictures.count >= 2 {
                menu.addItem(entry("Make One PDF of \(pictures.count) Pictures") { run { FileActions.makePDF(pictures) } })
            }
            menu.addItem(.separator())
        }
        menu.addItem(entry("Quick Look") { QuickLook.shared.show(item.url) })
        menu.addItem(entry("Open") { NSWorkspace.shared.open(item.url) })
        menu.addItem(entry("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) })
        menu.addItem(.separator())
        menu.addItem(entry("Remove from Shelf") { shelf.remove(item.url, why: "removed from the menu") })
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    private func entry(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.Dispatcher.fire(_:)), keyEquivalent: "")
        item.representedObject = MenuAction(run: action)
        item.target = MenuAction.dispatcher
        return item
    }
}

/// "Drop to keep here": the open panel while a file drag is over it.
struct DropTargetView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 20, weight: .regular))
            Text("Drop to keep here")
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

/// Quick Look thumbnails for the drop shelf, made once per file and kept
/// for the session (a handful of files; cleared past 60).
@MainActor
private final class FileThumbnails: ObservableObject {

    static let shared = FileThumbnails()
    @Published private(set) var images: [URL: NSImage] = [:]
    /// Asked for already, so a file without a thumbnail isn't asked again.
    private var asked: Set<URL> = []

    func image(for url: URL) -> NSImage? {
        if let image = images[url] { return image }
        if !asked.contains(url) {
            asked.insert(url)
            load(url)
        }
        return nil
    }

    private func load(_ url: URL) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 60),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.cgImage else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.images.count > 60 { self.images.removeAll() }
                self.images[url] = NSImage(cgImage: image, size: .zero)
            }
        }
    }
}
