import Foundation
import MLX

/// Brain and voice both run MLX from different actors; they take turns here.
enum MLXGate {
    static let lock = NSLock()

    /// Runs `body` with the GPU to itself. Kept short — one token, one
    /// sentence — so the other side never waits long.
    static func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Pip's voice: Kokoro-82M on MLX, on-device. Downloaded once (~330 MB),
/// loaded on use, unloaded when quiet. Model code vendored in `Voice/Kokoro`.
actor KokoroEngine {

    static let shared = KokoroEngine()

    /// The official Kokoro v1.0 weights in MLX form (Apache 2.0).
    static let repository = "mlx-community/Kokoro-82M-bf16"
    static let modelFile = "kokoro-v1_0.safetensors"
    /// The commit the files come from, and each file's SHA-256 (see FileDownload).
    static let revision = "a71e4d38b236d968966a2002c4c895dbd12b1c3c"
    static let sha256: [String: String] = [
        "kokoro-v1_0.safetensors": "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8",
        "voices/af_heart.safetensors": "2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094",
        "voices/af_bella.safetensors": "112d310468cbb3cf23404d3d0b50ad3adf017b87bf38bf9edd15f4ad572df6a3",
        "voices/af_nicole.safetensors": "574656386022c81a029e9a72558191925f44c3de2dad2fa2e45751938557d062",
        "voices/af_sarah.safetensors": "4940072182542f54c1035d1daf4c1cf3136ca9baa9ac57c8e006b4befcc50be6",
        "voices/af_nova.safetensors": "242b9a0a01eac1ac2865c69fc617a756b20d86df82d5fae3970533e2312ca50e",
        "voices/af_sky.safetensors": "957af332330db8e9bd7f9dc449475a946cb0d7d689afef64b91007bbbf20eaa0",
        "voices/am_michael.safetensors": "3940147ded35deba0bb52e8132f89b719298e0520258c34584358aa5a24da2ea",
        "voices/am_puck.safetensors": "9a8c2e56413bd2063f814cb4c3885fc425876157369117c3f8258d03c8a9ad89",
        "voices/am_fenrir.safetensors": "9abed964b906c4cae6f404d9849e76260689aea862bc6ca85fc3f5207ba96538",
        "voices/am_echo.safetensors": "031fc608a900332c4e1a29bd0884f5d0e84bd0348261fa79981e5cbd138c950d",
        "voices/am_adam.safetensors": "a4f60a3b9c20353c2604a17485ba53260502a758681a84d41e8af53cc559d929",
    ]
    static let approximateSize = "330 MB"
    /// Kokoro produces 24 kHz mono.
    static let sampleRate: Double = 24_000

    /// American English voices — the pronunciation dictionaries bundled are
    /// the US ones. The id prefix: a = American, f/m = female/male.
    static let voices: [(id: String, name: String)] = [
        ("af_heart", "Heart"), ("af_bella", "Bella"), ("af_nicole", "Nicole"),
        ("af_sarah", "Sarah"), ("af_nova", "Nova"), ("af_sky", "Sky"),
        ("am_michael", "Michael"), ("am_puck", "Puck"), ("am_fenrir", "Fenrir"),
        ("am_echo", "Echo"), ("am_adam", "Adam"),
    ]

    private static let voiceKey = "pipKokoroVoice"
    private static let defaultVoice = "af_heart"

    nonisolated static var voiceID: String {
        get {
            let saved = UserDefaults.standard.string(forKey: voiceKey) ?? defaultVoice
            return voices.contains { $0.id == saved } ? saved : defaultVoice
        }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated static var folder: URL {
        AppFolders.support.appendingPathComponent("Models/Kokoro-82M")
    }

    nonisolated static func voiceFile(_ id: String) -> URL {
        folder.appendingPathComponent("\(id).safetensors")
    }

    /// The model and the chosen voice are both on disk.
    nonisolated static var isDownloaded: Bool {
        LocalBrain.fileSize(folder.appendingPathComponent(modelFile)) > 0
            && LocalBrain.fileSize(voiceFile(voiceID)) > 0
    }

    /// The bundled dictionaries made it into the app.
    nonisolated static var hasResources: Bool {
        ["kokoro_config", "us_gold", "us_silver", "us_bart_config"].allSatisfy {
            KokoroResources.url($0, "json") != nil
        } && KokoroResources.url("us_bart", "safetensors") != nil
    }

    private var tts: KokoroTTS?
    private var styles: [String: MLXArray] = [:]
    private var unloadTask: Task<Void, Never>?
    private var downloading = false

    // MARK: - Download

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !downloading else { throw Failure(message: "Already downloading.") }
        downloading = true
        defer { downloading = false }

        let folder = Self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder
        try? excluded.setResourceValues(values)

        try await fetchVoice(Self.voiceID)
        progress(0.02)
        let model = folder.appendingPathComponent(Self.modelFile)
        if LocalBrain.fileSize(model) == 0 {
            try await fetch(Self.modelFile, to: model) { written, expected in
                guard expected > 0 else { return }
                progress(0.02 + 0.98 * Double(written) / Double(expected))
            }
        }
        progress(1)
    }

    /// Voices are small; another one is fetched when it's picked.
    func fetchVoice(_ id: String) async throws {
        let destination = Self.voiceFile(id)
        guard LocalBrain.fileSize(destination) == 0 else { return }
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try await fetch("voices/\(id).safetensors", to: destination) { _, _ in }
    }

    private func fetch(_ path: String, to destination: URL,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let url = URL(string: "https://huggingface.co/\(Self.repository)/resolve/\(Self.revision)/\(path)") else {
            throw Failure(message: "Bad download address.")
        }
        try await FileDownload(destination: destination, sha256: Self.sha256[path], progress: progress).run(from: url)
    }

    // MARK: - Load

    private func load() throws -> KokoroTTS {
        if let tts { return tts }
        guard Self.isDownloaded else { throw Failure(message: "My voice isn't downloaded yet.") }
        // KokoroTTS stops the app outright if a file is missing, so check first.
        guard Self.hasResources else {
            throw Failure(message: "My pronunciation files are missing from the app.")
        }
        let model = KokoroTTS(modelPath: Self.folder.appendingPathComponent(Self.modelFile), g2p: .misaki)
        tts = model
        return model
    }

    private func style(_ id: String) throws -> MLXArray {
        if let cached = styles[id] { return cached }
        let arrays = try loadArrays(url: Self.voiceFile(id))
        guard var style = arrays.values.first else { throw Failure(message: "That voice file is empty.") }
        // Stored as [510, 1, 256] or [510, 256]; the model wants the first.
        if style.ndim == 2 { style = style.expandedDimensions(axis: 1) }
        style = style.asType(.float32)
        styles[id] = style
        return style
    }

    /// Loads everything and speaks a word into nowhere, so the first real
    /// sentence doesn't pay for setting up the GPU kernels.
    func prewarm() {
        guard Self.isDownloaded, tts == nil else { return }
        _ = try? synthesize("Hi.")
    }

    func unload() {
        unloadTask?.cancel()
        unloadTask = nil
        tts = nil
        styles = [:]
        Memory.clearCache()
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard !Task.isCancelled else { return }
            self.unload()
        }
    }

    // MARK: - Speaking

    /// One sentence (or so) of text → 24 kHz samples.
    func synthesize(_ text: String, speed: Float = 1.0) throws -> [Float] {
        MLXGate.lock.lock()
        defer { MLXGate.lock.unlock() }
        let model = try load()
        let voice = try style(Self.voiceID)
        defer { scheduleUnload() }
        let (samples, _) = try model.generateAudio(voice: voice, language: .enUS, text: text, speed: speed)
        return samples
    }
}
