import AppKit
import Combine

/// Talk key → Pip listens → he answers aloud, and listens briefly if he
/// asked something. Typed questions are spoken too unless that's off.
@MainActor
final class VoiceController {

    let input = VoiceInput()
    let voice = PipVoice.shared

    private let agent: PetAgent
    private let search: SearchController
    private let openPip: () -> Void

    /// The current exchange was spoken, so the answer should be too.
    private var conversing = false
    private var waitingToSpeak = false
    private var cancellables = Set<AnyCancellable>()

    /// Listening or speaking — the panel shouldn't close itself meanwhile.
    var isBusy: Bool { input.isListening || voice.isSpeaking || waitingToSpeak || agent.awaitingSpeech }

    static let speaksKey = "pipSpeaksReplies"

    var speaksReplies: Bool {
        get { UserDefaults.standard.object(forKey: Self.speaksKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.speaksKey) }
    }

    static let speaksTypedKey = "pipSpeaksTypedReplies"

    var speaksTyped: Bool {
        get { UserDefaults.standard.object(forKey: Self.speaksTypedKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.speaksTypedKey) }
    }

    init(agent: PetAgent, search: SearchController, openPip: @escaping () -> Void) {
        self.agent = agent
        self.search = search
        self.openPip = openPip

        // A typed question: spoken questions have set this up already.
        agent.willAnswer = { [weak self] spoken in
            guard let self, self.speaksReplies, spoken || self.speaksTyped else { return }
            self.voice.stop()
            if KokoroEngine.isDownloaded { self.voice.prewarm() }
            self.waitingToSpeak = true
            if self.voice.canSpeak {
                self.agent.caption = nil
                self.agent.voiceSynced = true
            }
        }

        // Your words, live, in Pip's bar while you speak.
        input.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                MainActor.assumeIsolated {
                    guard let self, self.input.isListening, !text.isEmpty else { return }
                    // Your words beside Pip while you speak; the bar says "Listening…".
                    self.agent.showStatus(text)
                }
            }
            .store(in: &cancellables)

        input.onCommand = { [weak self] text in self?.heard(text) }
        input.vocabulary = { [weak self] in self?.agent.vocabulary() ?? [] }
        input.onNothingHeard = { [weak self] in
            guard let self else { return }
            self.agent.awaitingSpeech = false
            self.conversing = false
            self.search.query = ""
            // Say why, rather than silently going back to idle.
            if let problem = self.input.lastProblem, !problem.isEmpty {
                self.agent.showStatus(problem)
            } else {
                self.agent.showStatus(nil)
            }
        }

