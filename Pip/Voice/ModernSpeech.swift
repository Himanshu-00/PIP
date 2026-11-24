import AVFoundation
import Speech

/// Listening with `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26), on the
/// Mac; until its model is downloaded, `VoiceInput` uses the old recogniser.
@available(macOS 26.0, *)
final class ModernSpeech: @unchecked Sendable {

    /// The language and audio format to use, once the model is installed.
    nonisolated(unsafe) static var ready: (locale: Locale, format: AVAudioFormat)?
    /// Something went wrong at runtime; stick with the old recogniser.
    nonisolated(unsafe) static var broken = false
    nonisolated(unsafe) private static var preparing = false

    /// Finds the language and makes sure its model is installed.
    static func prepare() async {
        guard ready == nil, !preparing, !broken else { return }
        preparing = true
        defer { preparing = false }

        var found: Locale? = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if found == nil {
            found = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let locale = found else {
            ActivityLog.write(.voice, "the new speech model doesn't support this language; using the old one")
            return
        }
        let transcriber = makeTranscriber(locale)
        do {
            // Reserved, the model is the app's to keep; unreserved, macOS
            // could drop it, and a request was made (and "downloading" logged)
            // on every launch even when it finished in milliseconds.
            if await !AssetInventory.reservedLocales.contains(where: { $0.identifier == locale.identifier }) {
                _ = try await AssetInventory.reserve(locale: locale)
            }
            if await AssetInventory.status(forModules: [transcriber]) != .installed,
               let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                ActivityLog.write(.voice, "downloading the speech model…")
                try await request.downloadAndInstall()
            }
        } catch {
            ActivityLog.write(.error, "speech model install failed: \(error.localizedDescription)")
            return
        }
        let format: AVAudioFormat? = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let format else { return }
        ready = (locale, format)
        ActivityLog.write(.voice, "new speech model ready (\(locale.identifier), \(format))")
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        // Volatile results: a running guess while you speak, replaced by the
        // settled words a moment later — so your words appear live.
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults], attributeOptions: [])
    }

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    /// Made on the first buffer, on the audio thread, and only used there.
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    /// `finish()` was called: the model is settling the last words and will
    /// end by itself. Cancelling it then as well left it half-closed, and
    /// the next session couldn't start.
    private let stateLock = NSLock()
    private var finishing = false

    /// The previous session's shutdown; each start waits for it.
    nonisolated(unsafe) private static var teardown: Task<Void, Never>?

    /// `onText`: everything heard so far; `onEnd`: finished or failed; `hints`:
    /// words to expect.
    init?(onText: @escaping @Sendable (String) -> Void, onEnd: @escaping @Sendable (Error?) -> Void,
          hints: [String] = []) {
        guard !Self.broken, let ready = Self.ready else { return nil }
        let transcriber = Self.makeTranscriber(ready.locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.analyzer = analyzer
        self.input = continuation
        self.format = ready.format

        resultsTask = Task {
            var settled = ""
            do {
                for try await result in transcriber.results {
                    let words = String(result.text.characters)
                    if result.isFinal {
                        settled += words
                        onText(settled)
                    } else {
                        onText(settled + words)
                    }
                }
                onEnd(nil)
            } catch {
                onEnd(error)
            }
        }
        let previous = Self.teardown
        Task {
            await previous?.value
            do {
                if !hints.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = hints
                    try? await analyzer.setContext(context)
                }
                try await analyzer.start(inputSequence: stream)
            } catch {
                ActivityLog.write(.error, "speech analyzer failed to start: \(error.localizedDescription)")
                Self.broken = true
                onEnd(error)
            }
        }
    }

    /// Microphone audio, from the audio thread: converted to the format the
    /// model wants and passed on.
    func append(_ buffer: AVAudioPCMBuffer) {
        // A new converter whenever the microphone's format changes — e.g.
        // Bluetooth earphones switching to their headset mode mid-session.
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, converted.frameLength > 0 {
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// No more audio: let the model settle the last words, then end.
    func finish() {
        stateLock.lock()
        finishing = true
        stateLock.unlock()
        input.finish()
        let analyzer = self.analyzer
        Self.teardown = Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    /// Stop now; nothing more is wanted.
    func cancel() {
        input.finish()
        stateLock.lock()
        let settling = finishing
        stateLock.unlock()
        guard !settling else { return }    // already ending cleanly
        resultsTask?.cancel()
        let analyzer = self.analyzer
        Self.teardown = Task { await analyzer.cancelAndFinishNow() }
    }
}
