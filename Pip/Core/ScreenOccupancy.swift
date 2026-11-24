import AppKit
import ApplicationServices
import Combine

/// Is the app in front running full screen?
///
/// Four attempts at this were spent inferring the answer from window geometry,
/// and every one of them failed on the same rock: on a notched Mac a maximised
/// window and a letterboxed full-screen one are *identical*. Same width, same
/// height, top edge in the same place, both leaving a black strip where the
/// menu bar would be. No amount of measuring separates them, because there is
/// nothing there to measure.
///
/// macOS has simply been keeping the answer the whole time. Every window
/// carries an `AXFullScreen` attribute, and asking it is one call. It needs
/// Accessibility permission — which this app already asks for, because ⌥E
/// presses ⌘C and ⌘V for you and the media keys need it too. There was never a
/// reason to deduce something that could be read.
///
/// Everything here is scoped to *one display*. That was the other bug: the
/// first version asked whether the frontmost app was full screen and never
/// asked where. Put something full screen on an external monitor and the
/// MacBook's island would hide, for a film it wasn't covering.
///
/// So the window list narrows the question to the few processes that actually
/// own a window on the notched display, and Accessibility judges only those —
/// which is both correct and cheaper than interrogating every running app.
@MainActor
final class ScreenOccupancy: ObservableObject {

    @Published private(set) var isFullScreen = false

    /// Each signal separately, for the diagnostics.
    private(set) var accessibilitySaysFullScreen: Bool?
    private(set) var windowCovers = false

    private var observers: [Any] = []
    private var burst: [DispatchWorkItem] = []
    /// One check in flight at a time. The burst fires six times in two
    /// seconds; without this they overlap and interrogate every app at once.
    private var checking = false
    private var timer: Timer?
    private var islandWouldShow = false

