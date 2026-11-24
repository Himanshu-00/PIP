@preconcurrency import AVFoundation
import CoreAudio
import Speech

/// Listening with Apple's on-device speech recogniser (the fallback when
/// `ModernSpeech` isn't available).
@MainActor
final class VoiceInput: ObservableObject {

    @Published private(set) var isListening = false {
        didSet {
            if isListening { VoiceActivity.shared.isListening = true } else { VoiceActivity.shared.stopped() }
        }
    }

    /// The microphone's loudness, for Pip to react to (audio thread → main).
    nonisolated private static func report(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let rms = voiceRMS(channel, count: Int(buffer.frameLength))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard VoiceActivity.shared.isListening else { return }
                VoiceActivity.shared.heard(rms: rms)
            }
        }
    }
    @Published private(set) var transcript = ""
    /// Why the last attempt heard nothing, in words for the bubble. Nil when
    /// it simply heard silence.
    private(set) var lastProblem: String?

    /// The finished command.
    var onCommand: ((String) -> Void)?
    /// Listening ended with nothing said.
    var onNothingHeard: (() -> Void)?

    /// A fresh engine for every session. Reusing one across sessions broke
    /// after Pip had spoken: playing audio can change the audio route, and
    /// an engine started before that refuses to start again.
    private var engine: AVAudioEngine?
    /// The current session, so a cancelled one's late error can't end the next.
    private var session = 0
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// Words to expect, read as each session starts: names from the
    /// conversation and your files (a city name was heard as a brand,
    /// "latest" as "letters"). Set by VoiceController.
    var vocabulary: (() -> [String])?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var giveUpTimer: Task<Void, Never>?

    /// The newer speech model's session (macOS 26), when it's in use for
    /// this command. Typed loosely because the class only exists there.
    private var modern: AnyObject?

    init() {
        // Fetch the newer speech model in the background, once.
        if #available(macOS 26.0, *) {
            Task.detached(priority: .utility) { await ModernSpeech.prepare() }
        }
    }


    // MARK: - Permission

    static func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && microphone
    }

    // MARK: - Commands

    /// Starts listening. `endOnSilence`: finish after a pause; `giveUpAfter`:
    /// stop if nothing is said in this long.
    func listenForCommand(endOnSilence: Bool, giveUpAfter: TimeInterval? = nil) {
        stopSession()
        transcript = ""
        lastProblem = nil
        awaitingFinal = false
        endsOnSilence = endOnSilence
        guard startSession() else { isListening = false; return }
        isListening = true
        // Generous until the first word: people take a moment to answer, and
        // the recogniser takes a moment to report. With a give-up time set,
        // that does the waiting instead.
        if endOnSilence, giveUpAfter == nil { armSilence(seconds: 5) }
        if let giveUpAfter {
            giveUpTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(giveUpAfter * 1_000_000_000))
                guard !Task.isCancelled, let self, self.transcript.isEmpty else { return }
                self.finishCommand()
            }
        }
    }

    private var endsOnSilence = false
    private var awaitingFinal = false
    /// Quiet that ends a hands-free request. 1.7 s cut people off while
    /// they thought of the next word.
    private static let pause: TimeInterval = 2.2

    /// The talk key was let go: stop the microphone, then give the recogniser
    /// a moment to settle the last word before using the words.
    func release() {
        guard isListening, !awaitingFinal else { return }
        awaitingFinal = true
        silenceTimer?.cancel()
        if let engine, engine.isRunning { engine.stop() }
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // The new model reports when the last words are in (see modernEnded);
        // this is only a backstop.
        let settle: UInt64 = modern == nil ? 700_000_000 : 1_500_000_000
        if #available(macOS 26.0, *), let modern = modern as? ModernSpeech { modern.finish() }
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: settle)
            guard !Task.isCancelled else { return }
            self?.finishCommand()
        }
    }

    /// The key was let go.
    func finishCommand() {
        guard isListening else { return }
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopSession()
        isListening = false
        if words.isEmpty { onNothingHeard?() } else { onCommand?(words) }
    }

    func cancel() {
        stopSession()
        isListening = false
    }

    // MARK: - Session

    private func startSession() -> Bool {
        // The newer speech model when it's ready.
        if #available(macOS 26.0, *), startModernSession() { return true }
        guard let recognizer, recognizer.isAvailable else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        request.contextualStrings = hints()
        self.request = request
        guard let engine = Self.makeEngine(noiseReduction: true, tap: { buffer in
            request.append(buffer)
            Self.report(buffer)
        }) else {
            ActivityLog.write(.error, "the microphone wouldn't start")
            return false
        }
        self.engine = engine
        let format = engine.inputNode.outputFormat(forBus: 0)

        session += 1
        let id = session
        ActivityLog.write(.voice, "listening (on-device: \(request.requiresOnDeviceRecognition), mic: \(format))")
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let problem = error.map { error -> String in
                let ns = error as NSError
                ActivityLog.write(.error, "recognition error \(ns.domain) \(ns.code): \(ns.localizedDescription)")
                return Self.explain(ns)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Results from a session that has since been replaced are ignored.
                    guard let self, id == self.session else { return }
                    if let problem { self.lastProblem = problem }
                    self.handle(text: text, isFinal: isFinal, failed: problem != nil)
                }
            }
        }
        return true
    }

    @available(macOS 26.0, *)
    private func startModernSession() -> Bool {
        let id = session + 1
        // Results arrive off the main thread; ones from a session that has
        // since been replaced are dropped.
        let onText: @Sendable (String) -> Void = { [weak self] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, id == self.session else { return }
                    self.handleModern(text)
                }
            }
        }
        let onEnd: @Sendable (Error?) -> Void = { [weak self] error in
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, id == self.session else { return }
                    self.modernEnded(message)
                }
            }
        }
        guard let speech = ModernSpeech(onText: onText, onEnd: onEnd, hints: hints()) else { return false }
        guard let engine = Self.makeEngine(noiseReduction: true, tap: { buffer in
            speech.append(buffer)
            Self.report(buffer)
        }) else {
            ActivityLog.write(.error, "the microphone wouldn't start")
            speech.cancel()
            return false
        }
        session = id
        self.engine = engine
        modern = speech
        ActivityLog.write(.voice, "listening with the new speech model")
        return true
    }

    /// The vocabulary for this session, at most 100 (Apple's advice for
    /// contextual strings), logged so a mishearing can be traced.
    private func hints() -> [String] {
        let words = Array((vocabulary?() ?? []).prefix(100))
        if !words.isEmpty {
            ActivityLog.write(.voice, "hints: \(words.count) words (\(words.prefix(8).joined(separator: ", "))…)")
        }
        return words
    }

    private func handleModern(_ text: String) {
        guard isListening else { return }
        transcript = text.trimmingCharacters(in: .whitespaces)
        if endsOnSilence, !transcript.isEmpty { armSilence(seconds: Self.pause) }
    }

    /// Times in a row the new model heard nothing while the key was held.
    private var modernEmptyRuns = 0

    /// `error` is nil when it ended normally.
    private func modernEnded(_ error: String?) {
        guard isListening else { return }
        if let error {
            // Don't keep using a model that fails: back to the old recogniser.
            ActivityLog.write(.error, "new speech model error: \(error) — switching back to the old recogniser")
            if #available(macOS 26.0, *) { ModernSpeech.broken = true }
            if transcript.isEmpty, !awaitingFinal {
                // Still listening (the key is held): carry on with the old
                // recogniser right away rather than losing this press.
                listenForCommand(endOnSilence: endsOnSilence)
                return
            }
            if transcript.isEmpty { lastProblem = "I missed that — hold ⌥V and try again." }
            finishCommand()
            return
        }
        guard awaitingFinal else { return }
        if transcript.isEmpty {
            modernEmptyRuns += 1
            ActivityLog.write(.voice, "new speech model heard nothing (\(modernEmptyRuns) in a row)")
            if modernEmptyRuns >= 2, #available(macOS 26.0, *) {
                ActivityLog.write(.voice, "switching back to the old recogniser")
                ModernSpeech.broken = true
            }
        } else {
            modernEmptyRuns = 0
        }
        finishCommand()
    }

    // MARK: - Microphone, with the Mac's own noise reduction

    /// Offers macOS's Mic Mode picker once (Voice Isolation), when available.
    private static func offerVoiceIsolation() {
        let mode = AVCaptureDevice.preferredMicrophoneMode
        let name = mode == .voiceIsolation ? "voice isolation" : mode == .wideSpectrum ? "wide spectrum" : "standard"
        ActivityLog.write(.voice, "mic mode: \(name)")
        let key = "pipOfferedVoiceIsolation"
        guard mode != .voiceIsolation, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        ActivityLog.write(.voice, "mic mode: opened the picker so Voice Isolation can be chosen")
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    /// Use Apple's voice processing on the microphone: background-noise
    /// suppression, echo cancellation and automatic level — the same
    /// processing FaceTime uses. On by default; a menu item turns it off.
    static var reducesNoise: Bool {
        get { UserDefaults.standard.object(forKey: "pipReducesNoise") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pipReducesNoise") }
    }

    /// A running mic engine (one channel), voice processing first, without if
    /// refused.
    private static func makeEngine(noiseReduction: Bool,
                                   tap: @escaping (AVAudioPCMBuffer) -> Void) -> AVAudioEngine? {
        // Bluetooth earphones and headsets already clean up the voice in their
        // headset mode, and Apple's voice processing on top of them tends to
        // stall or deliver silence. So: plain microphone for those.
        let bluetooth = AudioRoute.inputIsBluetooth()
        if bluetooth { ActivityLog.write(.voice, "Bluetooth microphone — skipping noise reduction") }
        for processing in (reducesNoise && noiseReduction && !bluetooth ? [true, false] : [false]) {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            if processing {
                do {
                    try input.setVoiceProcessingEnabled(true)
                    input.isVoiceProcessingAGCEnabled = true
                    if #available(macOS 14.0, *) {
                        // Turn other sound (music, videos) down as little as possible.
                        input.voiceProcessingOtherAudioDuckingConfiguration =
                            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true,
                                                                                 duckingLevel: .min)
                    }
                } catch {
                    ActivityLog.write(.voice, "noise reduction unavailable: \(error.localizedDescription)")
                    continue
                }
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { continue }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                tap(mono(buffer))
            }
            engine.prepare()
            do {
                try engine.start()
                watchForDeviceChanges(engine, tap: tap)
                ActivityLog.write(.voice, processing
                    ? "microphone on, with noise reduction (\(Int(format.sampleRate)) Hz)"
                    : "microphone on (\(Int(format.sampleRate)) Hz)")
                if processing { offerVoiceIsolation() }
                return engine
            } catch {
                input.removeTap(onBus: 0)
                ActivityLog.write(.voice, "microphone failed to start\(processing ? " with noise reduction" : ""): \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// Observers for audio-device changes, one per running engine.
    private static var deviceWatches: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Restarts the engine on the new format when the audio hardware changes.
    private static func watchForDeviceChanges(_ engine: AVAudioEngine, tap: @escaping (AVAudioPCMBuffer) -> Void) {
        let key = ObjectIdentifier(engine)
        if let old = deviceWatches[key] { NotificationCenter.default.removeObserver(old) }
        deviceWatches[key] = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak engine] _ in
            MainActor.assumeIsolated {
                guard let engine, deviceWatches[ObjectIdentifier(engine)] != nil else { return }
                // Still running = the hardware didn't really change.
                guard !engine.isRunning else { return }
                let input = engine.inputNode
                input.removeTap(onBus: 0)
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    ActivityLog.write(.voice, "audio device changed — no microphone right now")
                    return
                }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    tap(mono(buffer))
                }
                engine.prepare()
                do {
                    try engine.start()
                    ActivityLog.write(.voice, "audio device changed — microphone restarted (\(Int(format.sampleRate)) Hz)")
                } catch {
                    ActivityLog.write(.error, "microphone didn't restart after a device change: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func stopWatching(_ engine: AVAudioEngine) {
        if let watch = deviceWatches.removeValue(forKey: ObjectIdentifier(engine)) {
            NotificationCenter.default.removeObserver(watch)
        }
    }

    /// Voice processing can deliver several channels; the recognisers want
    /// one. The first carries the processed voice.
    nonisolated private static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard buffer.format.channelCount > 1,
              let source = buffer.floatChannelData,
              let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let single = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let target = single.floatChannelData else { return buffer }
        single.frameLength = buffer.frameLength
        target[0].update(from: source[0], count: Int(buffer.frameLength))
        return single
    }

    private func stopSession() {
        if #available(macOS 26.0, *), let modern = modern as? ModernSpeech { modern.cancel() }
        modern = nil
        silenceTimer?.cancel(); silenceTimer = nil
        giveUpTimer?.cancel(); giveUpTimer = nil
        if let engine {
            Self.stopWatching(engine)
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
        // Retire the session before cancelling, so its cancellation report
        // can't be mistaken for the next session's.
        session += 1
        task?.cancel()
        task = nil
        request = nil
    }

    /// Recogniser errors, in terms of what to do about them.
    private nonisolated static func explain(_ error: NSError) -> String {
        let message = error.localizedDescription.lowercased()
        if message.contains("siri") || message.contains("dictation") || error.code == 1700 || error.code == 1101 {
            return "Speech recognition is off. Turn on Dictation in System Settings ▸ Keyboard, then try again."
        }
        if error.code == 1110 || message.contains("no speech") {
            return "I didn't catch anything — hold ⌥V while you speak, then let go."
        }
        if error.code == 216 || error.code == 301 || message.contains("cancel") {
            return ""      // we cancelled it ourselves; not worth mentioning
        }
        return "I couldn't understand that (\(error.localizedDescription))."
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard isListening else { return }
        if let text { transcript = text }
        if isFinal || failed {
            if !transcript.isEmpty || failed { finishCommand() }
            return
        }
        if endsOnSilence, !transcript.isEmpty { armSilence(seconds: Self.pause) }
    }

    /// Finishes after this much quiet, letting the recogniser settle the last words.
    private func armSilence(seconds: TimeInterval) {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Still talking (words arrive in bursts): wait for real quiet.
            let quiet = Date().timeIntervalSince(VoiceActivity.shared.lastVoice)
            if !self.transcript.isEmpty, quiet < Self.pause {
                self.armSilence(seconds: Self.pause - quiet)
                return
            }
            // Nothing said: nothing to settle (and settling would count it
            // against the new speech model as a miss).
            if self.transcript.isEmpty { self.finishCommand() } else { self.release() }
        }
    }
}


/// What the Mac is using for sound right now.
enum AudioRoute {
    /// The default microphone is Bluetooth (AirPods and other earphones).
    static func inputIsBluetooth() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr, device != 0 else { return false }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}
