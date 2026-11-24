import AppKit
import SwiftUI

/// The Pip window. With an answer: small Pip and the question on one row
/// under the notch, the answer full-width below (an explanation as headline,
/// paragraph and points). Every size comes from `NotchState`.
struct PipView: View {

    @EnvironmentObject private var state: NotchState
    @ObservedObject var search: SearchController
    @ObservedObject var pet: Pet
    @ObservedObject var agent: PetAgent
    var onOpen: (URL) -> Void
    /// For the voice download's progress, and whether Pip is talking.
    @ObservedObject private var voice = PipVoice.shared
    /// Whether he's listening, and how loud you are.
    @ObservedObject private var ears = VoiceActivity.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The model has been asked to load for this opening (first keystroke).
    @State private var warmedForTyping = false
    /// The chips' shared glass (`GlassChipGroup`).
    @Namespace private var chipGlass
    /// Watches the pointer against the search bar's row on screen.

    /// A download in progress — the brain first, then the voice — shown in
    /// the search bar where the "Full search" hint usually sits.
    private var download: (label: String, fraction: Double)? {
        if let fraction = agent.brainProgress { return ("Brain", fraction) }
        if let fraction = voice.downloadProgress { return ("Voice", fraction) }
        return nil
    }

    // Spec tokens (sections 3 and 4).
    // macOS's own dark-mode label colours: primary, secondary (60%),
    // tertiary (30%) — the hierarchy every Apple app uses.
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.6)
    static let chipText = Color.white.opacity(0.85)
    static let thinkingGrey = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.45)
    static let accent = Color.white.opacity(0.92)

    var body: some View {
        VStack(alignment: .leading, spacing: NotchState.pipRowGap) {
            topRow
            extras
            if state.pipShowsChips {
                chips.transition(.opacity)
            }
            searchBar
        }
        .padding(.top, state.pipTopInset)
        .padding(.horizontal, NotchState.pipSideInset)
        .padding(.bottom, NotchState.pipBottomPadding)
        .frame(width: state.searchSize.width, height: state.searchSize.height, alignment: .top)
        // The window grows with the island's own height animation.
        .animation(reduceMotion ? nil : .islandHeight, value: state.searchSize.height)
        // Pip's window is always dark, whatever the Mac's appearance.
        .environment(\.colorScheme, .dark)
        .onAppear {
            warmedForTyping = false
            agent.startFresh()
            agent.prewarm()
            agent.refreshStatus()
            pet.refresh()
        }
        // Your question goes beside small Pip, above his answer
        // (`headerQuestion`), so the bar clears as he starts. (It stayed in
        // the bar, greyed, while he thought, until 2026-11-22.)
        .onChange(of: agent.isThinking) { _, _ in
            if !search.query.isEmpty { search.query = "" }
            search.stopLive()
        }
        // Typing: files show as you type (the panel's search), and the
        // model starts loading at the first key, even on battery — you're
        // about to ask him something. Not while he works on the last question.
        .onChange(of: search.query) { _, text in
            guard !agent.isThinking else { return }
            // Files only for name-like text, and only until he has answered
            // this time: after that, typing here is talking to him.
            if agent.latest == nil, SearchController.looksLikeName(text) {
                search.queryChanged()
            } else {
                search.stopLive()
            }
            if !text.isEmpty, !warmedForTyping {
                warmedForTyping = true
                agent.prewarm(force: true)
            }
        }

    }

    // MARK: - Your question

    /// The question in the row's right corner, one line, clear of small Pip.
    @ViewBuilder
    private var headerQuestion: some View {
        // Level with small Pip, whatever its length; at the 10 pt lift it
        // stays clear of the notch (owner, 2026-11-22; capping it to the room
        // beside the notch, then dropping a long one 5 pt, were tried first).
        if let question = agent.lastQuestion, !ears.isListening {
            // Bold and faint, no background (owner, 2026-11-22; a dark grey
            // pill was tried the same day).
            Text(question)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: state.pipOrb)
                // Clear of small Pip: his width and a gap the same size.
                .padding(.leading, state.pipOrb * 2)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - State

    /// Thinking, unless he's stopped to ask something — then the question
    /// is what the card says.
    private var showsThinking: Bool {
        guard agent.confirmation == nil else { return false }
        if agent.awaitingSpeech { return true }
        // Speaking: thinking until the first words are actually heard.
        if agent.voiceSynced { return agent.caption == nil }
        return agent.isThinking && agent.partial == nil
    }

    /// What the card says: a question, or what he has said so far, or the
    /// reply as it's written. Only ever his final words — reasoning is
    /// stripped before it gets here.
    private var shownText: String? {
        if let question = agent.confirmation?.question { return question }
        if agent.voiceSynced { return agent.caption.map { agent.captionAhead ?? $0 } }
        return agent.partial ?? agent.latest
    }

    /// While speaking, how much of `shownText` has been said; the rest is
    /// laid out but not yet visible.
    private var spokenText: String? {
        guard agent.confirmation == nil, agent.voiceSynced else { return nil }
        return agent.caption
    }

    /// Text is showing: Pip shrinks into the top-left corner and the text
    /// gets the row. Before that, it's just big Pip.
    private var textMode: Bool {
        // Thinking: big Pip with the aurora inside him and "Thinking…" (or
        // what he's doing) under him (2026-11-21).
        if showsThinking { return true }
        guard let text = shownText else { return false }
        return !text.isEmpty
    }

    /// Pip's middle in screen coordinates, so he can look at the cursor.
    private var pipCenter: CGPoint {
        let screen = state.metrics.screenFrame
        let top = NotchGeometry.verticalOffset + state.pipTopInset
        let left = screen.midX - state.pipWindowWidth / 2 + NotchState.pipSideInset
        if state.pipCompact {
            return CGPoint(x: left + NotchState.pipOrbCentreX,
                           y: screen.maxY - top - state.pipOrbTop - state.pipOrb / 2)
        }
        return CGPoint(x: screen.midX, y: screen.maxY - top - NotchState.pipArtHeight / 2)
    }

    /// Spec section 5: a small smile when greeting or replying, the dot mouth
    /// and glancing eyes while thinking — plus listening and talking faces.
    private var expression: PipArt.Expression {
        if ears.isListening { return .listening }
        if showsThinking { return .thinking }
        if voice.isSpeaking { return .talking }
        return .replying
    }

    // MARK: - Top row

    /// One Pip, drawn big and scaled: centred on his own, or shrunk into the
    /// top-left corner with your question beside him and his answer below. The spring moves and
    /// shrinks him in one motion while the text fades in.
    private var topRow: some View {
        let big = NotchState.pipArtWidth
        let rowWidth = state.pipWindowWidth - NotchState.pipSideInset * 2
        // Small in the corner (44) while he listens, thinks or answers,
        // its middle on the first text line's. Big and centred otherwise.
        let compact = state.pipCompact
        let orb = state.pipOrb
        return ZStack(alignment: .topLeading) {
            VoicePulse(active: ears.isListening) {
                PipArt(expression: expression, width: big, level: ears.level, screenCenter: pipCenter,
                       interactive: !compact)
            }
            .frame(width: big, height: NotchState.pipArtHeight)
            .scaleEffect(compact ? orb / big : 1, anchor: .topLeading)
            .offset(x: compact ? NotchState.pipOrbCentreX - orb / 2 : (rowWidth - big) / 2,
                    y: compact ? state.pipOrbTop : 0)

            if showsThinking {
                // Thinking: big Pip, the waves inside him; the line under him.
                ThinkingText(label: agent.activity)
                    .fixedSize()
                    .frame(height: NotchState.pipReplyLineHeight)
                    .frame(width: rowWidth, alignment: .center)
                    .padding(.top, NotchState.pipArtHeight + NotchState.pipRowGap)
                    .transition(.opacity)
            } else if state.pipVoiceLayout, textMode, let words = shownText {
                // Listening: big Pip; your words below him, centred.
                replyCard(words, width: state.pipWindowWidth - NotchState.pipSideInset * 2)
                    .frame(width: rowWidth, alignment: .center)
                    .padding(.top, NotchState.pipArtHeight + NotchState.pipRowGap)
                    .transition(.opacity)
            } else if textMode, agent.confirmation == nil, state.pipExplanationHeight > 0,
                      let live = PipExplanation.live(written: agent.partial ?? agent.latest,
                                                     // The words said so far; the window
                                                     // is sized for the whole sentence
                                                     // (AppDelegate), so it doesn't grow per word.
                                                     spoken: agent.caption,
                                                     synced: agent.voiceSynced, streaming: agent.partial != nil,
                                                     expected: PipExplanation.expects(agent.lastQuestion)) {
                explanationView(live.explanation)
                    .padding(.top, state.pipTextTop)
                    .transition(.opacity)
            } else if textMode, let reply = shownText {
                replyCard(reply)
                    .padding(.top, state.pipTextTop)
                    .transition(.opacity)
            }
            // Small Pip, your question beside him; the answer under both.
            if compact { headerQuestion }
        }
        .frame(width: rowWidth, height: state.pipTopRowHeight, alignment: .topLeading)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: compact)
        // Listening ↔ typing/answering: 38 ↔ 30 in 0.2 s; instantly with
        // Reduce Motion.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: orb)
    }

    /// The reply: hugs its text up to the row's width, about four lines,
    /// then scrolls inside the card.
    private func replyCard(_ reply: String, width: CGFloat? = nil) -> some View {
        let width = width ?? state.pipAnswerWidth
        let lines = max(1, state.pipReplyLines)
        let textHeight = CGFloat(lines) * NotchState.pipReplyLineHeight
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    revealed(reply)
                        .font(.system(size: 15, weight: .regular))
                        .lineSpacing(PipReply.lineSpacing)
                        .foregroundStyle(Self.primaryText)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        // Each word fades in where it already sits.
                        .contentTransition(.interpolate)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: spokenText)
                    Color.clear.frame(height: 0).id("end")
                }
            }
            // Long answers keep the newest line in view as they grow.
            .onChange(of: reply) { _, _ in
                if agent.isThinking || voice.isSpeaking { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(maxWidth: min(width, PipReply.width(reply, within: width)), alignment: .leading)
        .frame(height: textHeight, alignment: .topLeading)
        .card()
    }

    /// The whole sentence laid out, the unspoken part transparent, so it fills
    /// in without reflowing (owner's request; overrides the no-word-fade rule).
    private func revealed(_ raw: String) -> Text {
        // Never raw markdown: no "**", points as "• " (`PipExplanation.plain`).
        let reply = PipExplanation.plain(raw)
        guard let spoken = spokenText.map(PipExplanation.plain), spoken.count < reply.count else { return Text(reply) }
        // Not a prefix (spacing differs): never show words before they're said.
        guard reply.hasPrefix(spoken) else { return Text(spoken) }
        return Text(spoken) + Text(String(reply.dropFirst(spoken.count))).foregroundColor(.clear)
    }

    // MARK: - Explanation

    /// Headline, paragraph, numbered points; scrolls past
    /// `NotchState.pipExplanationHeight`, bottom faded.
    private func explanationView(_ explanation: PipExplanation) -> some View {
        let width = min(state.pipAnswerWidth, PipExplanation.maxWidth)
        let height = state.pipExplanationHeight
        let scrolls = explanation.height(width: width) > height + 1
        return ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ExplanationLayout(explanation: explanation)
                Color.clear.frame(height: 0).id("explanationEnd")
            }
            .frame(width: width, alignment: .leading)
            .textSelection(.enabled)
        }
        // Written live: past the window's height, the newest line stays in view.
        .onChange(of: explanation) { _, _ in
            if agent.partial != nil || agent.voiceSynced, scrolls { proxy.scrollTo("explanationEnd", anchor: .bottom) }
        }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .mask {
            if scrolls {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: max(0, 1 - 28 / max(height, 1))),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Color.black
            }
        }
    }

    /// Under an explanation: where it came from, then Copy · Shorter · More
    /// detail.
    private var answerActions: some View {
        HStack(spacing: 6) {
            if let source = agent.replySource { SourceChip(source: source) }
            AnswerChip(title: "Copy", done: "Copied") {
                guard let reply = agent.latest else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(PipExplanation.plain(reply), forType: .string)
                ActivityLog.write(.system, "pip: copied the answer")
            }
            AnswerChip(title: "Shorter") { agent.send("Shorter, please.") }
            AnswerChip(title: "More detail") { agent.send("More detail, please.") }
            Spacer(minLength: 0)
        }
        .frame(height: NotchState.pipAnswerActionsHeight)
    }

    // MARK: - Extras (beyond the spec: files, Allow/Cancel)

    @ViewBuilder
    private var extras: some View {
        if state.pipShowsAnswerActions, !showsThinking {
            answerActions.transition(.opacity)
        }
        let live = SearchController.pipRows(results: search.results, query: search.query,
                                            answered: agent.latest != nil)
        if !showsThinking, !live.isEmpty {
            // What you're typing, as apps and files — until you send it to Pip.
            VStack(spacing: 0) {
                ForEach(live.prefix(NotchState.pipMaxResults), id: \.self) { url in
                    ResultRow(url: url, onOpen: onOpen)
                }
                if live.count > NotchState.pipMaxResults {
                    ShowAllRow(count: live.count) { search.showAll(for: search.query) }
                }
            }
        } else if !showsThinking, !agent.found.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(agent.found.prefix(NotchState.pipMaxResults).enumerated()), id: \.element) { index, url in
                    if let group = agent.foundHeaders[index],
                       agent.foundHeaders.keys.filter({ $0 <= index }).count <= NotchState.pipMaxGroupHeaders {
                        GroupHeader(name: group)
                    }
                    ResultRow(url: url, onOpen: onOpen)
                }
                if agent.found.count > NotchState.pipMaxResults {
                    ShowAllRow(count: agent.found.count, inFinder: agent.foundQuery == nil) {
                        // The search that found these — or, for a list that
                        // didn't come from a search, the files themselves.
                        if let query = agent.foundQuery {
                            search.showAll(for: query)
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting(agent.found)
                        }
                    }
                }
            }
        }
        if agent.noteOffer != nil, !showsThinking {
            GlassChipGroup {
                HStack(spacing: 8) {
                    choice("Save to Notes", prominent: true) { agent.saveOfferedNote() }
                    choice("No thanks", prominent: false) { agent.dismissNoteOffer() }
                }
            }
            .frame(height: NotchState.pipConfirmHeight)
            .padding(.leading, NotchState.pipRowInset)
            .transition(.opacity)
        }
        if !showsThinking, !agent.pictures.isEmpty {
            let rowWidth = state.pipWindowWidth - NotchState.pipSideInset * 2
            PictureRow(pictures: agent.pictures, width: rowWidth)
                .frame(height: NotchState.pipPicturesHeight(rows: state.pipPictureRows, width: rowWidth))
                .transition(.opacity)
        }
        if agent.confirmation != nil {
            GlassChipGroup {
                HStack(spacing: 8) {
                    choice("Allow", prominent: true) { agent.answer(true) }
                    choice("Cancel", prominent: false) { agent.answer(false) }
                }
            }
            .frame(height: NotchState.pipConfirmHeight)
            .padding(.leading, NotchState.pipRowInset)
        }
    }

    private func choice(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.black : Self.chipText)
            .padding(.horizontal, 14)
            .frame(height: NotchState.pipConfirmHeight)
            .glassChip(id: title, in: chipGlass, prominent: prominent) {
                Capsule().fill(prominent ? Self.primaryText : Color.white.opacity(0.10))
            }
            .overlay(ClickableArea(onClick: action, onHover: { _ in }))
    }

    // MARK: - Chips (greeting only)

    private var chips: some View {
        GlassChipGroup {
            HStack(spacing: 8) {
                SuggestionChip(symbol: "macwindow", title: "What's on my screen?", glass: chipGlass) {
                    agent.send("What's on my screen?")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: NotchState.pipChipsHeight)
    }

    // MARK: - Search bar (spec section 3)

    private var searchBar: some View {
        HStack(spacing: 10) {
            if ears.isListening {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Self.accent)
                    .frame(width: 18, height: 18)
            } else {
                // Thin and faint; centred under Pip, text aligned with his words.
                Image(systemName: "magnifyingglass")
                    .font(.system(size: barExpanded ? 14 : 11, weight: .regular))
                    .foregroundStyle(barExpanded ? Self.secondaryText : Self.thinkingGrey)
                    .frame(width: barExpanded ? 18 : 12, height: 18)
                    .padding(.trailing, 11)
            }

            SearchField(text: Binding(get: { search.query }, set: { search.query = $0 }),
                        focusToken: search.focusToken,
                        placeholder: ears.isListening ? "Listening…"
                            : barExpanded ? "Ask \(pet.name), or type a file name" : "Ask \(pet.name)",
                        onSubmit: {},
                        onCancel: { search.close() },
                        // Listening: no caret (your words are beside Pip).
                        style: .pip(thinking: showsThinking || ears.isListening, compact: !barExpanded))
                .frame(height: 22)

            // Listening needs nothing on the right: the mic, "Listening…" and
            // the colours moving with your voice already say it.
            if ears.isListening {
                EmptyView()
            } else if agent.isThinking {
                stopButton
            } else if let download {
                DownloadBadge(label: download.label, fraction: download.fraction)
            }
        }
        // Plus the 16 pt the bar reaches past the margins, so the icon stays
        // under Pip and the text under his words.
        .padding(.leading, (barExpanded ? 13 : 11) + NotchState.pipSideInset - NotchState.pipBarInset)
        .padding(.trailing, (barExpanded ? 14 : 11) + NotchState.pipSideInset - NotchState.pipBarInset)
        .frame(height: barHeight)
        .frame(width: barExpanded ? nil : Self.collapsedBarWidth)
        .frame(maxWidth: barExpanded ? .infinity : Self.collapsedBarWidth)
        // A flat, quiet capsule with a hairline edge, a little darker than
        // the glass around it (Liquid Glass here was tried and reverted).
        .background(Self.barShape.fill(Color.black.opacity(0.22)))
        .overlay(Self.barShape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        .clipShape(Self.barShape)
        // (A Siri-style coloured ring round the bar, glowing while he listened
        // or thought, was removed at the owner's request, 2026-11-12.)
        .frame(maxWidth: .infinity)
        // Edge to edge: out past the side margins to the bar's own inset.
        .padding(.horizontal, NotchState.pipBarInset - NotchState.pipSideInset)
        .frame(height: NotchState.pipSearchHeight)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.8), value: barExpanded)
    }

    /// A small "Ask Pip" pill until it's needed, then the full bar.
    private static let collapsedBarWidth: CGFloat = 100
    private static let barShape = Capsule(style: .continuous)
    private var barHeight: CGFloat { barExpanded ? NotchState.pipSearchHeight : 28 }

    /// Always the full bar (owner, 2026-11-12). It was a small "Ask Pip"
    /// pill until pointed at, typed or talked into.
    private var barExpanded: Bool { true }

    /// Thinking only: a 36 circle with a small square, 6 from the bar's
    /// edge. Cancels the request.
    /// Small and quiet: a 26 circle (36, brighter, took over the bar).
    private var stopButton: some View {
        Circle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 26, height: 26)
            .overlay(Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Self.secondaryText))
            .padding(.trailing, -6)
            .overlay(ClickableArea(onClick: {
                agent.stopEverything()
                PipVoice.shared.stop()
            }, onHover: { _ in }))
            .accessibilityLabel("Stop")
    }
}