    // MARK: - Lifecycle

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        refresh()
    }

    func stop() {
        cancelBurst()
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Polls only while the island has something to display.
    ///
    /// Entering full screen fires a notification; a game resizing a borderless
    /// window fires nothing. With nothing playing there is nothing to hide, and
    /// the timer doesn't exist.
    func setIslandWouldShow(_ shows: Bool) {
        guard shows != islandWouldShow else { return }
        islandWouldShow = shows
        syncPolling()
        scheduleRefresh()
    }

    /// Polls while the island has something to show *or* while it's currently
    /// hidden for full screen.
    ///
    /// That second condition is the one that was missing. With nothing
    /// playing there was no timer, so an app that went full screen before
    /// anything was playing left the island hidden with nothing watching for
    /// the exit — and if the notification was missed, it stayed hidden
    /// forever.
    private func syncPolling() {
        // Also polls while a "leaving" is pending, or the 0.8 s confirmation
        // can outlast the burst and nothing re-checks until the next poll.
        let wanted = islandWouldShow || isFullScreen || leavingSince != nil
        if wanted, timer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted {
            timer?.invalidate()
            timer = nil
        }
    }

    /// A burst of checks, not one.
    ///
    /// The notifications are the problem. `activeSpaceDidChange` arrives
    /// *after* the full-screen transition has finished animating, and
    /// `AXFullScreen` doesn't flip until the window has actually got there —
    /// so a single check at notification time is often still too early, and
    /// the next look was a two-second poll away. That gap is the "it stays for
    /// a few seconds and then vanishes" everyone can see.
    ///
    /// So the second after any transition is sampled densely and then left
    /// alone. Six checks, front-loaded, each one or two Accessibility calls in
    /// the common case — a rounding error against a full-screen animation, and
    /// the difference between the island going at the same moment as the
    /// window and going visibly late.
    private func scheduleRefresh() {
        cancelBurst()
        refresh()
        for delay in [0.08, 0.25, 0.5, 0.9, 1.4, 2.0, 2.8] {
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            burst.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelBurst() {
        burst.forEach { $0.cancel() }
        burst.removeAll()
    }

    // MARK: - Asking

    func refresh() {
        // Everything below talks to other processes, so none of it happens
        // here.
        //
        // `AXUIElementCopyAttributeValue` is synchronous IPC. If the app being
        // asked is busy — a browser mid-render, an app beachballing on its own
        // account — the call blocks until it answers or times out, and the
        // default timeout is measured in seconds. Doing that for a dozen apps,
        // six times in a burst, on the thread drawing the UI, is a beachball
        // with extra steps. It was mine.
        guard !checking else { return }
        checking = true

        Task.detached(priority: .utility) { [weak self] in
            let verdict = Self.evaluate()
            await self?.apply(verdict)
        }
    }

    private struct Verdict: Sendable {
        var hasNotchedScreen = true
        var windowCovers = false
        var accessibility: Bool?
    }

    private func apply(_ verdict: Verdict) {
        checking = false
        windowCovers = verdict.windowCovers
        accessibilitySaysFullScreen = verdict.accessibility

        // `AXFullScreen` decides, having been asked only about apps visible on
        // this display's current space.
        //
        // That pairing took several attempts. The attribute is right about
        // *whether* a window is full screen and wrong about *where and when* —
        // it stays true for a background space, whose window has identical
        // coordinates to the one in front. The window list is right about
        // where and when, and knows nothing about full screen. Neither is
        // correct alone, and every version that leaned on one of them broke in
        // the way the other would have caught.
        let full = verdict.hasNotchedScreen && (verdict.accessibility ?? false)

        // Hiding is immediate; showing again has to be earned.
        //
        // This is what the flicker was. Mid-transition the window list is
        // briefly empty — windows are moving between spaces and nothing is
        // settled — so a check landing in that gap reads "nothing visible,
        // therefore not full screen" and the island comes back for a frame
        // before the next check hides it again.
        //
        // The asymmetry is deliberate and matches the cost of being wrong.
        // Hiding late puts a widget on someone's film; showing late costs
        // half a second of an island nobody was looking at.
        if full {
            leavingSince = nil
            guard !isFullScreen else { return }
            isFullScreen = true
            syncPolling()
            return
        }

        guard isFullScreen else { leavingSince = nil; return }

        guard let since = leavingSince else {
            leavingSince = Date()
            return
        }
        guard Date().timeIntervalSince(since) >= 0.8 else { return }

        leavingSince = nil
        isFullScreen = false
        syncPolling()
    }

    /// When the checks first stopped saying "full screen".
    private var leavingSince: Date?

    /// Off the main thread, start to finish.
    private nonisolated static func evaluate() -> Verdict {
        // Locked to the display with the notch, and only that one. With the
        // lid closed there is no notch, so there is no island over anybody's
        // film and nothing to hide.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            return Verdict(hasNotchedScreen: false)
        }

        // Who is on the space in front of me?
        let visible = appsVisible(on: screen)
        guard !visible.isEmpty else {
            return Verdict(hasNotchedScreen: true, windowCovers: false, accessibility: false)
        }

        // Of those, is any full screen? `AXFullScreen` decides; the list above
        // only chose who to ask, and does so loosely on purpose.
        let ax = anyIsFullScreen(on: screen, pids: visible)
        return Verdict(hasNotchedScreen: true,
                       windowCovers: true,
                       // No Accessibility answer falls back to the strict
                       // geometry test, which only catches a window reaching
                       // the very top — something a maximised window can't do.
                       accessibility: ax ?? aWindowReachesTheTop(of: screen))
    }

    /// Processes with a window *visible on this display right now*.
    ///
    /// Deliberately a loose test, and the looseness is the point.
    ///
    /// `AXFullScreen` is the reliable part of this check — it identified every
    /// app correctly. Its one flaw is that it's also true for a window that is
    /// full screen on a *background* space, which on the same display has
    /// identical coordinates to the one in front. So the question this answers
    /// isn't "is something covering the screen" — that's what `AXFullScreen`
    /// is for — it's "is this app on the space I'm actually looking at".
    ///
    /// A window on a background space isn't in the on-screen list at all, so
    /// merely *appearing* here is the whole signal. Asking it to cover the
    /// display as well is what broke this twice: a strict geometric match
    /// fails for reasons that have nothing to do with the question — window
    /// shadows, letterboxing, a display arrangement where the notched screen
    /// isn't the coordinate origin — and each failure showed the island over
    /// somebody's film.
    ///
    /// Forty per cent overlap. Enough that a small floating window doesn't
    /// count, loose enough that nothing about how the window is drawn matters.
    private nonisolated static func appsVisible(on screen: NSScreen) -> [pid_t] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,
                                                     .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let target = cgFrame(of: screen)
        let area = target.width * target.height
        guard area > 0 else { return [] }
        let ours = ProcessInfo.processInfo.processIdentifier
        var found: [pid_t] = []

        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner != ours,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw)
            else { continue }

            let overlap = bounds.intersection(target)
            guard !overlap.isNull else { continue }
            guard overlap.width * overlap.height >= area * 0.4 else { continue }
            if !found.contains(owner) { found.append(owner) }
        }
        return found
    }

    /// Does any of these processes have a full-screen window on this display?
    ///
    /// Returns nil when Accessibility can't answer at all, so the caller can
    /// tell "no" from "don't know".
    ///
    /// Both routes to a window are tried, in this order, and the order is the
    /// fix for a regression: `AXFocusedWindow` works on Chromium apps where
    /// walking `AXWindows` does not list the full-screen window at all. Asking
    /// only the second way made Brave invisible to this check while the first
    /// way had been reporting it correctly.
    private nonisolated static func anyIsFullScreen(on screen: NSScreen, pids: [pid_t]) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }

        guard !pids.isEmpty else { return false }

        let target = cgFrame(of: screen)
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            // Without this, one unresponsive app stalls the whole check for
            // the default timeout — which is several seconds, and used to be
            // several seconds of the main thread. It's off the main thread
            // now, but a check that takes six seconds is still a check that
            // reports the wrong answer for six seconds.
            AXUIElementSetMessagingTimeout(app, 0.2)

            // The focused window only. Walking `AXWindows` is what broke
            // this: that list includes windows on *other spaces*, and a
            // full-screen window on a background space has identical
            // coordinates to one in front — so an app with a normal window
            // here and a full-screen window on some other space reported
            // full screen, and the island disappeared for good.
            //
            // An app's focused window is the one on the space it is currently
            // showing, which is exactly the question being asked. It was also
            // what worked before the walk was added.
            if let focused = copyElement(app, kAXFocusedWindowAttribute),
               isFullScreen(focused), isOn(target, focused) {
                return true
            }
        }
        return false
    }

    /// Is this window's centre on the given display?
    ///
    /// The whole point of the multi-monitor fix: a window being full screen
    /// says nothing about *where*, and hiding the MacBook's island for a film
    /// playing on an external monitor is the bug that produced this check.
    ///
    /// Missing geometry counts as "no".
    ///
    /// This used to err the other way, on the reasoning that a hidden island
    /// is recoverable by hovering where a visible one sits on someone's film.
    /// That reasoning stopped holding when the island began ordering itself
    /// off screen rather than collapsing: hovering can't bring back a window
    /// that isn't there, so a wrong "yes" now means the island is gone until
    /// something else changes. The cautious direction reversed with it.
    private nonisolated static func isOn(_ target: CGRect, _ window: AXUIElement) -> Bool {
        guard let frame = frameOf(window) else { return false }
        return target.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    private nonisolated static func copyElement(_ element: AXUIElement,
                                    _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast — guarded by the type check above.
        return (value as! AXUIElement)
    }

    private nonisolated static func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString,
                                            &value) == .success,
              let number = value as? NSNumber
        else { return false }
        return number.boolValue
    }

    /// Accessibility reports position and size as opaque `AXValue`s, in the
    /// same top-left coordinate space Core Graphics uses.
    private nonisolated static func frameOf(_ window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString,
                                            &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString,
                                            &sizeRef) == .success,
              let rawPosition = positionRef, let rawSize = sizeRef,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast — guarded by the type checks above.
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
        else { return nil }
        // swiftlint:enable force_cast
        return CGRect(origin: origin, size: size)
    }

    /// The fallback when Accessibility is unavailable: a window reaching y = 0
    /// on this display.
    ///
    /// Deliberately strict. A maximised window starts below the menu bar and a
    /// letterboxed one below the notch, so neither qualifies — this only
    /// catches apps that take the whole display, which is the most that can be
    /// known without asking macOS directly.
    private nonisolated static func aWindowReachesTheTop(of screen: NSScreen) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,
                                                     .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return false }

        let target = cgFrame(of: screen)
        let ours = ProcessInfo.processInfo.processIdentifier

        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner != ours,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw)
            else { continue }

            guard bounds.minY <= target.minY + 1,
                  bounds.width >= target.width - 2,
                  bounds.height >= target.height - 2
            else { continue }
            return true
        }
        return false
    }

    /// A screen's frame in Core Graphics coordinates.
    ///
    /// CG measures from the top-left of the primary display with y increasing
    /// downwards; AppKit from the bottom-left with y increasing up. Getting
    /// this backwards doesn't error — it compares windows against a rectangle
    /// somewhere off the bottom of the world and quietly finds nothing.
    private nonisolated static func cgFrame(of screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screen.frame }
        return CGRect(x: screen.frame.minX,
                      y: primary.frame.maxY - screen.frame.maxY,
                      width: screen.frame.width,
                      height: screen.frame.height)
    }

    // MARK: - Diagnostics

    var report: String {
        let ax: String
        switch accessibilitySaysFullScreen {
        case .some(true):  ax = "yes"
        case .some(false): ax = "no"
        case .none:        ax = AXIsProcessTrusted()
            ? "no answer"
            : "UNAVAILABLE — Accessibility not granted, so this falls back to guessing"
        }

        let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
        var lines = [
            "full screen on the notched display: \(isFullScreen)",
            "  displays: \(NSScreen.screens.count)",
            "  notched display: " + (notched.map {
                "\(Int($0.frame.width))×\(Int($0.frame.height)) at x \(Int($0.frame.minX))"
            } ?? "none — lid closed, nothing to hide"),
            "  frontmost app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")",
            "  apps visible on it: \(windowCovers ? "yes" : "no")",
            "  AXFullScreen on one of them: \(ax)",
            "  polling: \(timer != nil ? "yes" : "no")",
        ]

        // Per-app, because "AXFullScreen says no" isn't actionable without
        // knowing which apps were asked and what each one said.
        if let notched, AXIsProcessTrusted() {
            lines.append("")
            lines.append("  candidates:")
            let target = Self.cgFrame(of: notched)
            for pid in Self.appsVisible(on: notched).prefix(8) {
                let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                var verdict = "no full-screen window found"
                if let focused = Self.copyElement(app, kAXFocusedWindowAttribute) {
                    let full = Self.isFullScreen(focused)
                    let frame = Self.frameOf(focused)
                    let here = frame.map { target.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? true
                    verdict = "focused window: AXFullScreen=\(full), on this display=\(here)"
                    if let frame {
                        verdict += ", frame \(Int(frame.minX)),\(Int(frame.minY)) "
                            + "\(Int(frame.width))×\(Int(frame.height))"
                    }
                }
                lines.append("    \(name): \(verdict)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
