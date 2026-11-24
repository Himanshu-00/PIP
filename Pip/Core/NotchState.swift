import SwiftUI
import Combine

/// The island has three resting shapes, mirroring the iPhone.
enum NotchPresentation: Equatable {
    /// Nothing to show — exactly the hardware notch, invisible.
    case collapsed
    /// Media is present: the island widens slightly and shows a leading thumbnail.
    case compact
    /// A transient blip — charging, low battery — outranks media while it shows.
    case event
    /// Pointer is on the island: the player, or the shelf and search.
    case expanded
    /// Searching files. Outranks everything else.
    case search
}

/// What the expanded island shows, when the pointer has an opinion.
enum ExpandedPreference: Equatable {
    /// Follow what's playing.
    case automatic
    /// The player, because the pointer asked for it.
    case player
    /// The shelf and search, because the pointer asked for them.
    case tools
}

/// Shared, observable geometry + interaction state for the island.
@MainActor
final class NotchState: ObservableObject {

    @Published private(set) var metrics = NotchMetrics(notchSize: NotchGeometry.simulatedNotch,
                                                       screenFrame: .zero,
                                                       hasHardwareNotch: false)
    @Published var isExpanded = false {
        // Hovering again starts fresh. A manual switch is about this glance at
        // the island, not a setting — remembering it would mean the panel
        // silently opens on whatever you last poked, minutes later, with no
        // way to tell why.
        didSet { if !isExpanded { expandedPreference = .automatic } }
    }
    /// Something is playing *now*. Decides `.collapsed` vs `.compact`, and
    /// which half of the expanded panel opens by default.
    @Published var hasMedia = false
    /// A track exists at all — paused, a video, anything with a title.
    ///
    /// Separate from `hasMedia` because the two answer different questions.
    /// Paused music shouldn't hold the island open or claim the hover panel,
    /// but it is absolutely still worth *offering* a way back to the player.
    @Published var hasTrack = false
    /// Which half of the expanded panel to show, if the pointer has asked.
    @Published var expandedPreference: ExpandedPreference = .automatic

    /// Is the expanded panel the player, or the shelf and search?
    ///
    /// One predicate, deliberately. The size and the content used to decide
    /// this separately — `expandedSize` asked `hasMedia` while the view asked
    /// whether `engine.now` was valid — so a paused track, or a video, sized
    /// the panel for the shelf and then drew the player into it.
    var showsPlayer: Bool {
        switch expandedPreference {
        case .player:    return hasTrack
        case .tools:     return false
        case .automatic: return hasMedia
        }
    }
    /// Set by `flash(_:)`; clears itself.
    @Published private(set) var event: NotchEvent?
    /// Driven by SearchController — outranks hover, and takes the keyboard.
    @Published var isSearching = false
    /// True while the display is asleep or the session is switched away.
    ///
    /// Nothing in the island is worth drawing then, and an animation that keeps
    /// ticking behind a dark screen is the purest possible waste — it prevents
    /// the CPU reaching its deeper idle states for frames nobody sees.
    @Published var isSuspended = false
    /// Mic / Focus, for as long as each is true.
    @Published var indicators: [NotchIndicator] = []
    /// A running timer's end (see `NotchTimer`).
    @Published var timerEnd: Date?
    /// A paused timer's time left.
    @Published var timerPausedLeft: TimeInterval?
    var timerActive: Bool { timerEnd != nil || timerPausedLeft != nil }
    /// One line of context at the bottom of the expanded island.
    @Published var utility: NotchUtility?
    /// Something is running full screen on this display.
    @Published var isFullScreen = false
    /// How many search results are on screen, so the panel can be the size of
    /// its contents rather than the size of the most it could ever hold.
    @Published var searchRows = 0
    /// Whether the "weaker matches" row is showing under them.
    @Published var searchHasMore = false
    /// The search panel is open as Pip rather than the full file search.
    @Published var searchIsPet = false
    /// How many files Pip is showing in his bubble.
    @Published var pipResults = 0
    /// Group names shown among them.
    @Published var pipResultHeaders = 0
    /// Rows of web pictures Pip is showing (five a row; 0 = none).
    @Published var pipPictureRows = 0
    /// Pip is waiting for an Allow or Cancel.
    @Published var pipConfirming = false
    /// A summary can be saved to Notes: the "Save to Notes" button row.
    @Published var pipNoteOffer = false
    /// There are earlier messages to scroll back through.
    @Published var pipHasHistory = false
    /// Pip is working on something (thinking or still writing).
    @Published var pipBusy = false
    /// Files are parked on the drop shelf: its row shows in the hover panel.
    @Published var hasDropShelf = false
    /// A file drag is over the open panel: it shows "Drop to keep here".
    @Published var isDropTargeting = false

