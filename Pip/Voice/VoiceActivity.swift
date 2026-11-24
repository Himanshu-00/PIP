import Combine
import Foundation

/// What Pip's ears are doing, for the UI: whether he's listening, and how
/// loud the microphone is right now (0…1, smoothed) so he can react to your
/// voice as you speak.
@MainActor
final class VoiceActivity: ObservableObject {
    static let shared = VoiceActivity()

    @Published var isListening = false
    @Published private(set) var level: Double = 0
    /// The last moment the microphone heard a voice (loud enough to be
    /// speech, not room noise): hands-free waits for quiet from here too.
    private(set) var lastVoice = Date.distantPast

    private init() {}

    /// A new loudness reading from the microphone (RMS of one buffer).
    func heard(rms: Float) {
        // Speech RMS sits around 0.01–0.1; map that onto 0…1 on a log scale,
        // then ease towards it so the animation doesn't flicker.
        let db = 20 * log10(max(Double(rms), 1e-5))          // about −100…0
        let target = min(max((db + 50) / 40, 0), 1)           // −50 dB → 0, −10 dB → 1
        level += (target - level) * (target > level ? 0.6 : 0.25)
        if target > Self.speech { lastVoice = .now }
    }

    /// Louder than this (on the 0…1 scale above, about −38 dB) is someone talking.
    static let speech = 0.3

    func stopped() {
        isListening = false
        level = 0
    }
}

/// Root-mean-square loudness of a buffer of float samples (first channel).
func voiceRMS(_ samples: UnsafePointer<Float>, count: Int) -> Float {
    guard count > 0 else { return 0 }
    var sum: Float = 0
    var index = 0
    // Every 4th sample is plenty for a level meter.
    while index < count {
        sum += samples[index] * samples[index]
        index += 4
    }
    return (sum / Float((count + 3) / 4)).squareRoot()
}
