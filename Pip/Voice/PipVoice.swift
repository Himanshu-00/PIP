import AVFoundation

/// Pip's voice (Kokoro): a queue of sentences, each spoken as soon as it's
/// written, the next made while one plays. Quiet until downloaded.
@MainActor
final class PipVoice: ObservableObject {

    static let shared = PipVoice()

    @Published private(set) var isSpeaking = false
    /// How far the voice download has got, 0…1, while it's running.
    @Published private(set) var downloadProgress: Double?
    /// Called when everything queued has been spoken (not when cut off).
    var onFinished: (() -> Void)?
    /// Called with each sentence the moment its audio starts playing, so the
    /// words on screen can appear with the voice rather than ahead of it.
    var onSentenceStarted: ((String, TimeInterval) -> Void)?

    private let player = PCMPlayer()

    /// Which utterance is current; anything from an older one is ignored.
    private var utterance = 0
    /// Sentences waiting to be made into audio: as written, and as spoken.
    private var pending: [(text: String, clean: String)] = []
    /// Sentences whose audio is queued behind the one playing.
    private var waitingToStart: [(text: String, duration: TimeInterval)] = []
    private var working = false
    private var streamOpen = false
    private var buffersPlaying = 0
    /// This utterance so far, for one log line when it's done.
    private var saidSentences = 0
    private var saidSeconds = 0.0

    private init() {}

    var canSpeak: Bool { KokoroEngine.isDownloaded }

    // MARK: - Speaking

    /// Says a whole piece of text.
    func speak(_ text: String) {
        beginStream()
        for sentence in Self.sentences(text) { enqueue(sentence) }
        endStream()
    }

    /// Starts a new utterance that sentences will be added to as they arrive.
    func beginStream() {
        stop()
        saidSentences = 0
        saidSeconds = 0
        isSpeaking = true
        streamOpen = true
        if !canSpeak { downloadNeuralVoice() }
    }

    func enqueue(_ sentence: String) {
        guard canSpeak else { return }
        let clean = Self.speakable(sentence)
        guard clean.rangeOfCharacter(from: .alphanumerics) != nil else { return }
        pending.append((sentence, clean))
        work()
    }

    /// Nothing more is coming; finish once the queue has been spoken.
    func endStream() {
        streamOpen = false
        finishIfDone()
    }

    func stop() {
        utterance += 1
        pending = []
        waitingToStart = []
        working = false
        streamOpen = false
        buffersPlaying = 0
        player.stop()
        isSpeaking = false
    }

    /// Loads Kokoro ahead of time — called as soon as you start talking, so
    /// it's ready by the time there's an answer to say.
    func prewarm() {
        guard canSpeak else { return }
        Task.detached(priority: .userInitiated) { await KokoroEngine.shared.prewarm() }
    }

    /// Makes the next sentence into audio and queues it behind whatever is
    /// playing. One at a time, in order.
    private func work() {
        guard !working, !pending.isEmpty else { return }
        working = true
        let id = utterance
        let item = pending.removeFirst()
        Task { [weak self] in
            let samples: [Float]?
            do {
                samples = try await KokoroEngine.shared.synthesize(item.clean)
            } catch {
                ActivityLog.write(.error, "Kokoro failed: \(error.localizedDescription)")
                samples = nil
            }
            guard let self, self.utterance == id else { return }
            self.working = false
            if let samples, !samples.isEmpty {
                let duration = Double(samples.count) / KokoroEngine.sampleRate
                self.saidSentences += 1
                self.saidSeconds += duration
                let startsNow = self.buffersPlaying == 0
                self.buffersPlaying += 1
                let started = self.player.play(samples, sampleRate: KokoroEngine.sampleRate) { [weak self] in
                    Task { @MainActor in self?.bufferFinished(id) }
                }
                if !started {
                    self.buffersPlaying -= 1
                } else if startsNow {
                    self.onSentenceStarted?(item.text, duration)
                } else {
                    self.waitingToStart.append((item.text, duration))
                }
            }
            self.work()
            self.finishIfDone()
        }
    }

    private func bufferFinished(_ id: Int) {
        guard id == utterance else { return }
        buffersPlaying = max(0, buffersPlaying - 1)
        // The next queued sentence starts playing right as this one ends.
        if !waitingToStart.isEmpty {
            let next = waitingToStart.removeFirst()
            onSentenceStarted?(next.text, next.duration)
        }
        finishIfDone()
    }