    private var eventTask: Task<Void, Never>?

    /// Called when a click lands in the panel but outside the search island.
    /// The window has to be large enough to hold the search panel, so it
    /// covers dead space either side of it; clicking there should dismiss
    /// rather than silently swallow the click.
    var onDismissSearch: (() -> Void)?
    /// Set by AppDelegate. The hover panel's search field is a button, and
    /// this is what it presses — the island has no business knowing how a
    /// search is started, only that asking for one is possible.
    var onOpenSearch: (() -> Void)?

    /// Called when the pointer has been off an open panel for a while.
    var onPointerIdle: (() -> Void)?

    var presentation: NotchPresentation {
        if isSearching { return .search }
        return isExpanded ? .expanded : restingPresentation
    }

    /// What the island falls back to when the pointer leaves.
    ///
    /// Indicators keep it in `.compact` even with nothing playing: a mic that
    /// is live is worth a permanent sliver of screen, which is the entire
    /// argument for the orange dot macOS already shows.
    var restingPresentation: NotchPresentation {
        // Full screen means get out of the way.
        //
        // The island draws above the menu bar layer, which is what lets it sit
        // on the hardware notch — and also what puts it on top of a film. It
        // collapses to exactly the notch, which is invisible, and stays
        // hoverable: that's how the menu bar behaves in full screen too, and
        // matching it means the island is still *there* without being in the
        // way.
        if isFullScreen { return .collapsed }
        if event != nil { return .event }
        if hasMedia || !indicators.isEmpty || timerActive { return .compact }
        return .collapsed
    }

    /// Show a transient event, then return to whatever was there before.
    /// Takes a flash down early, if it's still the one showing.
    func clearFlash(_ event: NotchEvent) {
        guard self.event == event else { return }
        eventTask?.cancel()
        self.event = nil
    }

    func flash(_ event: NotchEvent) {
        eventTask?.cancel()
        self.event = event
        eventTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(event.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.event = nil
        }
    }

    // MARK: - Sizes

    /// Collapsed island == exactly the hardware notch, so it disappears into the bezel.
    var collapsedSize: CGSize { metrics.notchSize }

    /// Compact grows symmetrically, giving a strip either side of the camera —
    /// then a little more on the right for each extra indicator, so three
    /// glyphs don't get squeezed into the space meant for one.
    /// The right strip's width: the waveform (22), or the indicators, plus
    /// room for a timer's countdown.
    var compactTrailingWidth: CGFloat {
        let glyphs: CGFloat = indicators.isEmpty ? (timerActive ? 0 : 22) : CGFloat(indicators.count) * 15 + 7
        // Wider for "1:05:00" than for "4:59".
        let long = (timerEnd.map { $0.timeIntervalSinceNow >= 3540 } ?? false) || (timerPausedLeft ?? 0) >= 3540
        return glyphs + (timerActive ? (long ? 54 : 40) : 0)
    }

    var compactSize: CGSize {
        let extra = max(compactTrailingWidth - 22, 0)
        return CGSize(width: metrics.notchSize.width + NotchGeometry.compactInset * 2 + extra,
                      height: metrics.notchSize.height)
    }

    /// Two shapes, depending on what hovering is for.
    ///
    /// With something playing, this is the player and keeps the width it has
    /// always had — a wider island reads as a different shape rather than a
    /// roomier one. With nothing playing it holds the shelf and a search
    /// field, and a row of screenshot thumbnails simply needs more room than
    /// a track title does.
    var expandedSize: CGSize {
        // Annotated, not inferred. `self.utility == nil ? 0 : 42` is a pair of
        // integer literals, so Swift types it Int, and Int + CGFloat is not a
        // thing — the old version put the literal inline where the surrounding
        // CGFloat arithmetic forced it.
        let utility: CGFloat = self.utility == nil ? 0 : 42
        let dropShelf: CGFloat = hasDropShelf ? Self.dropShelfRowHeight : 0
        return showsPlayer
            ? CGSize(width: Self.playerWidth(for: metrics),
                     height: metrics.notchSize.height + 148 + utility)
            : CGSize(width: Self.shelfWidth(for: metrics),
                     // clearance 10, bar 38, gap 14, heading 16, gap 10,
                     // shelf 60, bottom padding 15 — and 7 points of slack, so
                     // the last row of thumbnails isn't sitting on the floor.
                     // The previous figure costed the heading row at 16 and
                     // forgot it contains 34-point buttons.
                     height: metrics.notchSize.height + 170 + dropShelf + utility)
    }

