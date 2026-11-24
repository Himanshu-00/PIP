#if DEBUG
import Foundation

/// What Pip's voice says, word by word (DEBUG, `-voiceCheck YES`), written
/// to `voice-check.txt`; unknown words marked `!!`, guessed ones `??`.
enum VoiceCheck {

    private static let hard = [
        "Your flight departs on Mon, 3 Mar 2025 at 09:45 from Terminal 1.",
        "Found 12 — top match: Ticket.pdf. Click one to open it.",
        "You paid AUD 120.75 by card ending 0000, and $1,250 in fees.",
        "I've opened Calculator; it's on the left, and don't worry — it's Pip's job.",
        "The e-ticket says SYD → SIN → LHR, booking ref ABC123. ✈️",
        "Timer set for 5 minutes — tea. Volume set to 40%.",
        "It's Saturday, 1 March 2025 at 4:07 AM.",
        "The meeting is at 9 PM, and the bus leaves at 6:15am or 7 p.m.",
    ]

    static func run() {
        let folder = AppFolders.logs
        let logs = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("activity-") }.sorted { $0.path > $1.path }
        var replies: [String] = []
        for log in logs {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") where line.contains("  REPLY    ") {
                let reply = String(line.components(separatedBy: "  REPLY    ").last ?? "")
                    .replacingOccurrences(of: " ⏎ ", with: "\n")
                if !reply.hasSuffix("…"), !replies.contains(reply) { replies.append(reply) }
            }
            if replies.count >= 40 { break }
        }

        guard let g2p = try? G2PFactory.createG2PProcessor(engine: .misaki) else {
            ActivityLog.write(.voice, "voice check: G2P didn't start")
            return
        }
        var report = ""
        var words = 0, empty = 0, guessed = 0
        MLXGate.lock.lock()
        defer { MLXGate.lock.unlock() }
        try? g2p.setLanguage(.enUS)
        for text in hard + replies.prefix(40) {
            for sentence in PipVoice.sentences(text) {
                let clean = PipVoice.speakable(sentence)
                guard let (phonemes, tokens) = try? g2p.process(input: clean) else { continue }
                report += "\n> \(clean)\n  \(phonemes)\n"
                for token in tokens ?? [] where token.text.rangeOfCharacter(from: .alphanumerics) != nil {
                    words += 1
                    let said = token.phonemes ?? ""
                    if said.isEmpty || said.contains("❓") {
                        empty += 1
                        report += "  !! \(token.text) → \(said.isEmpty ? "(nothing)" : said)\n"
                    } else if token.`_`.rating == 1 {
                        guessed += 1
                        report += "  ?? \(token.text) → \(said)\n"
                    }
                }
            }
        }
        let file = folder.appendingPathComponent("voice-check.txt")
        try? report.write(to: file, atomically: true, encoding: .utf8)
        ActivityLog.write(.voice, "voice check: \(words) words, \(empty) silent or unknown, \(guessed) guessed — \(file.path)")
    }
}
#endif
