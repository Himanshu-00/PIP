import AppKit
import SwiftUI
import Combine

/// Borderless, always-on-top panel that sits exactly over the hardware notch.
///
/// Click handling is the important part here. A window whose view hierarchy
/// declines a click does **not** forward that click to the window underneath —
/// it swallows it. The only true pass-through is `ignoresMouseEvents`, so the
/// panel keeps that switched on whenever the island is closed, and the window
/// itself is kept no bigger than the island needs to be.
@MainActor
final class NotchPanel: NSPanel {

    private let state: NotchState
    private var monitors: [Any] = []
    private var collapseWorkItem: DispatchWorkItem?
    private var expandWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var lastMouse: (point: CGPoint, at: TimeInterval)?
    private var spaceObserver: Any?
    private var panelIdleWork: DispatchWorkItem?
    private var reassertWork: DispatchWorkItem?
    init<Content: View>(metrics: NotchMetrics, state: NotchState, rootView: Content) {
        self.state = state

        let size = state.panelSize
        let frame = NSRect(x: metrics.screenFrame.midX - size.width / 2,
                           y: metrics.screenFrame.maxY - size.height,
                           width: size.width,
                           height: size.height)

        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        acceptsMouseMovedEvents = true
        // Closed island == completely transparent to the mouse.
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = PanelHostView(rootView: AnyView(rootView))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        // The drop shelf: a file drag over the open panel, and the drop.
        host.onTargeting = { [weak state] targeting in
            guard let state, state.isDropTargeting != targeting else { return }
            state.isDropTargeting = targeting
        }
        host.onDrop = { [weak state] urls in
            DropShelf.shared.add(urls)
            // Show where they went, even with music playing.
            state?.expandedPreference = .tools
        }
        contentView = host

        setFrame(frame, display: true)
        installHoverMonitors()
        observeFocus()
        observeSpaces()

        // Fade in once SwiftUI has done its first layout pass, otherwise the
        // hosting view's initial sizing is visible as a bounce on launch.
        alphaValue = 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self.animator().alphaValue = 1
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Take key on the click itself.
    ///
    /// The app can be active while this panel isn't key — nothing else owns a
    /// window — and AppKit delivers clicks to the key window. Without this the
    /// event arrives, hit-tests correctly, and has nowhere to go.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            if state.needsFocus,
               !state.islandScreenRect(for: state.presentation).contains(NSEvent.mouseLocation) {
                state.onDismissSearch?()
                return
            }
            if !isKeyWindow, state.isExpanded {
                makeKeyAndOrderFront(nil)
            }
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }

    /// Keys typed while the hover panel is merely key (it has no field)
    /// are dropped quietly rather than beeping.
    override func noResponder(for eventSelector: Selector) {
        if eventSelector == #selector(NSResponder.keyDown(with:)), !state.needsFocus { return }
        super.noResponder(for: eventSelector)
    }
    override var canBecomeMain: Bool { false }

    /// Set once the panel has been replaced; nothing may bring it back.
    private var isTornDown = false

    /// Called when the panel is replaced (display change, Realign).
    ///
    /// Must leave it inert, not just hidden: its state subscriptions used to
    /// survive, and the "put the window back" safety net below ordered the
    /// old panel in again. Two panels then stacked their glass (twice the
    /// blur) and took focus from each other on every hotkey.
    func teardown() {
        isTornDown = true
        cancellables.removeAll()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
        collapseWorkItem?.cancel()
        expandWorkItem?.cancel()
        panelIdleWork?.cancel()
        reassertWork?.cancel()
        orderOut(nil)
        // Releases the SwiftUI tree, which otherwise keeps redrawing for
        // every state change behind a window nobody can see.
        contentView = nil
        // Off NSApp.windows. Not released by AppKit as well: ARC owns it.
        isReleasedWhenClosed = false
        close()
    }

    // Every way back on screen or to the key, refused once torn down — one
    // place, so no caller (here or in AppDelegate) can revive an old panel.
    override func makeKeyAndOrderFront(_ sender: Any?) {
        guard !isTornDown else { return }
        super.makeKeyAndOrderFront(sender)
    }

    override func makeKey() {
        guard !isTornDown else { return }
        super.makeKey()
    }