    /// The drop shelf's section under the screenshots: gap 14, heading 16,
    /// gap 10, row 60.
    static let dropShelfRowHeight: CGFloat = 100

    static func playerWidth(for metrics: NotchMetrics) -> CGFloat {
        max(metrics.notchSize.width + 190, 400)
    }

    /// Deliberately identical to the search panel's width.
    ///
    /// Opening search used to move the panel in two directions at once — 600
    /// out to 780 sideways while it also grew downwards — and the bar inside
    /// it was morphing against that moving frame. Three motions to say one
    /// thing.
    ///
    /// Sharing the width leaves exactly one: height. The box stays put, the
    /// bar stretches across a frame that isn't moving, and the results arrive
    /// underneath. It is also better for the shelf on its own terms — 740
    /// points of content is seven thumbnails instead of five.
    ///
    /// Height can't be shared the same way. The search panel grows with the
    /// number of results, and pinning the shelf to that would leave it holding
    /// two hundred points of nothing.
    static func shelfWidth(for metrics: NotchMetrics) -> CGFloat {
        searchPanelWidth(for: metrics)
    }

    /// Tall, because a list of eight results is the point.
    /// The height of one result row, including its spacing.
    static let searchRowHeight: CGFloat = 48
    /// Field, padding and the space above the first row.
    static let searchChrome: CGFloat = 80
    /// The most rows shown before the list starts scrolling.
    ///
    /// Larger than the shortlist of five on purpose: revealing the weaker
    /// matches can put thirty rows in there, and a panel that stays sized for
    /// five while holding thirty is how the scrolling went missing in the
    /// first place.
    static let searchVisibleRows = 8

    /// Width of the results column. The detail pane takes what's left.
    ///
    /// Roughly 60/40 in the list's favour.
    ///
    /// 390 against the panel's 700: the list keeps the larger share because
    /// filenames are what truncates, but not so much that the card beside it
    /// can't hold a label and a value on one line.
    ///
    /// It started at 340 against a ~485 pane, which had it backwards: three
    /// short facts and a button held more width than a column of filenames.
    /// Evening it up wasn't enough — the pane's content doesn't grow to fill
    /// whatever it's given, it just centres itself in more emptiness. So the
    /// list takes the larger share outright and the pane gets what three lines
    /// of text actually need.
    static let searchListWidth: CGFloat = 390
    /// The key-hint strip along the bottom.
    static let searchFooterHeight: CGFloat = 36
    /// A floor on the content area once there's a detail pane to fill.
    ///
    /// Without it the panel keeps sizing itself to the number of rows, which
    /// was right when rows were all there was — two results meant a short
    /// panel. Now two results still have to sit beside an icon, four lines of
    /// metadata and two buttons, and a 190-point-tall box cannot hold that.
    /// The list scrolls; the detail pane can't.
    static let searchPaneMinimum: CGFloat = 250
    // MARK: Pip

