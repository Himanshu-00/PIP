import SwiftUI

/// The search panel; the selection follows the file as results reorder.
struct SearchView: View {

    @EnvironmentObject private var state: NotchState
    @ObservedObject var search: SearchController
    /// The width the hover panel's bar has, which is where this field starts.
    static let barWidth: CGFloat = 186

    /// False for the first frame, then the field widens to fill the panel.
    @State private var fieldExpanded = false

    /// Everything below the field, revealed a beat after it has grown.
    @State private var revealed = false


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clear of the camera, the same as the hover panel, so bar and field line up.
            Color.clear.frame(height: state.metrics.notchSize.height + 10)

            // Grown, not faded: the field starts at the bar's size and widens.
            field
                .frame(width: fieldWidth, alignment: .leading)
                .padding(.bottom, 16)
                .onAppear {
                    withAnimation(.islandWidth) { fieldExpanded = true }
                }

            // Grouped so the reveal below has one view to attach to.
            Group {
                if search.results.isEmpty {
                    empty
                } else {
                    results
                }
            }
            // The field expands first; the rest fades in once it's nearly there.
            .opacity(revealed ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.18).delay(0.20)) { revealed = true }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(width: state.searchSize.width, height: state.searchSize.height, alignment: .top)
    }

    /// 186 on the first frame, the panel's full content width after that.
    private var fieldWidth: CGFloat {
        fieldExpanded ? max(state.searchSize.width - 40, Self.barWidth) : Self.barWidth
    }

    /// The list and the detail card, side by side, above the footer.
    private var results: some View {
        VStack(spacing: 0) {
            // Results on the left, the selected one described on the right.
            HStack(spacing: 12) {
                list
                    .frame(width: NotchState.searchListWidth)

                // The detail pane on its own lifted surface.
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(IslandStyle.surfaceFill))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(IslandStyle.controlStroke),
                                              lineWidth: 1)))
            }
            footer
        }
    }

    // MARK: - Detail

    /// What's currently highlighted, which is what the pane describes.
    private var current: Candidate? {
        search.results.indices.contains(search.selection)
            ? search.results[search.selection]
            : search.results.first
    }

    private var detail: some View {
        Group {
            if let candidate = current {
                DetailPane(candidate: candidate,
                           onReveal: { search.reveal(candidate) })
                    // Keyed to the file, so the pane is replaced as one.
                    .id(candidate.url)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .padding(.horizontal, 10)
        .animation(.easeOut(duration: 0.14), value: current?.url)
    }

    // MARK: - Footer

    /// The count ("5 of 31") and what the keys do.
    private var footer: some View {
        HStack(spacing: 18) {
            Text(countLabel)
                .foregroundStyle(.white.opacity(0.34))

            Spacer(minLength: 0)

            ForEach(Self.hints) { hint in
                HStack(spacing: 5) {
                    // Keycaps, not chips: a fixed minimum width so the three
                    // of them line up, and a hairline for the moulded edge a
                    // key has.
                    Text(hint.keys)
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(minWidth: 11)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(.white.opacity(IslandStyle.controlFill))
                                .overlay(Capsule().strokeBorder(
                                    .white.opacity(IslandStyle.controlStroke), lineWidth: 1)))
                    Text(hint.label)
                        .foregroundStyle(.white.opacity(0.30))
                }
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.45))
        .frame(height: NotchState.searchFooterHeight)
        .overlay(alignment: .top) {
            // Anchors the row to the content above it. Without a rule the
            // hints read as three loose labels adrift at the bottom edge.
            Rectangle().fill(.white.opacity(IslandStyle.hairline)).frame(height: 1)
        }
    }

    /// A struct rather than a tuple because `ForEach(_:id:)` needs a key path,
    /// and Swift has no key paths into tuple elements. Cost me a compile error
    /// once already in this project.
    private struct KeyHint: Identifiable {
        let keys: String
        let label: String
        var id: String { keys }
    }

    private static let hints = [
        KeyHint(keys: "tab", label: "ask Pip"),
        KeyHint(keys: "↑↓", label: "navigate"),
        KeyHint(keys: "↵", label: "open"),
        KeyHint(keys: "esc", label: "close"),
    ]

    private var countLabel: String {
        let shown = search.results.count
        let hidden = search.showsWeak ? 0 : search.prunedCount
        if hidden > 0 { return "\(shown) of \(shown + hidden) results" }
        return shown == 1 ? "1 result" : "\(shown) results"
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                // Starts at the hovered brightness, because the pointer was
                // over the bar when it was clicked — so at t=0 this is the
                // same glyph at the same weight — then settles as it widens.
                .foregroundStyle(.white.opacity(fieldExpanded ? 0.5 : 0.8))

            SearchField(text: $search.query,
                     focusToken: search.focusToken,
                     placeholder: placeholder,
                     onSubmit: { search.openSelected() },
                     onCancel: { search.close() })
                .frame(height: 24)
                .onChange(of: search.query) { _, _ in search.queryChanged() }

            if let folder = search.folder {
                // The scope, visible and dismissable.
                HStack(spacing: 4) {
                    Text(folder.lastPathComponent)
                        .lineLimit(1)
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(IslandStyle.controlFill))
                    .overlay(Capsule().strokeBorder(.white.opacity(IslandStyle.controlStroke),
                                                    lineWidth: 1)))
                .overlay(ClickableArea(onClick: { search.widen() }, onHover: { _ in }))
            }

            if !status.isEmpty {
                // Says what it's doing, without a spinner that implies you
                // should wait. You shouldn't — whatever is already on screen
                // is usable, and this is only about what might still arrive.
                Text(status)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.34))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        // A capsule outline, matching the bar it grows from; starts bright, settles.
        .background(
            Capsule()
                .strokeBorder(.white.opacity(revealed ? IslandStyle.controlStroke
                                                      : NotchRootView.barStrokeHover),
                              lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: status)
    }

    /// What the search is doing ("searching the last year — 75 files read").
    private var status: String {
        guard !search.query.isEmpty else { return "" }
        let climbing = search.reach.label
        if !climbing.isEmpty { return climbing }
        return search.phase == .refining ? "refining" : ""
    }

    private var placeholder: String {
        return search.folder == nil ? "Search everything…" : "Search this folder…"
    }

    // MARK: - Results

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // One header, or a header per group (`ResultGroups`).
                    if search.groupHeaders.isEmpty {
                        sectionHeader(search.showsWeak ? "All matches" : "Best matches")
                    }

                    ForEach(Array(search.results.enumerated()), id: \.element.id) { index, candidate in
                        if let group = search.groupHeaders[index] {
                            sectionHeader(group).padding(.top, index == 0 ? 0 : 8)
                        }
                        Row(candidate: candidate,
                            selected: index == search.selection,
                            scope: search.folder,
                            about: search.abouts[candidate.url])
                            .id(candidate.id)
                            .overlay(ClickableArea(
                                onClick: { search.open(candidate) },
                                onHover: { inside in if inside { search.hover(index) } }))
                    }

                    // What was cut, offered rather than hidden.
                    if search.prunedCount > 0, !search.showsWeak { weaker }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Rows fade at the edges (drawing only; clicks still land).
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.035),
                    .init(color: .black, location: 0.93),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom))
            // Keyed on the keyboard counter, not on the selection. Hovering
            // sets the selection too, and scrolling to a hovered row moves the
            // list out from under the pointer.
            .onChange(of: search.keyboardMoves) { _, _ in
                guard search.results.indices.contains(search.selection) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(search.results[search.selection].id, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        // Label plus a rule running off to the edge: it reads as a divider
        // that happens to be named, rather than a caption floating above the
        // first row with nothing tying it to the list.
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.30))
            Rectangle()
                .fill(.white.opacity(IslandStyle.hairline))
                .frame(height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 9)
    }

    private var weaker: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
            Text("\(search.prunedCount) weaker \(search.prunedCount == 1 ? "match" : "matches")")
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.42))
        .padding(.horizontal, 10)
        .frame(height: 30)
        // A dashed rule under it, so the cut is visible as a boundary rather
        // than implied by a sentence. The list ends here and there is more.
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(IslandStyle.hairline)).frame(height: 1)
                .padding(.horizontal, 6)
        }
        .overlay(ClickableArea(onClick: { search.revealWeaker() }, onHover: { _ in }))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(search.query.count < 2 ? "Type to search"
                 : search.reach == .folder ? "Nothing found" : "Still looking…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text(search.query.count < 2
                 ? "By name, or by what's inside — “the paper about attention” works."
                 : search.reach != .folder
                   ? "Widening out — reading files the index doesn't know about."
                   : search.folder != nil
                     ? "Nothing here. Press → to search everywhere instead."
                     : "Nothing matched, anywhere obvious.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.28))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }
}