        // Speak the answer while it's still being written: each sentence goes
        // to the voice the moment it's complete.
        agent.$partial
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                MainActor.assumeIsolated {
                    guard let self, self.waitingToSpeak, self.speaksReplies,
                          let text, !text.isEmpty else { return }
                    self.streamed(text)
                }
            }
            .store(in: &cancellables)

        // When the answer is finished, say whatever hasn't been said yet.
        agent.$isThinking
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] thinking in
                MainActor.assumeIsolated {
                    guard let self, !thinking, self.waitingToSpeak else { return }
                    self.waitingToSpeak = false
                    self.finishSpeaking()
                }
            }
            .store(in: &cancellables)

        // A question that needs a yes or no is spoken too, and then he listens.
        agent.$confirmation
            .receive(on: RunLoop.main)
            .sink { [weak self] confirmation in
                MainActor.assumeIsolated {
                    guard let self, self.conversing, let question = confirmation?.question else { return }
                    self.say(question)
                }
            }
            .store(in: &cancellables)

        // The bubble writes each sentence out word by word as it's heard,
        // paced to the sentence's own length — text and voice together.
        voice.onSentenceStarted = { [weak self] sentence, duration in
            guard let self, self.agent.voiceSynced else { return }
            self.reveal(sentence, over: duration)
        }

        // A request that waited while he spoke goes once he's done — starting
        // it cut the answer being said short.
        agent.holdsQueue = { [weak self] in self?.voice.isSpeaking == true || self?.waitingToSpeak == true }

        // After speaking, listen for a reply.
        voice.onFinished = { [weak self] in
            guard let self else { return }
            self.unsync()
            self.agent.resumeQueue()
            // Not with the panel closed (a click elsewhere): no hidden microphone.
            guard self.conversing, self.search.isOpen else { return }
            // Only keep listening if Pip asked something — a question, or a
            // yes/no. Otherwise the exchange is over; ⌥V starts the next one.
            let reply = (self.agent.latest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.agent.confirmation != nil || reply.hasSuffix("?") else {
                self.conversing = false
                return
            }
            // A pause for the speaker to go quiet, then a tick, then the mic.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.conversing, !self.input.isListening else { return }
                NSSound(named: "Tink")?.play()
                ActivityLog.write(.voice, "listening for your answer")
                self.input.listenForCommand(endOnSilence: true, giveUpAfter: 10)
            }
        }
    }

    // MARK: - Talk key

    /// Press to talk; listening ends on a second press or ~2 s of quiet. While
    /// he thinks or speaks, a press stops him and listens for a new question.
    func talkPressed() {
        // Key repeat while it's held: one press.
        guard pressReleased else { return }
        pressReleased = false
        // Listening: this press is "I'm done".
        if input.isListening {
            ActivityLog.write(.voice, "talk key pressed again — done")
            settleThenRelease()
            return
        }
        // Still on the last question — thinking, or saying its answer: that
        // one stops, and this press is a new question (owner, 2026-11-22).
        // Before, it kept going and the new question waited behind it.
        if agent.isThinking || voice.isSpeaking || agent.voiceSynced {
            ActivityLog.write(.voice, "talk key pressed while answering — stopped that for a new question")
            stopAll()
            agent.cancel()
        }
        startListening()
    }

    private var pressReleased = true

    func talkReleased() {
        pressReleased = true
    }

    private func settleThenRelease() {
        // Your last words take a moment to settle: thinking dots meanwhile,
        // and the panel stays open. Cleared when the words arrive (or at
        // most 6 s, if nothing usable was heard).
        if input.isListening, !search.query.isEmpty {
            agent.awaitingSpeech = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if self?.agent.isThinking == false { self?.agent.awaitingSpeech = false }
            }
        }
        input.release()
    }

    private func startListening() {
        voice.stop()
        // The natural voice: fetched the first time you talk (about 330 MB,
        // once), and loaded while you're still speaking so the answer isn't
        // kept waiting.
        if speaksReplies {
            if KokoroEngine.isDownloaded { voice.prewarm() } else { voice.downloadNeuralVoice() }
        }
        Task {
            guard await VoiceInput.requestPermission() else {
                openPip()
                agent.showStatus("I need the microphone and speech recognition — allow them in System Settings ▸ Privacy & Security.")
                return
            }
            openPip()
            conversing = true
            search.query = ""
            // Clear the last answer; Pip (big, listening eyes) and the search
            // bar show he's listening — no extra line of text.
            agent.showStatus(nil)
            // Ends at the next press, or by itself after a pause.
            input.listenForCommand(endOnSilence: true)
            if !input.isListening {
                agent.showStatus("I couldn't start the microphone. Try again in a moment.")
            }
        }
    }

    // MARK: - The exchange

    private func heard(_ text: String) {
        defer { if !agent.isThinking { agent.awaitingSpeech = false } }
        // Nothing said, only punctuation (the recogniser sends "." for a
        // breath): not a question — it went to the brain as "." once.
        guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            ActivityLog.write(.voice, "heard nothing (\"\(text)\") — ignored")
            return
        }
        // "Um.", "Hmm" on its own: thinking aloud, not a request (a follow-up
        // listen sent "Um." to Pip, who answered it — 2026-11-21).
        let filler: Set<String> = ["um", "umm", "uh", "uhh", "hmm", "hm", "mm", "mmm", "er", "erm", "ah", "oh"]
        let spoken = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if !spoken.isEmpty, spoken.allSatisfy(filler.contains) {
            ActivityLog.write(.voice, "heard only \"\(text)\" — ignored")
            return
        }
        ActivityLog.write(.voice, "heard: \(text)")
        // What was said stays in the bar, greyed while Pip answers, like a
        // typed question (`PipView` clears it when he's done). Cleared here,
        // it vanished a second after you stopped talking.
        search.query = text
        // Answering a yes/no by voice.
        if agent.confirmation != nil {
            // Whole words, so "look" or "book" isn't heard as "ok".
            let lowered = text.lowercased()
            let words = Set(lowered.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
            let yes = !words.isDisjoint(with: ["yes", "yeah", "yep", "sure", "allow", "okay", "ok"])
                || lowered.contains("do it") || lowered.contains("go ahead")
            let no = !words.isDisjoint(with: ["no", "nope", "cancel", "don't", "dont", "stop"])
            if yes, !no { agent.answer(true) }
            else if no || words.count <= 2 { agent.answer(false) }
            else { agent.answer(instead: text) }   // an instruction, e.g. "select the colour first"
            return
        }
        // "Stop", "wait", "never mind" come first: they stop the answer being
        // made and anything waiting. Words after "stop"/"wait" are the new
        // request ("wait, check the PDF instead").
        let lowered = text.lowercased()
        let interrupts = ["stop", "wait", "cancel", "never mind", "nevermind", "that's all", "thats all", "goodbye", "bye"]
        if let word = interrupts.first(where: { lowered.hasPrefix($0) }) {
            let rest = String(text.dropFirst(word.count)).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            ActivityLog.write(.voice, "interrupted (\(word))" + (rest.isEmpty ? "" : " — then: \(rest)"))
            agent.stopEverything()
            voice.stop()
            if ["stop", "wait", "cancel"].contains(word), rest.split(separator: " ").count >= 2 {
                agent.send(rest, spoken: true)
            } else {
                conversing = false
                search.query = ""
                say("Okay!")
            }
            return
        }
        // Words and voice together: armed by `willAnswer` as it starts — now
        // or, if Pip is still busy, when its turn in the queue comes.
        agent.send(text, spoken: true)
    }

    // MARK: - Speaking as it streams

    /// The reply text streamed so far, and how many of its characters have
    /// already gone to the voice.
    private var streamText = ""
    private var streamOffset = 0
    private var streaming = false

    /// Letters of the sentence being spoken, shown as it's spoken.
    private var revealTask: Task<Void, Never>?
    /// The caption as it will be once the current sentence is fully shown.
    private var pendingFull: String?
    /// How often the caption steps on: 24 a second, a few letters a step —
    /// smooth to the eye, and each step is a redraw of the island.
    private static let revealTick: TimeInterval = 1.0 / 24

    /// Letter by letter, paced to the sentence's own length (owner,
    /// 2026-11-22: "letter by letter, smoother"; word by word before).
    private func reveal(_ sentence: String, over duration: TimeInterval) {
        // A new sentence started: the last one is finished — show it whole
        // before starting on this one.
        revealTask?.cancel()
        if let shown = pendingFull { agent.caption = shown }
        let base = agent.caption.map { $0 + " " } ?? ""
        pendingFull = base + sentence
        agent.captionAhead = pendingFull
        let letters = Array(sentence)
        guard letters.count > 1, duration > 0.3 else {
            agent.caption = base + sentence
            return
        }
        // Finish slightly ahead of the voice, so the text never lags it.
        let steps = max(1, min(letters.count, Int(duration * 0.92 / Self.revealTick)))
        let step = duration * 0.92 / Double(steps)
        revealTask = Task { @MainActor [weak self] in
            for index in 1 ... steps {
                guard let self, !Task.isCancelled, self.agent.voiceSynced else { return }
                let count = letters.count * index / steps
                self.agent.caption = base + String(letters.prefix(count))
                if index < steps {
                    try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                }
            }
        }
    }

    private func startStream() {
        voice.beginStream()
        streaming = true
        streamText = ""
        streamOffset = 0
        revealTask?.cancel()
        pendingFull = nil
        agent.caption = nil
        agent.captionAhead = nil
        if voice.canSpeak { agent.voiceSynced = true }
    }

    /// Back to showing the reply as written.
    private func unsync() {
        revealTask?.cancel()
        pendingFull = nil
        agent.voiceSynced = false
        agent.caption = nil
        agent.captionAhead = nil
    }

    private func streamed(_ text: String) {
        if !streaming { startStream() }
        // A new round of writing (after a tool ran) starts over; what was
        // already said stays said.
        if !text.hasPrefix(String(streamText.prefix(streamOffset))) { streamOffset = 0 }
        streamText = text
        let (sentences, offset) = PipVoice.completeSentences(in: text, from: streamOffset)
        sentences.forEach(voice.enqueue)
        streamOffset = offset
    }

    private func finishSpeaking() {
        let reply = agent.latest ?? ""
        guard streaming else {
            // Nothing streamed (an instant command): say the whole reply.
            guard !reply.isEmpty, voice.canSpeak else { unsync(); return }
            startStream()
            streaming = false
            PipVoice.sentences(reply).forEach(voice.enqueue)
            voice.endStream()
            return
        }
        streaming = false
        // The final reply usually continues what was streamed: say the rest.
        // If it doesn't (the answer changed after a tool ran), say it all.
        let spoken = String(streamText.prefix(streamOffset))
        let rest = Self.remainder(of: reply, after: spoken) ?? reply
        PipVoice.sentences(rest).forEach(voice.enqueue)
        voice.endStream()
    }

    /// What's left of `reply` once `spoken` has been said, comparing only
    /// the visible characters (the final reply may be trimmed differently
    /// from the streamed text). Nil if the reply doesn't start with it.
    private static func remainder(of reply: String, after spoken: String) -> String? {
        var index = reply.startIndex
        for character in spoken where !character.isWhitespace {
            while index < reply.endIndex, reply[index].isWhitespace { index = reply.index(after: index) }
            guard index < reply.endIndex, reply[index] == character else { return nil }
            index = reply.index(after: index)
        }
        return String(reply[index...])
    }

    private func say(_ text: String) {
        guard speaksReplies else { return }
        streaming = false
        voice.speak(text)
    }

    /// Esc, or the panel closing: stop everything.
    func stopAll() {
        conversing = false
        waitingToSpeak = false
        streaming = false
        unsync()
        voice.stop()
        input.cancel()
    }
}