    private func finishIfDone() {
        guard isSpeaking, !streamOpen, !working, pending.isEmpty, buffersPlaying == 0 else { return }
        isSpeaking = false
        if saidSentences > 0 {
            ActivityLog.write(.voice, String(format: "said %d sentence%@ (%.1fs of speech)", saidSentences,
                                             saidSentences == 1 ? "" : "s", saidSeconds))
        }
        // Let go of the speaker, so the microphone session that follows
        // starts on a quiet, free audio device.
        player.stop()
        onFinished?()
    }

    // MARK: - Text

    /// Text as it should be read aloud: no markdown, paths, symbols or ID-like
    /// names; dates and percentages spelt out (see `-voiceCheck`).
    nonisolated static func speakable(_ text: String) -> String {
        var clean = text
        for mark in ["**", "__", "`", "#", "*"] { clean = clean.replacingOccurrences(of: mark, with: "") }
        clean = clean.replacingOccurrences(of: #"/Users/[^\s]+/"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "—", with: ", ")
        clean = clean.replacingOccurrences(of: "→", with: " to ").replacingOccurrences(of: "%", with: " percent")
        // Emoji ("✈️", "🛫") were read as "ex".
        clean = String(clean.filter { character in
            !character.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
        })
        // Web addresses: "google dot com".
        clean = clean.replacingOccurrences(of: #"\b(?:https?://)?(?:www\.)?([A-Za-z0-9-]+)\.(com|org|net|io|gov|edu|au|in)(?:\.(au|in|uk))?\b[^\s]*"#,
                                           with: "$1 dot $2", options: [.regularExpression, .caseInsensitive])
        // File names: "Ticket PDF"; names that are mostly an ID: "the PDF file".
        let kinds = "pdf|docx?|xlsx?|pptx?|txt|csv|md|html?|json|zip|png|jpe?g|heic|gif|mp4|mov|plist|command|dmg|pkg"
        if let regex = try? NSRegularExpression(pattern: #"\b([\w][\w ()-]*?)\.("# + kinds + #")\b"#, options: .caseInsensitive) {
            let ns = clean as NSString
            var out = ""
            var last = 0
            for match in regex.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let stem = ns.substring(with: match.range(at: 1))
                let kind = ns.substring(with: match.range(at: 2)).uppercased()
                let digits = stem.filter(\.isNumber).count
                out += digits >= 6 ? "the \(kind) file"
                    : stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ") + " " + kind
                last = match.range.location + match.range.length
            }
            clean = out + ns.substring(from: last)
        }
        clean = spokenTimes(clean)
        // Day and month names, next to a number as tickets write them.
        for (short, long) in shortDates {
            clean = clean.replacingOccurrences(of: #"\b"# + short + #"\b(?=,?\s*\d)|(?<=\d )"# + short + #"\b"#,
                                               with: long, options: .regularExpression)
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clock times as said aloud: "4:07 AM" → "4 oh 7 A M".
    nonisolated static func spokenTimes(_ text: String) -> String {
        let pattern = #"\b(\d{1,2})(?::(\d{2}))?\s*(?:([AaPp])\.?\s?[Mm]\.?(?![A-Za-z]))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let hasMinutes = match.range(at: 2).location != NSNotFound
            let hasHalf = match.range(at: 3).location != NSNotFound
            guard hasMinutes || hasHalf else { continue }   // a plain number
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            var spoken = ns.substring(with: match.range(at: 1))
            if hasMinutes {
                let minutes = ns.substring(with: match.range(at: 2))
                if minutes == "00" { spoken += hasHalf ? "" : " hundred" }
                else if minutes.hasPrefix("0") { spoken += " oh " + String(minutes.dropFirst()) }
                else { spoken += " " + minutes }
            }
            if hasHalf { spoken += ns.substring(with: match.range(at: 3)).lowercased() == "a" ? " A M" : " P M" }
            // Keep a space after it if the match ate one before the next word.
            let matched = ns.substring(with: match.range)
            // ...and the full stop, when "AM." / "p.m." also ended the sentence.
            out += spoken + (matched.hasSuffix(".") ? "." : "") + (matched.hasSuffix(" ") ? " " : "")
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }

    nonisolated private static let shortDates: [(String, String)] = [
        ("Mon", "Monday"), ("Tue", "Tuesday"), ("Tues", "Tuesday"), ("Wed", "Wednesday"), ("Thu", "Thursday"),
        ("Thur", "Thursday"), ("Thurs", "Thursday"), ("Fri", "Friday"), ("Sat", "Saturday"), ("Sun", "Sunday"),
        ("Jan", "January"), ("Feb", "February"), ("Mar", "March"), ("Apr", "April"), ("Jun", "June"),
        ("Jul", "July"), ("Aug", "August"), ("Sep", "September"), ("Sept", "September"), ("Oct", "October"),
        ("Nov", "November"), ("Dec", "December"),
    ]

    /// Sentence-sized pieces. Very long sentences are split at commas to stay
    /// well inside what the model takes at once.
    nonisolated static func sentences(_ text: String) -> [String] {
        var pieces: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { piece, _, _, _ in
            guard let piece = piece?.trimmingCharacters(in: .whitespacesAndNewlines), !piece.isEmpty else { return }
            pieces.append(piece)
        }
        if pieces.isEmpty { pieces = [text] }
        return pieces.flatMap(splitLong)
    }

    /// The sentences in `text`, after the first `offset` characters, that are
    /// definitely finished — ended with . ! or ? and followed by more text.
    /// Returns them and the new offset. For speaking a reply as it streams.
    static func completeSentences(in text: String, from offset: Int) -> (sentences: [String], offset: Int) {
        guard offset < text.count else { return ([], offset) }
        let start = text.index(text.startIndex, offsetBy: offset)
        var found: [String] = []
        var consumed = offset
        text.enumerateSubstrings(in: start..<text.endIndex,
                                 options: [.bySentences, .localized]) { piece, _, enclosing, stop in
            guard let piece else { return }
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard enclosing.upperBound < text.endIndex,
                  let last = trimmed.last, ".!?…:".contains(last) else {
                stop = true
                return
            }
            found.append(contentsOf: splitLong(trimmed))
            consumed = text.distance(from: text.startIndex, to: enclosing.upperBound)
        }
        return (found, consumed)
    }

    nonisolated private static func splitLong(_ sentence: String) -> [String] {
        guard sentence.count > 220 else { return [sentence] }
        var parts: [String] = []
        var current = ""
        for clause in sentence.components(separatedBy: ", ") {
            if !current.isEmpty, current.count + clause.count > 200 {
                parts.append(current)
                current = clause
            } else {
                current = current.isEmpty ? clause : current + ", " + clause
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - Download and voices

    func downloadNeuralVoice() {
        guard downloadProgress == nil, !KokoroEngine.isDownloaded else { return }
        downloadProgress = 0
        Task { [weak self] in
            do {
                try await KokoroEngine.shared.download { fraction in
                    Task { @MainActor in self?.downloadProgress = fraction }
                }
                self?.downloadProgress = nil
            } catch {
                ActivityLog.write(.error, "voice download failed: \(error.localizedDescription)")
                self?.downloadProgress = nil
            }
        }
    }

    /// Picks a voice, fetching it first if needed, then says hello in it.
    func pickNeuralVoice(_ id: String) {
        Task { [weak self] in
            do {
                try await KokoroEngine.shared.fetchVoice(id)
                KokoroEngine.voiceID = id
                self?.speak("Hi! This is how I sound now.")
            } catch {
                ActivityLog.write(.error, "couldn't fetch voice \(id): \(error.localizedDescription)")
            }
        }
    }
}

/// Plays raw samples. A fresh audio engine per utterance: the microphone
/// session that runs between replies can change the audio route, and an
/// engine started before that won't play afterwards.
@MainActor
final class PCMPlayer {

    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?

    /// Queues samples after anything already playing. False if audio couldn't start.
    func play(_ samples: [Float], sampleRate: Double, finished: @escaping @Sendable () -> Void) -> Bool {
        guard let node = ready(sampleRate: sampleRate), let format else { return false }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in finished() }
        if !node.isPlaying { node.play() }
        return true
    }

    func stop() {
        node?.stop()
        engine?.stop()
        if let engine, let node { engine.detach(node) }
        node = nil
        engine = nil
    }

    private func ready(sampleRate: Double) -> AVAudioPlayerNode? {
        if let engine, engine.isRunning, let node, format?.sampleRate == sampleRate { return node }
        stop()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            ActivityLog.write(.error, "speaker failed to start: \(error.localizedDescription)")
            return nil
        }
        self.engine = engine
        self.node = node
        self.format = format
        return node
    }
}