// MARK: - Detail pane

/// The selected file, described.
private struct DetailPane: View {

    let candidate: Candidate
    var onReveal: () -> Void

    var body: some View {
        // Everything at the top as a fixed block, nothing stretching.
        VStack(spacing: 0) {
            // The icon on a soft disc. Finder icons are ragged silhouettes at
            // this size and a quiet backdrop gives them an edge to sit against
            // rather than floating on the panel.
            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path))
                .resizable()
                .frame(width: 52, height: 52)
                .padding(11)
                .background(Circle().fill(.white.opacity(IslandStyle.surfaceFill)))

            Text(candidate.displayName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 12)
                .padding(.horizontal, 12)

            if let title = candidate.pdfTitle, title != candidate.displayName {
                // The document's own title, when reading it turned one up. It
                // explains the match without pretending to be the filename —
                // the same split as the rows in the list.
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.34))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .padding(.top, 2)
                    .padding(.horizontal, 10)
            }

            // Tight rows, narrow gutter.
            VStack(spacing: 5) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.label)
                            .foregroundStyle(.white.opacity(0.30))
                            .frame(width: 60, alignment: .trailing)
                        Text(row.value)
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.system(size: 11))
            .padding(.top, 15)
            .padding(.horizontal, 6)

            // Only Show in Finder (a click on the row already opens).
            button("Show in Finder", action: onReveal)
                .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(.white.opacity(IslandStyle.controlFill))
                    .overlay(Capsule().strokeBorder(.white.opacity(IslandStyle.controlStroke),
                                                    lineWidth: 1)))
            // A real NSView, because SwiftUI's gestures don't fire inside a
            // non-activating panel. Same reason every other control here uses it.
            .overlay(ClickableArea(onClick: action, onHover: { _ in }))
    }

    /// Read once per selection change. A struct for `ForEach(_:id:)`.
    struct Fact: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private var rows: [Fact] {
        let values = try? candidate.url.resourceValues(
            forKeys: [.fileSizeKey, .localizedTypeDescriptionKey])

        // Three lines: kind and size share one; "last opened" dropped.
        var kind = values?.localizedTypeDescription
            ?? candidate.url.pathExtension.uppercased()
        if let size = values?.fileSize {
            kind += " · " + ByteCountFormatter.string(fromByteCount: Int64(size),
                                                      countStyle: .file)
        }

        var out = [Fact(label: "Kind", value: kind)]
        if let modified = candidate.modified {
            out.append(Fact(label: "Modified", value: Self.stamp.string(from: modified)))
        }
        out.append(Fact(label: "Where",
                        value: candidate.url.deletingLastPathComponent().path
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~")))
        return out
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

// MARK: - Row

private struct Row: View {

    let candidate: Candidate
    let selected: Bool
    /// The folder being searched, so rows inside it can stay quiet about it.
    let scope: URL?
    /// Pip's description of the file, when he has written one.
    var about: String?

    var body: some View {
        HStack(spacing: 13) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path))
                .resizable()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2.5) {
                // Always the real file name (titles can be guesses).
                Text(candidate.displayName)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Only when it says something the first line didn't. Every row
                // captioned "~/Downloads" while searching Downloads is five
                // repetitions of a fact already on screen.
                if let subtitle {
                    Text(subtitle.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.36))
                        .lineLimit(1)
                        // Paths are read from the right — the folder matters
                        // more than the volume. Titles are read from the left.
                        .truncationMode(subtitle.isPath ? .head : .tail)
                }
            }

            Spacer(minLength: 6)
        }
        .padding(.horizontal, 10)
        .frame(height: NotchState.searchRowHeight - 2)
        // A neutral selection, 0.15 with a hairline (no accent colour).
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(selected ? IslandStyle.selectionFill : 0))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? IslandStyle.selectionStroke : 0),
                                  lineWidth: 1)))
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    /// The second line, and whether it's a path — which decides which end gets
    /// truncated.
    private var subtitle: (text: String, isPath: Bool)? {
        // Pip's description first: what the file is, in his words.
        if let about { return (about, false) }
        // The document's own title underneath, explaining the match.
        if let title = candidate.pdfTitle,
           title.caseInsensitiveCompare(candidate.displayName) != .orderedSame,
           title.caseInsensitiveCompare(candidate.url.deletingPathExtension().lastPathComponent)
               != .orderedSame {
            return (title, false)
        }
        if let from = candidate.whereFrom, let host = URL(string: from)?.host {
            return (host, false)
        }
        let parent = candidate.url.deletingLastPathComponent()
        guard parent != scope else { return nil }
        return (parent.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), true)
    }
}