    /// Pip's window sizes. `PipView` lays out with these and `pipSize` adds up
    /// the same ones, so the window and its contents agree. History:
    /// Docs/history/Core.md.
    static let pipWidth: CGFloat = 460
    /// Each side's margin.
    static let pipSideInset: CGFloat = 24
    /// The search bar's gap to the window's sides and bottom: 36 − 20, so the
    /// capsule's round ends are concentric with the window's corners.
    static let pipBarInset: CGFloat = pipBottomRadius - pipSearchHeight / 2
    static let pipBottomPadding: CGFloat = pipBarInset
    /// Between rows (top row, extras, chips, search bar).
    static let pipRowGap: CGFloat = 14
    /// The top row's own left/right padding.
    static let pipRowInset: CGFloat = 0
    /// Pip on his own, centred and big — before there's any text.
    static let pipArtWidth: CGFloat = 190
    /// Pip's orb in the corner while listening.
    static let pipOrbListening: CGFloat = 44
    /// Pip's orb in the corner with an answer.
    static let pipOrbSmall: CGFloat = 34
    /// From the row's left edge: the orb's middle sits over the bar's icon.
    static let pipOrbCentreX: CGFloat = 17
    static var pipArtHeight: CGFloat { PipArt.height(forWidth: pipArtWidth) }
    // Pip's words have no card around them; kept so the sums below read.
    static let pipCardPadTop: CGFloat = 0
    static let pipCardPadBottom: CGFloat = 0
    static let pipCardPadSide: CGFloat = 0
    /// The answer's width: the whole row, under small Pip and your question.
    static var pipCardMaxWidth: CGFloat {
        pipWidth - pipSideInset * 2 - pipRowInset * 2
    }
    /// Between the header row (small Pip, your question) and the answer.
    static let pipAnswerGap: CGFloat = 10
    static var pipTextWidth: CGFloat { pipCardMaxWidth - pipCardPadSide * 2 }
    /// The window's width for a long answer (same margins).
    static let pipLongWidth: CGFloat = 600
    /// The text's width in the long window.
    static var pipLongTextWidth: CGFloat { pipLongWidth - pipSideInset * 2 - pipRowInset * 2 - pipCardPadSide * 2 }
    /// Taller than this at the usual width, an answer is long: more than
    /// three lines of plain text, or an explanation past this height.
    static let pipLongAnswerLines = 3
    static let pipLongExplanationHeight: CGFloat = 150
    /// The text's width below big Pip while listening (the narrow window).
    static var pipVoiceTextWidth: CGFloat { pipNarrowWidth - pipSideInset * 2 - pipCardPadSide * 2 }
    static let pipReplyLineHeight: CGFloat = 21
    /// Lines before a plain reply scrolls.
    static let pipReplyMaxLines = 6
    static let pipChipsHeight: CGFloat = 30
    /// The search bar, a capsule edge to edge along the bottom.
    static let pipSearchHeight: CGFloat = 40
    static let pipBottomRadius: CGFloat = 36
    static let pipFlare: CGFloat = 16
    // Beyond the spec: files Pip found, and Allow/Cancel.
    /// A file row: its name, and under it Pip's description or its title.
    static let pipResultHeight: CGFloat = 40
    /// A group's name above its rows (`ResultGroups`).
    static let pipGroupHeaderHeight: CGFloat = 20
    /// At most this many group names show (six rows rarely make more).
    static let pipMaxGroupHeaders = 3
    static let pipMaxResults = 6
    /// Web pictures: five a row, sized so the row spans the answer's width
    /// (80 pt in the narrow window left a gap once it widened to 600).
    static let pipPicturesPerRow = 5
    static let pipMaxPictureRows = 2
    static let pipPictureGap: CGFloat = 8
    static func pipPictureSide(width: CGFloat) -> CGFloat {
        floor((width - pipPictureGap * CGFloat(pipPicturesPerRow - 1)) / CGFloat(pipPicturesPerRow))
    }
    static func pipPicturesHeight(rows: Int, width: CGFloat) -> CGFloat {
        rows > 0 ? CGFloat(rows) * pipPictureSide(width: width) + CGFloat(rows - 1) * pipPictureGap : 0
    }
    static let pipConfirmHeight: CGFloat = 28
    /// Clears the hardware notch (the spec's 30, or the notch if taller).
    static func pipTopPadding(for metrics: NotchMetrics) -> CGFloat {
        max(30, metrics.notchSize.height)
    }

    /// With an answer, the header row sits this much higher: the most that
    /// keeps a long question's letters below the notch's bottom edge.
    static let pipHeaderLift: CGFloat = 10
    /// The top padding as laid out now.
    var pipTopInset: CGFloat { Self.pipTopPadding(for: metrics) - (pipCompact ? Self.pipHeaderLift : 0) }

    /// Lines in Pip's reply (or question), 0 when there's none showing.
    @Published var pipReplyLines = 0
    /// The answer showing is long: the window is `pipLongWidth` wide.
    @Published var pipLongAnswer = false
    /// The answer's text width, as laid out now.
    var pipAnswerWidth: CGFloat { pipLongAnswer ? Self.pipLongTextWidth : Self.pipTextWidth }
    /// The thinking state is showing ("Thinking…" beside Pip).
    @Published var pipThinking = false