/// What Pip says sits as plain text beside him, the way Siri and Live
/// Activities set text next to an icon — no bubble, no border.
private struct PipCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.top, NotchState.pipCardPadTop)
            .padding(.bottom, NotchState.pipCardPadBottom)
            .padding(.horizontal, NotchState.pipCardPadSide)
    }
}

private extension View {
    func card() -> some View { modifier(PipCardStyle()) }
}

/// One file Pip found: its icon, name and folder, and a click to open it.
/// A small folder button at the end shows it in Finder instead.
private struct ResultRow: View {

    let url: URL
    var onOpen: (URL) -> Void

    @ObservedObject private var notes = FileNoteCache.shared
    @State private var hovering = false
    @State private var folderHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PipView.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // What it is: Pip's description, or the document's own title.
                if let line = notes.line(for: url) {
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(PipView.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Text(url.deletingLastPathComponent().path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11))
                .foregroundStyle(PipView.secondaryText.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 140, alignment: .trailing)
            // Room for the folder button, which sits on top (below).
            Color.clear.frame(width: 18)
        }
        .padding(.horizontal, 10)
        .frame(height: NotchState.pipResultHeight - 3)
        // Cards: faintly visible always, brighter on hover.
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.13 : 0.05)))
        .frame(height: NotchState.pipResultHeight)
        .overlay(ClickableArea(onClick: { onOpen(url) }, onHover: { hovering = $0 }))
        // After the row's area, so it's on top and takes its own clicks.
        .overlay(alignment: .trailing) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PipView.secondaryText.opacity(folderHovering ? 1 : 0.6))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(folderHovering ? 0.12 : 0)))
                .padding(.trailing, 4)
                .overlay(ClickableArea(onClick: {
                    ActivityLog.write(.system, "pip: show in folder — \(url.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }, onHover: { folderHovering = $0 }))
                .help("Show in Folder")
                .accessibilityLabel("Show in Folder")
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: folderHovering)
        .onAppear { notes.want([url]) }
    }
}

/// A group's name above its files in Pip's window (`ResultGroups`).
private struct GroupHeader: View {
    let name: String

    var body: some View {
        Text(name.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(1)
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, minHeight: NotchState.pipGroupHeaderHeight,
                   maxHeight: NotchState.pipGroupHeaderHeight, alignment: .bottomLeading)
    }
}

/// Pictures from the web under his answer, five a row, up to two rows
/// (`WebAccess.pictures`). Click one for the page it came from; the
/// button in its corner (on hover) saves it to Downloads, full size.
private struct PictureRow: View {

    let pictures: [WebAccess.Picture]
    /// The row's width; five pictures span it.
    let width: CGFloat
    @State private var hovered: URL?
    /// The pointer is over that picture's download button.
    @State private var buttonHovered: URL?
    /// The last press landed on the button (read when the click fires).
    @State private var pressedButton = false
    @State private var saving: Set<URL> = []
    /// Saved, and where to.
    @State private var saved: [URL: URL] = [:]

    private var side: CGFloat { NotchState.pipPictureSide(width: width) }
    /// The button's corner of a picture: its top-right 32 pt.
    private static let buttonZone: CGFloat = 32

    private func inButton(_ point: CGPoint) -> Bool {
        point.x >= side - Self.buttonZone && point.y <= Self.buttonZone
    }

    /// Drawn only: the picture's one clickable area tells the two presses apart.
    private func downloadButton(_ picture: WebAccess.Picture) -> some View {
        let done = saved[picture.page]
        let shown = hovered == picture.page || saving.contains(picture.page) || done != nil
        return Image(systemName: done != nil ? "checkmark" : saving.contains(picture.page) ? "ellipsis" : "arrow.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.black.opacity(buttonHovered == picture.page ? 0.85 : 0.6)))
            .padding(5)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// Saves it to Downloads, full size; once saved, shows it in Finder.
    private func download(_ picture: WebAccess.Picture) {
        if let done = saved[picture.page] {
            NSWorkspace.shared.activateFileViewerSelecting([done])
            return
        }
        guard !saving.contains(picture.page) else { return }
        saving.insert(picture.page)
        Task { @MainActor in
            let file = await WebAccess.save(picture)
            saving.remove(picture.page)
            if let file { saved[picture.page] = file }
            ActivityLog.write(.system, "pip: saved picture — "
                              + (file.map { $0.lastPathComponent } ?? "failed (\(picture.page.host ?? ""))"))
        }
    }

    /// Decoded once per picture: the window re-renders per token.
    @MainActor private static var images: [URL: NSImage] = [:]

    private static func image(_ picture: WebAccess.Picture) -> NSImage? {
        if let cached = images[picture.page] { return cached }
        let decoded = NSImage(data: picture.thumbnail)
        if images.count > 40 { images.removeAll() }
        images[picture.page] = decoded
        return decoded
    }

    var body: some View {
        let shown = Array(pictures.prefix(NotchState.pipPicturesPerRow * NotchState.pipMaxPictureRows))
        let perRow = NotchState.pipPicturesPerRow
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stride(from: 0, to: shown.count, by: perRow)), id: \.self) { start in
                HStack(spacing: 8) {
                    ForEach(shown[start..<min(start + perRow, shown.count)], id: \.page) { picture in
                        tile(picture)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func tile(_ picture: WebAccess.Picture) -> some View {
        Group {
            if let image = Self.image(picture) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.06)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(hovered == picture.page ? 0.35 : 0.10), lineWidth: 1))
        .brightness(hovered == picture.page ? 0.04 : 0)
        .overlay(alignment: .topTrailing) { downloadButton(picture) }
        // One area for the picture and its button: where the press
        // landed decides which.
        .overlay(ClickableArea(onClick: {
            if pressedButton {
                download(picture)
            } else {
                ActivityLog.write(.system, "pip: opened picture's page — \(picture.page.host ?? "")")
                NSWorkspace.shared.open(picture.page)
            }
        }, onHover: { inside in
            if inside { hovered = picture.page } else if hovered == picture.page { hovered = nil }
        }, onPress: { point in
            pressedButton = inButton(point)
        }, onPointer: { point in
            let over = point.map(inButton) ?? false
            if over { if buttonHovered != picture.page { buttonHovered = picture.page } }
            else if buttonHovered == picture.page { buttonHovered = nil }
        }))
        .help(picture.title)
    }
}

/// Where an explanation came from: a file (click to open), a page (click
/// to open), or just "From the web". Built from the tools that ran.
private struct SourceChip: View {

    let source: PetAgent.ReplySource
    @State private var hovering = false

    private var link: URL? {
        switch source {
        case .file(let url), .site(let url): return url
        case .web: return nil
        }
    }

    private static let textWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 5) {
            switch source {
            case .file(let url):
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 14, height: 14)
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: Self.textWidth, alignment: .leading)
            case .site(let url):
                Image(systemName: "globe").font(.system(size: 10.5))
                Text(url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "the web").lineLimit(1)
                    .frame(maxWidth: Self.textWidth, alignment: .leading)
            case .web:
                Image(systemName: "globe").font(.system(size: 10.5))
                Text("From the web")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(hovering && link != nil ? 0.8 : 0.6))
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .frame(height: NotchState.pipAnswerActionsHeight)
        // As wide as its text: a max width on the chip stretched "From the
        // web" across 190 pt. Long names are capped and cut instead.
        .fixedSize()
        .background(Capsule().fill(Color.white.opacity(hovering && link != nil ? 0.11 : 0.07)))
        .overlay(ClickableArea(onClick: {
            guard let link else { return }
            ActivityLog.write(.system, "pip: opened the answer's source — \(link.isFileURL ? link.lastPathComponent : link.host ?? "")")
            NSWorkspace.shared.open(link)
        }, onHover: { hovering = $0 }))
    }
}

