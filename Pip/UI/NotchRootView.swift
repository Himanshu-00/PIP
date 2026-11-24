import SwiftUI

struct NotchRootView: View {

    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var engine: MediaEngine
    @EnvironmentObject private var search: SearchController
    @EnvironmentObject private var shelf: ScreenshotShelf
    @EnvironmentObject private var pet: Pet
    @EnvironmentObject private var agent: PetAgent
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var dropShelf = DropShelf.shared

    @State private var searchHovering = false

    /// Non-nil while the user is dragging the scrub bar.
    @State private var scrubPreview: Double?

    var body: some View {
        VStack(spacing: 0) {
            island
                .padding(.top, NotchGeometry.verticalOffset)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    // MARK: - Island

    private var shape: NotchShape {
        switch state.presentation {
        case .collapsed:
            // Zero top radius: no black flares bleeding onto the menu bar.
            return NotchShape(topCornerRadius: 0, bottomCornerRadius: 10)
        case .compact:
            return NotchShape(topCornerRadius: 6, bottomCornerRadius: 13)
        case .event:
            return NotchShape(topCornerRadius: 7, bottomCornerRadius: 14)
        case .expanded:
            return NotchShape(topCornerRadius: 11, bottomCornerRadius: 26)
        case .search:
            // Pip's window has its own corners: 16 flares and a 36 bottom,
            // per his design spec.
            if search.mode == .pet {
                return NotchShape(topCornerRadius: NotchState.pipFlare,
                                  bottomCornerRadius: NotchState.pipBottomRadius)
            }
            // The same radii as the hover panel. Search grows out of it, and
            // corners that change while the box grows read as a second
            // animation layered on the first.
            return NotchShape(topCornerRadius: 11, bottomCornerRadius: 26)
        }
    }

    private var island: some View {
        // The shape is sized first and content hung off it as top overlays (a ZStack
        // would size to its biggest child).
        shape
            // Open panels: glass below the black. Closed and compact: solid black.
            .fill(isGlass ? Color.clear : Color.black)
            // Swapped at once, never cross-faded: halfway through a fade
            // neither the black nor the glass's black top is opaque, and the
            // real notch showed through for a moment as a panel opened.
            .animation(nil, value: isGlass)
            .islandSize(state.currentSize, notLessThan: state.collapsedSize)
            .background(alignment: .top) {
                // Glass from the first frame (owner, 2026-11-21). A SwiftUI
                // stand-in until the shape settled hid the glass's outline at
                // the final size, but opened darker and the blur popped in.
                if isGlass {
                    PipGlass(shape: shape, notchHeight: state.metrics.notchSize.height)
                        // Same reason: in at once, not faded in.
                        .transition(.identity)
                }
            }
            // Each layer is mounted only in its own state, so hidden timers don't tick.
            .overlay(alignment: .top) {
                if state.presentation == .compact {
                    compactContent
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .offset(y: -3)))
                        .animation(.spring(response: 0.34, dampingFraction: 0.8),
                                   value: state.presentation)
                }
            }
            .overlay(alignment: .top) {
                if state.presentation == .event {
                    eventContent
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                // Opacity only (blur or scale render offscreen and flashed the notch);
                // `presentation`, not `isExpanded`.
                if state.presentation == .expanded {
                    // Slides down a beat after the shape opens (offset only).
                    expandedContent
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -8))
                                .animation(.spring(response: 0.32, dampingFraction: 0.82)
                                    .delay(0.07)),
                            // Removed instantly: the search field appears at exactly its size and place.
                            removal: .identity))
                }
            }
            .overlay(alignment: .top) {
                if state.presentation == .search {
                    searchContent
                        // No transition in: the field morphs from the bar, results fade in later.
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .opacity.animation(.easeOut(duration: 0.12))))
                }
            }
            .overlay {
                // A 1 pt matte rim along the bottom edge, for the pre-Liquid Glass blur.
                if isGlass, !PipGlass.isLiquid {
                    shape
                        .stroke(Color.white.opacity(0.16), lineWidth: 2)
                        .mask(LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.7),
                            .init(color: .black, location: 1),
                        ], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                }
            }
            .clipShape(shape)
            // Corner radii only (size is per axis above); full screen skips the spring.
            .animation(state.isFullScreen ? .easeOut(duration: 0.12) : .island,
                       value: state.presentation)
    }

    /// An open panel — Pip, search, or the hover panel — which is glass.
    private var isGlass: Bool { state.presentation == .search || state.presentation == .expanded }


    /// Pip, or the full search panel — the same slot, the same window and
    /// keyboard handling, different contents.
    @ViewBuilder
    private var searchContent: some View {
        if search.mode == .pet {
            PipView(search: search, pet: pet, agent: agent) { url in
                SearchController.forPip.recordPipOpen(url)
                NSWorkspace.shared.open(url)
                search.close()
            }
        } else {
            SearchView(search: search)
        }
    }

    // MARK: - Compact content (compactLeading)

    /// Two strips either side of the camera, exactly like the iPhone:
    /// compactLeading is the album art, compactTrailing is the live value.
    private var compactContent: some View {
        HStack(spacing: 0) {
            compactArtwork
            Spacer(minLength: 0)
            compactTrailing
                .frame(width: state.compactTrailingWidth, height: 22)
        }
        .padding(.horizontal, (NotchGeometry.compactInset - 22) / 2)
        .frame(width: state.compactSize.width,
               height: state.compactSize.height)
    }

    /// The right strip. Live indicators — mic, Focus — outrank the
    /// waveform, because "something is listening to you" is worth more of your
    /// attention than "music is playing", which you already know.
    @ViewBuilder
    private var compactTrailing: some View {
        if state.timerActive {
            // The countdown takes the waveform's place; indicators stay.
            HStack(spacing: 5) {
                ForEach(state.indicators) { indicator in
                    Image(systemName: indicator.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(indicator.tint)
                        .symbolEffect(.pulse, isActive: indicator.pulses)
                }
                Spacer(minLength: 0)
                timerText
            }
        } else if state.indicators.isEmpty {
            AudioBars(isPlaying: engine.now?.isPlaying == true,
                      color: engine.accent,
                      isSuspended: state.isSuspended)
        } else {
            HStack(spacing: 5) {
                ForEach(state.indicators) { indicator in
                    Image(systemName: indicator.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(indicator.tint)
                        .symbolEffect(.pulse, isActive: indicator.pulses)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: state.indicators)
        }
    }

    /// Time left: counting (redrawn by the system each second) or paused.
    @ViewBuilder
    private var timerText: some View {
        if let end = state.timerEnd, end > Date() {
            Text(timerInterval: Date()...end, countsDown: true, showsHours: true)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Self.timerTint)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        } else if let left = state.timerPausedLeft {
            Text(Self.clock(left))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Self.timerTint.opacity(0.5))
                .lineLimit(1)
        }
    }

    static let timerTint = Color(red: 1.0, green: 0.62, blue: 0.04)

    /// "4:59", "1:05:00".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                         : String(format: "%d:%02d", minutes, secs)
    }

    @ViewBuilder
    private var compactArtwork: some View {
        if engine.now?.isValid == true {
            ArtworkView(image: engine.artwork, size: 22, cornerRadius: 7, glyphSize: 10)
            // Pop when the track changes.
            .id(engine.now?.artworkFingerprint ?? "idle")
            .transition(.scale(scale: 0.55).combined(with: .opacity))
            .animation(.spring(response: 0.32, dampingFraction: 0.78),
                       value: engine.now?.artworkFingerprint)
        } else if state.timerActive {
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.timerTint)
                .frame(width: 22, height: 22)
        } else {
            // Indicators only: nothing on the left, so the glyphs sit on the
            // right where the waveform would be and the island stays balanced.
            Color.clear.frame(width: 22, height: 22)
        }
    }

    // MARK: - Transient events

    @ViewBuilder
    private var eventContent: some View {
        if let event = state.event {
            HStack(spacing: 7) {
                if case .hint = event {
                    // Click to ask is armed: small Pip, listening, instead of a dot.
                    PipArt(expression: .listening, width: 44, interactive: false)
                        .frame(width: 44, height: PipArt.height(forWidth: 44))
                        .scaleEffect(20 / 44)
                        .frame(width: 26, height: 20)
                } else if let battery = event.battery {
                    BatteryGlyph(level: battery.level, charging: battery.charging, tint: event.tint)
                        .frame(width: 26, height: 20)
                } else {
                    Image(systemName: event.symbol)
                        .font(.system(size: event.glyphSize, weight: .bold))
                        .foregroundStyle(event.tint)
                        .frame(width: 26, height: 20)
                }

                if let title = event.title {
                    // The title has to clear the camera housing, so it goes on
                    // the left of it and the island widens to suit.
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120, alignment: .leading)
                }

                Spacer(minLength: 0)

                if let trailing = event.trailing {
                    Text(trailing)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        // A battery's percentage in its colour, as on iPhone.
                        .foregroundStyle(event.battery != nil ? event.tint : .white.opacity(0.92))
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: state.eventSize.width, height: state.eventSize.height)
            .transition(.opacity)
        }
    }

    // MARK: - Expanded content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keep clear of the physical camera housing.
            Color.clear.frame(height: state.metrics.notchSize.height + 10)

            // One predicate for the size and the content — see
            // NotchState.showsPlayer. These used to disagree.
            if state.isDropTargeting {
                // A file drag is over the panel: one thing to say.
                DropTargetView()
                    .padding(.bottom, 4)
                    .transition(.opacity)
            } else if state.showsPlayer, let track = engine.now, track.isValid {
                playerBody(track)
            } else {
                idleBody
            }

            if let utility = state.utility {
                Divider()
                    .overlay(.white.opacity(0.08))
                    .padding(.top, 11)
                    .padding(.bottom, 9)
                utilityRow(utility)
            }
        }
        // 20, matching the search panel, so the bar and the field share an
        // x as well as a y.
        .padding(.horizontal, 20)
        .padding(.bottom, 15)
        .frame(width: state.expandedSize.width, height: state.expandedSize.height, alignment: .top)
    }

    private func playerBody(_ track: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                artworkView

                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(text: track.title,
                                font: .system(size: 14.5, weight: .semibold))
                        .id(track.artworkFingerprint)

                    Text(track.artist.isEmpty ? track.appName : track.artist)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                controls(track)

                // Back to the shelf without stopping the music. Without this,
                // anything playing means the screenshots are unreachable by
                // pointer for as long as it plays.
                IslandButton(symbol: "photo.on.rectangle", size: 12, style: .plain) {
                    state.expandedPreference = .tools
                }
            }

            progress(track)
        }
    }

    /// Hovering with nothing playing: search, then the screenshot shelf.
    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The bar on its own row, matching the search field's inset and height.
            HStack(spacing: 12) {
                searchOpener
                Spacer(minLength: 0)
                if state.hasTrack, let track = engine.now, track.isValid {
                    NowPlayingChip(track: track, artwork: engine.artwork, accent: engine.accent) {
                        state.expandedPreference = .player
                    }
                }
            }
            .padding(.bottom, 14)

            sectionHeading("Recent screenshots")
                .padding(.bottom, 10)

            ShelfView(shelf: shelf)

            // Mounted only with something on it (NotchState.dropShelfRowHeight).
            if state.hasDropShelf {
                sectionHeading("Kept here")
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                DropShelfView(shelf: dropShelf)
            }
        }
    }

    /// The search bar's outline under the pointer.
    static let barStrokeHover = 0.2

    private var searchOpener: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(searchHovering ? 0.8 : 0.5))

            Text("Search files")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(searchHovering ? 0.62 : 0.42))

            Spacer(minLength: 10)

            Text(HotKeyCenter.choices[min(max(prefs.searchHotKeyIndex, 0),
                                          HotKeyCenter.choices.count - 1)].title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.36))
                // The same keycap as the search footer's — fill, hairline and
                // padding — so the shortcut looks like one key everywhere.
                .frame(minWidth: 11)
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(.white.opacity(IslandStyle.controlFill))
                        .overlay(Capsule().strokeBorder(
                            .white.opacity(IslandStyle.controlStroke), lineWidth: 1)))
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(width: SearchView.barWidth, height: 38)
        // Outline only on the glass panel; it brightens on hover.
        .contentShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(searchHovering ? Self.barStrokeHover
                                                                      : IslandStyle.controlStroke),
                                        lineWidth: 1))
        .animation(.easeOut(duration: 0.14), value: searchHovering)
        .overlay(ClickableArea(onClick: { state.onOpenSearch?() },
                               onHover: { searchHovering = $0 }))
    }

    /// The search results' heading style, without their rule: on the glass
    /// panel the line read as a seam through it.
    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.30))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The next meeting, or the download that just landed. One line, one
    /// button — anything richer belongs in the app that owns it.
    private func utilityRow(_ utility: NotchUtility) -> some View {
        HStack(spacing: 9) {
            Image(systemName: utility.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(utility.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(utility.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(utility.subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if let title = utility.secondaryTitle, let action = utility.secondaryAction {
                TinyButton(title: title, prominent: false, action: action)
            }
            if let title = utility.actionTitle, let action = utility.action {
                TinyButton(title: title, prominent: true, action: action)
            }
        }
        .frame(height: 30)
    }

    // MARK: - Pieces

    private var artworkView: some View {
        ArtworkView(image: engine.artwork, size: 62, cornerRadius: 16, glyphSize: 22)
            .overlay(alignment: .bottomTrailing) {
                // Which app the audio is coming from, the way iOS badges its
                // Now Playing art. Cheaper and clearer than a line of text.
                if let bundleID = engine.now?.bundleID,
                   let icon = AppIcon.icon(for: bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.black.opacity(0.9), lineWidth: 2))
                        .offset(x: 6, y: 5)
                }
            }
            .animation(.easeOut(duration: 0.25), value: engine.artwork)
    }

    private func controls(_ track: NowPlaying) -> some View {
        HStack(spacing: 8) {
            IslandButton(symbol: "backward.fill", size: 13, style: .plain) { engine.send(.previous) }
            IslandButton(symbol: track.isPlaying ? "pause.fill" : "play.fill",
                         size: 15, style: .filled) { engine.send(.playPause) }
            IslandButton(symbol: "forward.fill", size: 13, style: .plain) { engine.send(.next) }
        }
    }

    private func progress(_ track: NowPlaying) -> some View {
        // 1 Hz while playing, every 10 minutes while paused.
        TimelineView(.periodic(from: .now, by: track.isPlaying ? 1 : 600)) { _ in
            let seekable = track.duration > 0
            let fraction = seekable ? track.currentElapsed() / track.duration : 0
            // While scrubbing, the label reads where you're going, not where you are.
            let shownTime = (scrubPreview.map { $0 * track.duration }) ?? track.currentElapsed()

            VStack(spacing: 3) {
                ScrubBar(fraction: fraction,
                         preview: $scrubPreview,
                         enabled: seekable,
                         tint: engine.accent) { target in
                    engine.seek(toFraction: target)
                }  

                HStack {
                    Text(NowPlaying.timeString(shownTime))
                        .foregroundStyle(.white.opacity(scrubPreview == nil ? 0.38 : 0.8))
                    Spacer()
                    Text(seekable ? NowPlaying.timeString(track.duration) : "--:--")
                        .foregroundStyle(.white.opacity(0.38))
                }
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            }
        }
        .frame(height: 34)
        .opacity(track.duration > 0 ? 1 : 0.3)
    }
}

/// Text button for the utility row. Same ClickableArea trick as everything
/// else here — SwiftUI gestures never fire in a non-activating panel.
private struct TinyButton: View {
    let title: String
    var prominent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(prominent || hovering ? 1 : 0.65))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            // Palette tokens, not private greys: these sit beside the search
            // controls and should be the same family of fills.
            .background(Capsule().fill(.white.opacity(
                prominent ? (hovering ? IslandStyle.controlActive : IslandStyle.controlHover)
                          : (hovering ? IslandStyle.controlHover : IslandStyle.controlFill))))
            .overlay(ClickableArea(onClick: action, onHover: { hovering = $0 }))
            .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Flat, hover-highlighted glyph button that works inside a non-key panel.
/// A battery drawn like the menu bar's: an outline with a cap, filled to the
/// charge in `tint`, a bolt on it while charging.
private struct BatteryGlyph: View {

    let level: Double
    let charging: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint)
                        .frame(width: max(2.5, (proxy.size.width - 4) * min(max(level, 0), 1)))
                        .padding(2)
                }
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 0.5)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 23, height: 11.5)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(.white.opacity(0.35))
                .frame(width: 1.5, height: 4)
        }
    }
}

