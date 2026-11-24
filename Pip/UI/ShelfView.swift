import SwiftUI

/// The screenshot shelf: one `ClickableArea` over the whole row picks the
/// thumbnail from x; the row scrolls itself (no ScrollView).
struct ShelfView: View {

    @ObservedObject var shelf: ScreenshotShelf
    /// Flashes a word over the row when something has been put on the
    /// clipboard — copying is silent otherwise, and a silent action is
    /// indistinguishable from one that didn't happen.
    @State private var note: String?
    /// Where the pointer is over the row, top-left coordinates.
    @State private var pointer: CGPoint?
    /// How far the row is scrolled, in points.
    @State private var offset: CGFloat = 0
    /// The thumbnail a click, right-click or drag started on. A box, not
    /// state: it's written and read inside the same event, before SwiftUI
    /// would have re-rendered.
    @State private var press = Press()
    private final class Press { var shot: ScreenshotShelf.Shot? }

    /// Big enough to read a shot's content.
    static let thumbnailHeight: CGFloat = 60
    private let thumbnailWidth: CGFloat = 96
    private let spacing: CGFloat = 10
    private let inset: CGFloat = 2

    var body: some View {
        if shelf.shots.isEmpty {
            empty
        } else {
            row
        }
    }

    private var row: some View {
        GeometryReader { proxy in
            let shots: [ScreenshotShelf.Shot] = shelf.shots
            let stride: CGFloat = thumbnailWidth + spacing
            let content: CGFloat = CGFloat(shots.count) * stride - spacing + inset * 2
            let maxOffset: CGFloat = max(0, content - proxy.size.width)
            let scrolled: CGFloat = min(max(offset, 0), maxOffset)
            // The thumbnail under x, if x is on one rather than in a gap.
            let shot: (CGFloat) -> ScreenshotShelf.Shot? = { x in
                let local = x + scrolled - inset
                guard local >= 0 else { return nil }
                let index = Int(local / stride)
                guard index < shots.count, local - CGFloat(index) * stride <= thumbnailWidth else { return nil }
                return shots[index]
            }
            let hovered: URL? = pointer.flatMap { shot($0.x) }?.url

            HStack(spacing: spacing) {
                ForEach(shots) { item in
                    thumbnail(item, hovered: hovered == item.url)
                }
            }
            .padding(.horizontal, inset)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: -scrolled)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipped()
            .overlay(ClickableArea(
                onClick: {
                    guard let item = press.shot else { return }
                    flash(shelf.copyImage(item) ? "Copied" : "Couldn't read that file")
                },
                onHover: { _ in },
                onDoubleClick: {
                    guard let item = press.shot else { return }
                    QuickLook.shared.show(item.url)
                },
                onRightClick: { point in
                    guard let item = press.shot else { return }
                    menu(for: item, at: point)
                },
                // The file itself, so the receiving app gets a real screenshot
                // rather than a path string — Mail attaches it, Slack uploads it.
                dragPayload: {
                    guard let item = press.shot else { return nil }
                    return (item.url, item.thumbnail)
                },
                onPress: { point in press.shot = shot(point.x) },
                onPointer: { point in
                    if pointer != point { pointer = point }
                },
                onScroll: { delta in
                    let next = min(max(scrolled - delta, 0), maxOffset)
                    if next != offset { offset = next }
                }))
        }
        .frame(height: Self.thumbnailHeight)
        .overlay(alignment: .center) {
            if let note {
                Text(note)
                    .font(.system(size: 11.5, weight: .semibold))
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.25)) { note = nil }
        }
    }

    private func thumbnail(_ shot: ScreenshotShelf.Shot, hovered: Bool) -> some View {
        Group {
            if let image = shot.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // The thumbnail is decoded on the main actor during a refresh,
                // so it is normally already there. This is for the case where
                // the file was removed between listing it and reading it.
                Color.white.opacity(IslandStyle.surfaceFill)
                    .overlay(Image(systemName: "photo")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3)))
            }
        }
        .frame(width: thumbnailWidth, height: Self.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .hoverGlow(hovered, cornerRadius: 11)
        // A pin is worth a mark, or pinning is a state you can only discover
        // by opening the menu again.
        .overlay(alignment: .topTrailing) {
            if shot.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(4)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .padding(4)
            }
        }
    }

    /// Everything but click and drag, in a menu.
    private func menu(for shot: ScreenshotShelf.Shot, at point: NSPoint) {
        let menu = NSMenu()

        menu.addItem(item("Copy Image") {
            flash(shelf.copyImage(shot) ? "Copied" : "Couldn't read that file")
        })
        menu.addItem(item("Copy Text") {
            Task { @MainActor in
                flash(await shelf.copyText(shot) ? "Text copied" : "No text found")
            }
        })
        menu.addItem(.separator())
        menu.addItem(item("Crop…") { AnnotationWindow.shared.open(shot.url) })
        menu.addItem(item("Quick Look") { QuickLook.shared.show(shot.url) })
        menu.addItem(item(shot.pinned ? "Unpin" : "Pin") { shelf.togglePin(shot) })
        menu.addItem(.separator())
        menu.addItem(item("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([shot.url])
        })

        menu.popUp(positioning: nil, at: point, in: nil)
    }

    private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.representedObject = MenuAction(run: action)
        entry.target = MenuAction.dispatcher
        entry.action = #selector(MenuAction.Dispatcher.fire(_:))
        return entry
    }

    private var empty: some View {
        HStack(spacing: 7) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 12))
            Text("Screenshots you take will appear here")
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.3))
        .frame(height: Self.thumbnailHeight)
    }
}

/// A shelf tile's border: a 1 pt outline that brightens on hover, as the
/// search bar's and the now-playing chip's do.
struct HoverGlow: ViewModifier {

    let hovered: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .overlay(shape.strokeBorder(.white.opacity(hovered ? 0.32 : IslandStyle.imageStroke), lineWidth: 1))
            .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

extension View {
    func hoverGlow(_ hovered: Bool, cornerRadius: CGFloat) -> some View {
        modifier(HoverGlow(hovered: hovered, cornerRadius: cornerRadius))
    }
}