/// A quiet follow-up under an explanation: Copy, Shorter, More detail.
private struct AnswerChip: View {

    let title: String
    /// Said for a moment after it's clicked ("Copied").
    var done: String? = nil
    let action: () -> Void
    @State private var hovering = false
    @State private var showsDone = false

    var body: some View {
        Text(showsDone ? (done ?? title) : title)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.55))
            .padding(.horizontal, 9)
            .frame(height: NotchState.pipAnswerActionsHeight)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.11 : 0.06)))
            .fixedSize()
            .overlay(ClickableArea(onClick: {
                action()
                guard done != nil else { return }
                showsDone = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showsDone = false }
            }, onHover: { hovering = $0 }))
    }
}

/// "Show all 12 in Search": the rest of what Pip found, in the full panel.
/// Same height and card as a result row, quieter text.
private struct ShowAllRow: View {

    let count: Int
    var inFinder = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Show all \(count) in \(inFinder ? "Finder" : "Search")")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PipView.secondaryText)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PipView.secondaryText.opacity(0.8))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: NotchState.pipResultHeight - 3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.10 : 0.0)))
        .frame(height: NotchState.pipResultHeight)
        .overlay(ClickableArea(onClick: action, onHover: { hovering = $0 }))
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Measures a reply the way the view will set it, so the window can be the
/// right height before the text is drawn.
@MainActor
enum PipReply {

