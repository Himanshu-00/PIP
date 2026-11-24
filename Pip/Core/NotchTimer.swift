import AppKit

/// A countdown in the notch, like the iPhone's Dynamic Island timer.
///
/// Closed, the island shows a timer glyph and the time left; hovering shows
/// a row with Pause/Resume and Cancel; at zero it flashes and chimes.
/// Started by typing or saying "timer 10 min" to Pip (`QuickCommands`, no
/// model), or through Pip's `timer` tool for anything phrased differently.
///
/// Nothing ticks here. The end is one scheduled work item, and the countdown
/// text is SwiftUI's `Text(timerInterval:)`, which the system redraws once a
/// second on its own — no timer of ours, no `TimelineView` (see CLAUDE.md:
/// idle cost ≈ 0).
@MainActor
final class NotchTimer {

    static let shared = NotchTimer()

    private weak var state: NotchState?
    private var finish: DispatchWorkItem?
    private(set) var label: String?
    /// The length it was started with, for the row's title.
    private(set) var length: TimeInterval = 0

    /// Called at zero, with the label.
    var onFinished: ((String?) -> Void)?
    /// Called whenever it starts, pauses, resumes or stops.
    var onChange: (() -> Void)?

    private init() {}

    func attach(_ state: NotchState) { self.state = state }

    var isRunning: Bool { state?.timerEnd != nil }
    var isPaused: Bool { state?.timerPausedLeft != nil }
    var isActive: Bool { isRunning || isPaused }

    /// Seconds left, running or paused.
    var remaining: TimeInterval {
        if let end = state?.timerEnd { return max(0, end.timeIntervalSinceNow) }
        return state?.timerPausedLeft ?? 0
    }

    // MARK: - Controls

    func start(seconds: TimeInterval, label: String? = nil) {
        guard let state, seconds >= 1 else { return }
        finish?.cancel()
        self.label = label.flatMap { $0.isEmpty ? nil : $0 }
        length = seconds
        state.timerPausedLeft = nil
        state.timerEnd = Date().addingTimeInterval(seconds)
        schedule(seconds)
        ActivityLog.write(.system, "timer: \(Self.spoken(seconds))\(self.label.map { " — \($0)" } ?? "")")
        onChange?()
    }

    func pause() {
        guard let state, let end = state.timerEnd else { return }
        finish?.cancel()
        state.timerPausedLeft = max(1, end.timeIntervalSinceNow)
        state.timerEnd = nil
        onChange?()
    }

    func resume() {
        guard let state, let left = state.timerPausedLeft else { return }
        state.timerPausedLeft = nil
        state.timerEnd = Date().addingTimeInterval(left)
        schedule(left)
        onChange?()
    }

    func add(seconds: TimeInterval) {
        guard let state else { return }
        if let end = state.timerEnd {
            let left = end.timeIntervalSinceNow + seconds
            length += seconds
            state.timerEnd = Date().addingTimeInterval(left)
            finish?.cancel()
            schedule(left)
        } else if let left = state.timerPausedLeft {
            length += seconds
            state.timerPausedLeft = left + seconds
        } else {
            start(seconds: seconds, label: label)
            return
        }
        onChange?()
    }

    func cancel() {
        finish?.cancel()
        finish = nil
        state?.timerEnd = nil
        state?.timerPausedLeft = nil
        label = nil
        onChange?()
    }

    private func schedule(_ seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.ring() }
        }
        finish = work
        // Wall time: `DispatchTime` stops while the Mac sleeps, so a timer
        // that ran out during sleep would ring late while showing 0:00.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds, execute: work)
    }

    private func ring() {
        let finishedLabel = label
        finish = nil
        state?.timerEnd = nil
        state?.timerPausedLeft = nil
        label = nil
        ActivityLog.write(.system, "timer done\(finishedLabel.map { " — \($0)" } ?? "")")
        onFinished?(finishedLabel)
        onChange?()
    }

    // MARK: - Words

    /// "10 min", "1 hr 30 min", "45 sec".
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hr") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if secs > 0, hours == 0 { parts.append("\(secs) sec") }
        return parts.isEmpty ? "0 sec" : parts.joined(separator: " ")
    }

    /// Seconds in "10 min", "1 hour 30 minutes", "1h30", "90s", "half an
    /// hour", or a bare "10" (minutes). Nil when there's no duration.
    static func duration(in text: String) -> TimeInterval? {
        let lowered = text.lowercased()
        if lowered.contains("half an hour") || lowered.contains("half hour") { return 1800 }
        if lowered.contains("quarter of an hour") || lowered.contains("quarter hour") { return 900 }
        guard let regex = try? NSRegularExpression(
            pattern: #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)?(?![a-z])"#) else { return nil }
        var total: TimeInterval = 0
        var found = false
        for match in regex.matches(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) {
            guard let numberRange = Range(match.range(at: 1), in: lowered),
                  let number = Double(lowered[numberRange]) else { continue }
            let unit = Range(match.range(at: 2), in: lowered).map { String(lowered[$0]) } ?? ""
            switch unit.first {
            case "h": total += number * 3600
            case "s": total += number
            case "m": total += number * 60
            default:
                // A bare number after hours ("1h30") is minutes; alone, minutes too.
                total += number * 60
            }
            found = true
        }
        return found && total >= 1 && total <= 24 * 3600 ? total : nil
    }
}