    override func orderFrontRegardless() {
        guard !isTornDown else { return }
        super.orderFrontRegardless()
    }

    #if DEBUG
    // Glass is frost without the key: log every change, with who has it now.
    override func becomeKey() {
        super.becomeKey()
        ActivityLog.write(.system, "debug key: panel \(windowNumber) became key")
    }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async {
            ActivityLog.write(.system, "debug key: panel \(self.windowNumber) lost key — now "
                              + "\(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none"), active \(NSApp.isActive), "
                              + "front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        }
    }
    #endif

    /// Closes an open panel a couple of seconds after the pointer leaves it.
    ///
    /// Generous on the boundary, because the panel's visible edge and its
    /// window are not the same rectangle, and a shortcut that vanishes because
    /// the pointer strayed four points is worse than one that lingers.
    private func evaluatePanelIdle() {
        let zone = state.islandScreenRect(for: state.presentation).insetBy(dx: -24, dy: -24)
        if zone.contains(NSEvent.mouseLocation) {
            cancelPanelIdle()
            return
        }
        guard panelIdleWork == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panelIdleWork = nil
            // Checked again on the way out: the pointer may have come back,
            // and the panel may have been typed into since.
            guard self.state.needsFocus,
                  !self.state.islandScreenRect(for: self.state.presentation)
                    .insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation)
            else { return }
            self.state.onPointerIdle?()
        }
        panelIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func cancelPanelIdle() {
        panelIdleWork?.cancel()
        panelIdleWork = nil
    }

    // MARK: - Spaces

    /// Re-asserts the window whenever the active space changes.
    ///
    /// A window created while a full-screen space is in front doesn't reliably
    /// come back when that space goes away, even with `.canJoinAllSpaces`. The
    /// symptom is the one that's hardest to attribute: launch the app while
    /// something is already full screen and the island works — until you leave
    /// full screen, at which point it is simply never seen again, and nothing
    /// about it looks broken because the process is running perfectly.
    ///
    /// `orderFrontRegardless` on every space change costs nothing and makes
    /// the launch order irrelevant.
    private func observeSpaces() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reassertAfterSpaceChange() }
            }

        // Full screen removes the window, rather than collapsing it to the
        // size of the notch.
        //
        // Collapsing was nearly invisible and nearly isn't good enough: a
        // borderless panel over a letterbox strip still leaves an edge where
        // two blacks don't quite agree. Taking it off screen leaves nothing to
        // disagree about, and an ordered-out window also stops compositing
        // entirely — which is the honest version of "doesn't consume anything
        // while it isn't wanted".
        state.$isFullScreen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hidden in
                MainActor.assumeIsolated {
                    hidden ? self?.fadeOut() : self?.fadeIn()
                }
            }
            .store(in: &cancellables)

        // A safety net, because ordering the window out is unrecoverable in a
        // way that collapsing it never was.
        //
        // If `isFullScreen` is ever wrong, a collapsed island is invisible but
        // still there — hover brings it back. An ordered-out one is gone, and
        // nothing the user can do reaches it. So whenever the island has
        // something to show and nothing is supposed to be hidden, the window
        // is put back. Cheap, idempotent, and it turns a permanent failure
        // into a momentary one.
        // `presentation` is computed, so the things that feed it are what can
        // be watched.
        Publishers.CombineLatest3(state.$hasMedia, state.$indicators, state.$isExpanded)
            .map { media, indicators, expanded in media || !indicators.isEmpty || expanded }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] wantsToShow in
                MainActor.assumeIsolated {
                    guard let self, wantsToShow,
                          !self.state.isFullScreen, !self.isVisible else { return }
                    self.fadeIn()
                }
            }
            .store(in: &cancellables)
    }

    /// Re-asserts the window after a space change, but not immediately.
    ///
    /// A space change *is* the full-screen transition, and at the moment the
    /// notification arrives nothing has decided anything yet — the occupancy
    /// check is still running its first samples. Ordering the window to the
    /// front right then puts the island back on screen for a few hundred
    /// milliseconds before it's hidden again, which is the flicker.
    ///
    /// Waiting means the decision has been made by the time this runs, and
    /// the only case it exists for — a window created while a full-screen
    /// space was in front, which doesn't return on its own — is not
    /// time-critical in the slightest.
    private func reassertAfterSpaceChange() {
        reassertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.state.isFullScreen else { return }
            self.orderFrontRegardless()
        }
        reassertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    /// Fades rather than snapping.
    ///
    /// `orderOut` on its own is instantaneous, and an instantaneous
    /// disappearance reads as a glitch — especially against a full-screen
    /// transition, which is itself a half-second animation. A short fade makes
    /// the island look like part of that movement instead of something that
    /// broke during it.
    ///
    /// Deliberately faster out than in: leaving is the urgent direction.
    func fadeOut() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Checked again on completion: full screen can end inside the
            // fade, and ordering out then would hide a window that should be
            // coming back.
            MainActor.assumeIsolated {
                guard let self, self.state.isFullScreen else { return }
                self.orderOut(nil)
            }
        })
    }

    func fadeIn() {
        // Already up and opaque: nothing to do. Without this, a redundant call
        // drops alpha to zero and fades it back in — a flash for no reason.
        guard !isVisible || alphaValue < 0.99 else { return }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            animator().alphaValue = 1
        }
    }

    // MARK: - Drop
    // MARK: - Focus

    /// The window grows for the search panel and shrinks back afterwards.
    ///
    /// Read the value handed to the sink, never `state.isSearching`: @Published
    /// fires in `willSet`, so the property still holds the *old* value while
    /// subscribers run. Reading it here is what previously disabled mouse
    /// capture on the same tick it was enabled.
    private func observeFocus() {
        // The drop shelf's row adds height to the hover panel; the window
        // is sized for it only while there is one.
        state.$hasDropShelf
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] hasShelf in
                MainActor.assumeIsolated {
                    guard let self, !self.state.needsFocus else { return }
                    self.resizePanel(to: self.state.panelSize(withDropShelf: hasShelf))
                }
            }
            .store(in: &cancellables)

        state.$isSearching
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] focused in
                MainActor.assumeIsolated { self?.syncFocus(focused) }
            }
            .store(in: &cancellables)
    }

    /// Activation is only a request since macOS 14, and it is sometimes
    /// refused — most often after a while of use with another app in front.
    /// Refused, the panel isn't key: typing goes nowhere and Liquid Glass
    /// falls back to frost. So check shortly after and ask again, a few times.
    private func confirmFocus(attempt: Int = 1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.isTornDown, self.state.needsFocus else { return }
            self.repairStaleKey()
            if NSApp.isActive, self.isKeyWindow {
                if attempt > 1 { ActivityLog.write(.system, "panel focused on attempt \(attempt)") }
                return
            }
            guard attempt <= 3 else {
                ActivityLog.write(.system, "panel never got focus (app active \(NSApp.isActive), key \(self.isKeyWindow))")
                return
            }
            let panels = NSApp.windows.filter { $0 is NotchPanel }.map { "\($0.windowNumber)\($0.isVisible ? "" : " hidden")" }
            ActivityLog.write(.system, "panel \(self.windowNumber) not focused (app active \(NSApp.isActive), key window "
                              + "\(NSApp.keyWindow.map { "\(type(of: $0)) \($0.windowNumber)" } ?? "none"), panels \(panels)) — asking again")
            NSApp.activate()
            self.makeKeyAndOrderFront(nil)
            self.confirmFocus(attempt: attempt + 1)
        }
    }

    /// NSApp thinks the panel is key but the panel was told otherwise —
    /// left behind when something resigned it without going through AppKit.
    /// makeKey can't fix it (as far as NSApp knows it's already key), so
    /// tell the window, which lines the two back up.
    private func repairStaleKey() {
        guard !isTornDown, NSApp.isActive, NSApp.keyWindow === self, !isKeyWindow else { return }
        ActivityLog.write(.system, "panel key state was stale — repaired")
        becomeKey()
    }

    private func syncFocus(_ focused: Bool) {
        expandWorkItem?.cancel(); expandWorkItem = nil
        collapseWorkItem?.cancel(); collapseWorkItem = nil

        ignoresMouseEvents = !(focused || state.isExpanded)

        if focused {
            resizePanel(to: state.focusPanelSize)
            // Typing needs real keyboard focus, and an .accessory app has to
            // activate to get it — the panel alone becoming key isn't enough.
            // Alpha is restored explicitly: the panel may be mid-fade, or
            // fully faded out because something is full screen, and a hotkey
            // bringing back an invisible window is indistinguishable from a
            // hotkey that did nothing.
            alphaValue = 1
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            repairStaleKey()
            confirmFocus()
            #if DEBUG
            let panels = NSApp.windows.filter { $0 is NotchPanel }.count
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                ActivityLog.write(.system, "debug focus: \(panels) NotchPanel, key \(self.isKeyWindow), "
                                  + "keyWindow is self \(NSApp.keyWindow === self), active \(NSApp.isActive)")
            }
            #endif
        } else {
            // Hands focus back to whatever the user was actually working in.
            // NSApp.hide(nil) would hide our own panel along with it.
            //
            // No `resignKey()` first. That is AppKit's notification to the
            // window, not a request: calling it only cleared the panel's own
            // flag, NSApp.keyWindow still named the panel, and if the
            // deactivation hadn't landed by the next ⌥F, makeKey saw an
            // already-key window and did nothing — the panel never got the
            // key, and the glass drew as frost. Deactivating resigns it
            // properly.
            NSApp.deactivate()
            // Shrink only after the close animation has played, otherwise the
            // panel clips its own contents on the way out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
                guard let self, !self.state.needsFocus else { return }
                self.resizePanel(to: self.state.panelSize)
                self.ignoresMouseEvents = !self.state.isExpanded
                // A hotkey brought the window back over a full-screen app —
                // deliberately, so that was right — but closing the panel has
                // to put it away again. Without this, using ⌥F during a film
                // leaves the island sitting there afterwards.
                if self.state.isFullScreen { self.fadeOut() }
            }
        }
    }

    private func resizePanel(to size: CGSize) {
        let screen = state.metrics.screenFrame
        let rect = NSRect(x: screen.midX - size.width / 2,
                          y: screen.maxY - size.height,
                          width: size.width,
                          height: size.height)
        guard frame != rect else { return }

        // `display: false`, and no manual resize of the content view.
        //
        // The hosting view already has an autoresizing mask, so setting its
        // frame by hand was redundant — and doing it while AppKit was midway
        // through a layout pass is what produced "not legal to call
        // -layoutSubtreeIfNeeded on a view which is already being laid out".
        // Forcing an immediate display made it likelier by running layout
        // synchronously inside a Combine sink.
        setFrame(rect, display: false)
    }

    // MARK: - Hover

    private func installHoverMonitors() {
        // One monitor pair for everything, not one per feature.
        //
        // Hover and drop both care about mouse movement, and registering two
        // sets meant every pointer movement was delivered twice, all day.
        // `.rightMouseDragged` is gone as well — dragging with the right button
        // is never an attempt to open the island.
        //
        // Global monitors keep working even though the window ignores mouse
        // events, which is why hover detection doesn't rely on the view
        // hierarchy at all.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]

        // These arrive on the main thread already, so assumeIsolated avoids
        // spawning a Task per mouse move — at 120 Hz that would be thousands of
        // throwaway allocations a minute for a check that is usually a single
        // comparison.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }

        // The local one only matters while our own panel is frontmost, which is
        // rare — but without it the island can't tell the pointer has left
        // while the ask panel holds focus.
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    /// Cheapest branch first. A plain move can't affect the drop target, and
    /// that is the overwhelming majority of what arrives here.
    private func handle(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            evaluateHover()
        case .leftMouseDragged:
            evaluateHover()
        default:
            break
        }
    }

    private func triggerZone() -> CGRect {
        var zone = state.islandScreenRect(for: state.restingPresentation)
        zone = zone.insetBy(dx: -6, dy: 0)
        zone.size.height += 4
        return zone
    }

    /// Points per second since the previous mouse event.
    ///
    /// The distinction that matters is *passing through* versus *arriving*.
    /// A pointer crossing the top of the screen on its way to a menu bar item
    /// is moving fast; one you deliberately aimed at the notch slows down and
    /// stops. Speed separates them far better than a fixed delay, which has to
    /// be long enough for the first case and therefore feels sluggish for the
    /// second.
    private func pointerSpeed(at mouse: CGPoint) -> CGFloat {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastMouse = (mouse, now) }
        guard let previous = lastMouse else { return .greatestFiniteMagnitude }
        let elapsed = now - previous.at
        guard elapsed > 0.001 else { return 0 }
        return hypot(mouse.x - previous.point.x, mouse.y - previous.point.y) / elapsed
    }

    private func evaluateHover() {
        // An open panel doesn't hover — it waits.
        //
        // Moving the pointer off it shouldn't snatch it away mid-thought, but
        // leaving it up forever after someone has clearly moved on is its own
        // kind of rude. So: a couple of seconds outside, then it goes.
        if state.needsFocus {
            evaluatePanelIdle()
            return
        }
        cancelPanelIdle()

        // Meaningless in full screen too, where the window isn't on screen at
        // all: expanding it would set a state nobody can see, which then
        // arrives fully open the moment full screen ends. The hotkeys still
        // work, because those are asked for rather than wandered into.
        guard !state.isFullScreen else { return }

        let mouse = NSEvent.mouseLocation

        // Fast rejection: while closed, the island occupies a thin strip at the very
        // top of the screen. One comparison discards nearly every mouse event.
        if !state.isExpanded && mouse.y < state.hoverThresholdY {
            if expandWorkItem != nil {
                expandWorkItem?.cancel()
                expandWorkItem = nil
            }
            // Keep sampling position even down here. Without it the first
            // reading inside the zone has nothing to compare against and every
            // approach looks infinitely fast.
            lastMouse = (mouse, ProcessInfo.processInfo.systemUptime)
            return
        }

        let inside = state.isExpanded
            ? state.islandScreenRect(for: .expanded).insetBy(dx: -8, dy: -8).contains(mouse)
            : triggerZone().contains(mouse)

        if inside {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            guard !state.isExpanded, expandWorkItem == nil else { return }

            // Dwell: only open if the pointer is still there after a beat,
            // so sliding past the notch doesn't steal the menu bar.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.expandWorkItem = nil
                guard self.triggerZone().contains(NSEvent.mouseLocation) else { return }
                self.setExpanded(true)
            }
            let speed = pointerSpeed(at: mouse)
            let delay = speed < NotchGeometry.arrivalSpeed
                ? NotchGeometry.arrivalDelay      // arrived: open now
                : NotchGeometry.hoverDelay        // still travelling: wait

            expandWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)

        } else {
            expandWorkItem?.cancel()
            expandWorkItem = nil
            guard state.isExpanded, collapseWorkItem == nil else { return }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.collapseWorkItem = nil
                self.setExpanded(false)
            }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.isExpanded != expanded, !state.needsFocus else { return }
        // Hand the keyboard back when the island closes, if we took it.
        if !expanded, isKeyWindow { resignKey() }
        // Opening: key, without activating the app or re-ordering the
        // window. Liquid Glass only draws as glass in the key window — the
        // hover panel was a frosted blur until it was clicked (a click made
        // it key in `sendEvent`). Closing hands the key back, above.
        if expanded, !isKeyWindow { makeKey() }
        if expanded { repairStaleKey() }
        // Only capture the mouse while the island is actually on screen.
        // Closed, the panel must be completely transparent to clicks — a view
        // returning nil from hitTest swallows the event rather than
        // forwarding it, so ignoresMouseEvents is the only true pass-through.
        ignoresMouseEvents = !expanded
        // Deliberately NOT calling orderFrontRegardless() here. The panel is already
        // at statusBar+2 and was ordered front at launch; re-ordering a window mid
        // animation makes the window server re-composite it, which can drop a frame
        // and let the hardware notch show through.
        // No withAnimation here on purpose: NotchRootView owns the animation.
        // Driving the same frame change from two places compounds the springs
        // and is what produced the double-bounce.
        state.isExpanded = expanded
    }
}

extension Animation {
    /// The springy, slightly overshooting feel of the iPhone Dynamic Island.
    ///
    /// This used to be two animations — a spring outwards and a flat easeOut
    /// inwards — because a spring's undershoot on the way in drew the island
    /// smaller than the hardware notch and exposed its edges. `ClampedSize`
    /// puts a floor under the interpolated size, so the undershoot still
    /// happens mathematically and simply cannot be drawn. One animation again,
    /// and it bounces both ways.
    static var island: Animation {
        .spring(response: 0.36, dampingFraction: 0.68, blendDuration: 0.1)
    }
}