    /// An explanation is showing (`PipExplanation`): its measured height,
    /// up to `PipExplanation.maxHeight`; 0 for plain text.
    @Published var pipExplanationHeight: CGFloat = 0
    /// The explanation is finished (it's laid out live as it's written).
    @Published var pipExplanationDone = false
    /// The row under an explanation: where it came from, Copy · Shorter ·
    /// More detail. Only once it's finished.
    static let pipAnswerActionsHeight: CGFloat = 26
    var pipShowsAnswerActions: Bool { pipExplanationHeight > 0 && pipExplanationDone && !pipThinking }

    /// The card's height for the reply showing.
    var pipReplyCardHeight: CGFloat {
        if pipExplanationHeight > 0 { return pipExplanationHeight }
        return Self.pipCardPadTop + CGFloat(pipReplyLines) * Self.pipReplyLineHeight + Self.pipCardPadBottom
    }

    /// Greeting: nothing said yet this time, nothing being worked on.
    var pipIsGreeting: Bool { !pipThinking && !pipBusy && pipReplyLines == 0 }

    /// Pip alone (greeting, thinking, listening) needs little width; text,
    /// chips, files and questions get the full width.
    static let pipNarrowWidth: CGFloat = 290
    var pipWindowWidth: CGFloat {
        // Listening never widens it; files, a question and suggestions do.
        let wide = (!pipVoiceLayout && pipTextMode && !pipThinking) || pipShowsChips || pipConfirming
            || (!pipThinking && (pipResults > 0 || pipPictureRows > 0))
        if wide, pipLongAnswer, !pipVoiceLayout, !pipThinking { return Self.pipLongWidth }
        return wide ? Self.pipWidth : Self.pipNarrowWidth
    }

    /// Text showing: Pip is small in the corner and the text takes the row.
    var pipTextMode: Bool { pipReplyLines > 0 }

    /// Listening to you: the orb goes to the corner as for an answer.
    @Published var pipListening = false
    /// Listening to you: Pip big and centred, your words below him.
    @Published var pipVoiceLayout = false

    /// Pip small in the corner with an answer; big otherwise (greeting,
    /// typing, listening, thinking).
    var pipCompact: Bool { pipTextMode && !pipVoiceLayout && !pipThinking }
    var pipOrb: CGFloat { pipListening ? Self.pipOrbListening : Self.pipOrbSmall }
    /// The orb sits at the row's top.
    var pipOrbTop: CGFloat { 0 }

    /// The top row: big Pip alone, or the header row and the answer below.
    var pipTopRowHeight: CGFloat {
        // Thinking: big Pip, the waves inside him, one line under him.
        if pipThinking { return Self.pipArtHeight + Self.pipRowGap + Self.pipReplyLineHeight }
        if pipVoiceLayout {
            return Self.pipArtHeight + (pipTextMode ? Self.pipRowGap + pipReplyCardHeight : 0)
        }
        guard pipCompact else { return Self.pipArtHeight }
        // Small Pip and your question, then the answer below them.
        return pipOrb + (pipTextMode ? Self.pipAnswerGap + pipReplyCardHeight : 0)
    }

    /// The answer starts under the header row.
    var pipTextTop: CGFloat { pipOrb + Self.pipAnswerGap }

    /// Chips only in the greeting, and never once a conversation has started.
    var pipShowsChips: Bool {
        pipIsGreeting && !pipHasHistory && !pipConfirming && !Self.pipSuggestionsRetired
    }

    /// Suggestions are for a first meeting: once you've asked Pip anything,
    /// ever, they don't come back.
    static var pipSuggestionsRetired: Bool {
        get { UserDefaults.standard.bool(forKey: "pipSuggestionsRetired") }
        set { UserDefaults.standard.set(newValue, forKey: "pipSuggestionsRetired") }
    }