    private static let font: NSFont = {
        NSFont.systemFont(ofSize: 15, weight: .regular)
    }()

    /// Measured once; making a layout manager per call adds up per token.
    private static let lineHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: font)

    private static func bounds(_ text: String, width: CGFloat? = nil) -> NSRect {
        // Measured as shown: markdown taken out (`PipExplanation.plain`).
        NSAttributedString(string: PipExplanation.plain(text), attributes: [.font: font])
            .boundingRect(with: NSSize(width: width ?? NotchState.pipTextWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// Lines in the card (1 up to about 4; more scrolls), at `width`.
    static func lines(_ text: String, width: CGFloat? = nil) -> Int {
        let count = Int((bounds(text, width: width).height / max(lineHeight, 1)).rounded(.up))
        return min(max(count, 1), NotchState.pipReplyMaxLines)
    }

    /// The text's own width, so a short reply gets a short card.
    static func width(_ text: String, within width: CGFloat? = nil) -> CGFloat {
        ceil(bounds(text, width: width).width) + 2
    }

    /// The spec's 21-point line height, as SwiftUI line spacing.
    static var lineSpacing: CGFloat {
        max(0, 21 - lineHeight)
    }
}

/// A small progress bar and percentage: "Brain ▬▬▭ 42%".
private struct DownloadBadge: View {
    let label: String
    let fraction: Double

    private let barWidth: CGFloat = 44

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule().fill(PipView.accent)
                    .frame(width: max(5, barWidth * clamped))
            }
            .frame(width: barWidth, height: 5)
            .animation(.easeOut(duration: 0.3), value: clamped)

            Text("\(label) \(Int(clamped * 100))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(PipView.secondaryText)
        }
        .fixedSize()
        .help("Downloading \(label.lowercased()): \(Int(clamped * 100))%")
    }
}

/// A suggestion, Spotlight-style: a small symbol and a few words on a faint
/// fill, no border. A real button.
private struct SuggestionChip: View {
    let symbol: String
    let title: String
    let glass: Namespace.ID
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PipView.secondaryText.opacity(0.8))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PipView.chipText)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: NotchState.pipChipsHeight)
        .glassChip(id: title, in: glass, hovering: hovering) {
            Capsule().fill(Color.white.opacity(hovering ? 0.11 : 0.06))
        }
        .fixedSize()
        .overlay(ClickableArea(onClick: action, onHover: { hovering = $0 }))
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: hovering)
    }
}
