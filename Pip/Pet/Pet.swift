import Foundation
import SwiftUI

/// A creature whose mood is derived from the Mac (battery, music, heat),
/// never simulated on a timer.
@MainActor
final class Pet: ObservableObject {

    enum Mood: Equatable {
        case idle
        case happy
        case sleepy
        case hungry
        case eating
        case dancing
        case stressed
        case celebrating
        case thinking
        case talking
    }

    @Published private(set) var mood: Mood = .idle
    /// One short line, shown beside it in the hover panel.
    @Published private(set) var line = "Hi! Click me if you need anything."
    @Published var name: String {
        didSet { UserDefaults.standard.set(name, forKey: Self.nameKey) }
    }
    let born: Date

    // MARK: - Inputs

    private var batteryPercent = 100
    private var pluggedIn = true
    private var musicPlaying = false
    private var runningHot = false
    private var agentBusy = false
    private var agentSpeaking = false

    /// A short-lived reaction that outranks the steady moods for a few
    /// seconds — a download landing, being fed, a reminder going off.
    private var moment: (mood: Mood, line: String)?
    private var momentTask: Task<Void, Never>?

    private static let nameKey = "petName"
    private static let bornKey = "petBorn"

    init() {
        let defaults = UserDefaults.standard
        name = defaults.string(forKey: Self.nameKey) ?? "Pip"
        if let stored = defaults.object(forKey: Self.bornKey) as? Date {
            born = stored
        } else {
            born = .now
            defaults.set(born, forKey: Self.bornKey)
        }
        recompute()
    }

    // MARK: - Updates from the Mac

    func setBattery(percent: Int, pluggedIn: Bool) {
        let wasHungry = isHungry
        let wasPlugged = self.pluggedIn
        batteryPercent = percent
        self.pluggedIn = pluggedIn
        // Plugging in while hungry is feeding it.
        if wasHungry, pluggedIn, !wasPlugged {
            react(.eating, "Nom nom… thanks for the charge!")
        }
        recompute()
    }

    func setMusic(playing: Bool) { musicPlaying = playing; recompute() }
    func setRunningHot(_ hot: Bool) { runningHot = hot; recompute() }

    func setAgent(busy: Bool) { agentBusy = busy; recompute() }
    func setAgent(speaking: Bool) { agentSpeaking = speaking; recompute() }

    /// Re-evaluates time-of-day moods. Called when it comes into view rather
    /// than on a timer: nobody can see it change while the panel is closed.
    func refresh() { recompute() }

    /// A brief reaction to something that just happened.
    func react(_ mood: Mood, _ line: String, for seconds: Double = 4) {
        moment = (mood, line)
        recompute()
        momentTask?.cancel()
        momentTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.moment = nil
            self?.recompute()
        }
    }

    // MARK: - Mood

    private var isHungry: Bool { batteryPercent <= 20 && !pluggedIn }

    private var isLate: Bool {
        let hour = Calendar.current.component(.hour, from: .now)
        return hour >= 0 && hour < 6
    }

    /// Highest priority first. A creature can only look one way at a time, so
    /// the order is the whole design: talking to you beats everything, a low
    /// battery beats music, music beats sleepiness.
    private func recompute() {
        let next: (Mood, String)
        if agentBusy {
            next = (.thinking, "Hmm, let me think…")
        } else if agentSpeaking {
            next = (.talking, line)
        } else if let moment {
            next = (moment.mood, moment.line)
        } else if isHungry {
            next = (.hungry, "I'm hungry… \(batteryPercent)% left. Plug me in?")
        } else if runningHot {
            next = (.stressed, "Phew, it's getting hot in here.")
        } else if musicPlaying {
            next = (.dancing, "This one's a bop!")
        } else if isLate {
            next = (.sleepy, "It's late… zzz")
        } else {
            next = (.idle, idleLine)
        }
        if mood != next.0 { mood = next.0 }
        if line != next.1 { line = next.1 }
    }

    private var idleLine: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 6..<12:  return "Good morning! Need anything?"
        case 12..<18: return "Click me if you need a hand."
        default:      return "Evening! What are we doing?"
        }
    }

    /// Lets the agent set what it says without fighting the mood logic.
    func say(_ text: String) {
        line = text
        agentSpeaking = true
        recompute()
        speakingTask?.cancel()
        speakingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.agentSpeaking = false
            self?.recompute()
        }
    }

    private var speakingTask: Task<Void, Never>?
}