    /// About 238 in the greeting, 194 thinking or replying (spec section 2).
    var pipSize: CGSize {
        var height = pipTopInset + pipTopRowHeight
        let results = pipThinking ? 0 : min(pipResults, Self.pipMaxResults)
        if results > 0 {
            height += Self.pipRowGap + CGFloat(results) * Self.pipResultHeight
                + CGFloat(min(pipResultHeaders, Self.pipMaxGroupHeaders)) * Self.pipGroupHeaderHeight
        }
        if pipPictureRows > 0, !pipThinking {
            height += Self.pipRowGap + Self.pipPicturesHeight(rows: pipPictureRows,
                                                               width: pipWindowWidth - Self.pipSideInset * 2)
        }
        if pipConfirming { height += Self.pipRowGap + Self.pipConfirmHeight }
        if pipNoteOffer, !pipThinking { height += Self.pipRowGap + Self.pipConfirmHeight }
        if pipShowsAnswerActions { height += Self.pipRowGap + Self.pipAnswerActionsHeight }
        if pipShowsChips { height += Self.pipRowGap + Self.pipChipsHeight }
        height += Self.pipRowGap + Self.pipSearchHeight + Self.pipBottomPadding
        return CGSize(width: pipWindowWidth, height: height)
    }

    /// Grows with the answer, up to a point, and no longer shrinks below the
    /// detail pane.
    ///
    /// A fixed panel is either too tall for two results or too short for five,
    /// and a box with three rows in a space meant for six reads as something
    /// having gone wrong. The island takes the size of what's in it — bounded
    /// below by what the right-hand pane needs.
    var searchSize: CGSize {
        // The chat is a fixed size. It holds a few lines of conversation,
        // and a box that grew and shrank with every reply would be the
        // panel twitching while you read it.
        if searchIsPet { return pipSize }
        let rows = CGFloat(min(max(searchRows, 0), Self.searchVisibleRows))
        let content = rows == 0
            ? 62                                        // the "type to search" hint
            : max(rows * Self.searchRowHeight + (searchHasMore ? 30 : 0) + 22,
                  Self.searchPaneMinimum)
        // The footer only exists once there's something to count.
        let footer = rows == 0 ? 0 : Self.searchFooterHeight
        return CGSize(width: Self.searchPanelWidth(for: metrics),
                      height: metrics.notchSize.height + Self.searchChrome
                            + content + footer + 14)
    }

    /// Wide enough for a list and a detail pane side by side, and no wider.
    ///
    /// 700, and the hover panel uses it too — see `shelfWidth`.
    ///
    /// The number is set by the quieter of the two panels, not the louder one.
    /// Search is opened deliberately and can justify width; the shelf appears
    /// because the pointer crossed the top of the screen, and half a 14-inch
    /// display arriving uninvited is a lot. 700 is 46% of 1512 rather than
    /// 52%, which is the difference between a panel and a takeover.
    ///
    /// Search gives up a little for that, and both columns share the cost
    /// rather than the card paying all of it — at a 420 list the card would be
    /// 228, which is under what a label column and a value need side by side.
    /// 390 and 258 is the split that keeps both usable.
    static func searchPanelWidth(for metrics: NotchMetrics) -> CGFloat {
        max(metrics.notchSize.width + 480, 700)
    }

    /// The tallest the search island can ever be, for sizing the window.
    var searchSizeMaximum: CGSize {
        // Pip at his tallest: a full reply, files and a question.
        // (Voice: big Pip with the reply below him, the tallest top row.)
        // (An explanation's top row, at most `PipExplanation.maxHeight`, is
        // the other candidate for the tallest; then its row of chips.)
        let pipTallest = Self.pipTopPadding(for: metrics)
            + max(Self.pipArtHeight + Self.pipRowGap
                    + Self.pipCardPadTop + CGFloat(Self.pipReplyMaxLines) * Self.pipReplyLineHeight + Self.pipCardPadBottom,
                  Self.pipOrbSmall + Self.pipAnswerGap + PipExplanation.maxHeight)
            + Self.pipRowGap + Self.pipAnswerActionsHeight
            + Self.pipRowGap + CGFloat(Self.pipMaxResults) * Self.pipResultHeight
            + CGFloat(Self.pipMaxGroupHeaders) * Self.pipGroupHeaderHeight
            + Self.pipRowGap + Self.pipPicturesHeight(rows: Self.pipMaxPictureRows,
                                                      width: Self.pipLongWidth - Self.pipSideInset * 2)
            + Self.pipRowGap + Self.pipConfirmHeight
            + Self.pipRowGap + Self.pipConfirmHeight      // Save to Notes
            + Self.pipRowGap + Self.pipChipsHeight
            + Self.pipRowGap + Self.pipSearchHeight + Self.pipBottomPadding
        let searchTallest = metrics.notchSize.height + Self.searchChrome
            + max(CGFloat(Self.searchVisibleRows) * Self.searchRowHeight + 30 + 22,
                  Self.searchPaneMinimum)
            + Self.searchFooterHeight + 14
        return CGSize(width: Self.searchPanelWidth(for: metrics), height: max(searchTallest, pipTallest))
    }