/// What's playing, beside the search bar, small like the music notch: cover,
/// the title's first two words, the bars in the song's colour. Click for the player.
private struct NowPlayingChip: View {

    let track: NowPlaying
    let artwork: NSImage?
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    /// The title's first two words ("Blinding Lights", "Bohemian Rhapsody").
    private var shortTitle: String {
        track.title.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(image: artwork, size: 22, cornerRadius: 6, glyphSize: 10)
            Text(shortTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.72))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 110, alignment: .leading)
            AudioBars(isPlaying: track.isPlaying, color: accent)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 38)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(hovering ? NotchRootView.barStrokeHover
                                                                : IslandStyle.controlStroke),
                                        lineWidth: 1))
        .animation(.easeOut(duration: 0.14), value: hovering)
        .overlay(ClickableArea(onClick: action, onHover: { hovering = $0 }))
        .help("Show the player")
    }
}

private struct IslandButton: View {

    enum Style { case plain, filled }

    let symbol: String
    var size: CGFloat
    var style: Style = .plain
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    private var background: Double {
        switch style {
        case .plain:  return hovering ? IslandStyle.controlHover : 0
        case .filled: return hovering ? IslandStyle.controlActive : IslandStyle.controlHover
        }
    }

    private func press() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { pressed = true }
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { pressed = false }
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white.opacity(hovering || style == .filled ? 1 : 0.78))
            .frame(width: size + 18, height: size + 18)
            .background(Circle().fill(.white.opacity(background)))
            .scaleEffect(pressed ? 0.86 : 1)
            // An AppKit view rather than .onTapGesture — see ClickableArea.
            .overlay(ClickableArea(onClick: press, onHover: { hovering = $0 }))
            .animation(.easeOut(duration: 0.15), value: hovering)
    }

}