    /// Wide enough for a percentage clear of the camera — or narrow when the
    /// event is glyph-only, so it doesn't look lopsided. Events carrying a
    /// title (a filename, a meeting name) need room for words instead.
    var eventSize: CGSize {
        if event?.title != nil {
            return CGSize(width: max(metrics.notchSize.width + 250, 440),
                          height: metrics.notchSize.height)
        }
        let inset = event?.trailing == nil ? NotchGeometry.compactInset : NotchGeometry.eventInset
        return CGSize(width: metrics.notchSize.width + inset * 2,
                      height: metrics.notchSize.height)
    }

    func size(for presentation: NotchPresentation) -> CGSize {
        switch presentation {
        case .collapsed: return collapsedSize
        case .compact:   return compactSize
        case .event:     return eventSize
        case .expanded:  return expandedSize
        case .search:    return searchSize
        }
    }

    var currentSize: CGSize { size(for: presentation) }

    /// The window is only as big as the expanded island (plus room for its shadow).
    /// Anything larger becomes a dead zone for clicks while the island is open.
    var panelSize: CGSize { panelSize(withDropShelf: hasDropShelf) }

    /// Explicit, for sinks: @Published fires in willSet, so inside one the
    /// property still holds the old value.
    func panelSize(withDropShelf dropShelf: Bool) -> CGSize {
        // The tallest the expanded island can ever be, not the tallest it is
        // right now. The window is built once; sizing it to the current state
        // means the utility row appearing later gets clipped by a window that
        // was correct when it was made.
        let tallest = metrics.notchSize.height + 42
            + (dropShelf ? 170 + Self.dropShelfRowHeight : 148)
        // The wider of the two expanded shapes, not whichever is showing. The
        // window is built once, and sizing it to the current state means the
        // shelf gets clipped by a window that was correct when it was made.
        let widest = max(Self.playerWidth(for: metrics), Self.shelfWidth(for: metrics))
        return CGSize(width: widest + 48,
                      height: tallest + 32 + NotchGeometry.verticalOffset)
    }

    /// The window is sized for the largest the island can get, and left there.
    ///
    /// Resizing a window on every keystroke as results come and go is visible
    /// even when the window is transparent — and pointless, because the only
    /// thing anyone sees is the island inside it, which animates on its own.
    var searchPanelSize: CGSize {
        CGSize(width: searchSizeMaximum.width + 48,
               height: searchSizeMaximum.height + 32 + NotchGeometry.verticalOffset)
    }

    /// Both the ask panel and the search panel need the keyboard and a bigger
    /// window. They behave identically as far as the panel is concerned, so it
    /// tracks one flag rather than two.
    var needsFocus: Bool { isSearching }

    /// The window the search panel needs. Only one thing takes focus now, so
    /// this no longer has to choose between two.
    var focusPanelSize: CGSize { searchPanelSize }

    // MARK: - Placement

    func apply(_ metrics: NotchMetrics) {
        self.metrics = metrics
        self.isExpanded = false
        self.isSearching = false
    }

    /// Anything below this y can't possibly be hovering the closed island.
    /// Used to reject the overwhelming majority of mouse-move events in one
    /// comparison, before any rect maths happens.
    var hoverThresholdY: CGFloat {
        metrics.screenFrame.maxY - collapsedSize.height - NotchGeometry.verticalOffset - 6
    }

    /// The island's rect in screen coordinates for a given presentation.
    func islandScreenRect(for presentation: NotchPresentation) -> CGRect {
        let size = size(for: presentation)
        let frame = metrics.screenFrame
        return CGRect(x: frame.midX - size.width / 2,
                      y: frame.maxY - size.height - NotchGeometry.verticalOffset,
                      width: size.width,
                      height: size.height)
    }
}
