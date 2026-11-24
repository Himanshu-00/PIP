import CoreGraphics
import CryptoKit
import Foundation
import MLX
import MLXNN

/// Pip's brain, running inside the app on Apple's MLX: Qwen3.5-9B, 4-bit
/// (about 6 GB). Its vision part is downloaded with it but not loaded.
///
/// Download once on request, load on first use, generate one token at a
/// time, unload after ten quiet minutes so it isn't holding memory between
/// questions. (`Spec` keeps the model's details in one place.) It's an actor
/// so all of that happens off the main thread, one request at a time.
actor LocalBrain {

    struct Spec: Sendable {
        let repository: String
        let folderName: String
        let approximateSize: String
        /// The model can "think out loud" first; Pip asks it not to.
        let hybridThinking: Bool
        /// Quiet time before the weights are dropped from memory.
        let idleSeconds: UInt64
        /// Everything to download; the `.safetensors` files are the weights.
        let files: [String]
        /// The commit the files come from — never `main`, which can change
        /// under us — and each file's SHA-256, checked before it's kept.
        var revision = "main"
        var sha256: [String: String] = [:]
    }

    static let qwen35Spec = Spec(repository: "mlx-community/Qwen3.5-9B-MLX-4bit",
                                 folderName: "Qwen3.5-9B-MLX-4bit",
                                 approximateSize: "6 GB", hybridThinking: true, idleSeconds: 600,
                                 files: ["config.json", "tokenizer_config.json", "tokenizer.json", "vocab.json",
                                         "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"],
                                 revision: "938d8919941c6e7efd3c7150eff7fe9d12afa631",
                                 sha256: [
                                    "config.json": "a96942cb6a8a1d3f1d17514d81a1925d04362a6a3233b389d13012211baaa9f8",
                                    "tokenizer_config.json": "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182",
                                    "tokenizer.json": "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4",
                                    "vocab.json": "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003",
                                    "model-00001-of-00002.safetensors": "a68b87558c6ef43f74c2bd63ce7e9092ceddc3101f3def0030774bae5f42aadd",
                                    "model-00002-of-00002.safetensors": "b0a770bf8469c7f3f18756a0e0283f1c1174344a83e059a4e483f6af4907352d",
                                 ])

    /// Pip's brain.
    static let currentSpec = qwen35Spec
    static let shared = LocalBrain(spec: currentSpec)

    static let repository = currentSpec.repository
    static let approximateSize = currentSpec.approximateSize
    nonisolated static var folder: URL { folderURL(for: currentSpec) }
    nonisolated static var isDownloaded: Bool { downloaded(currentSpec) }

    nonisolated static func folderURL(for spec: Spec) -> URL {
        AppFolders.support.appendingPathComponent("Models")
            .appendingPathComponent(spec.folderName)
    }

    /// Every file present and non-empty.
    nonisolated static func downloaded(_ spec: Spec) -> Bool {
        let folder = folderURL(for: spec)
        return spec.files.allSatisfy { fileSize(folder.appendingPathComponent($0)) > 0 }
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    let spec: Spec
    nonisolated var folder: URL { Self.folderURL(for: spec) }
    nonisolated var isDownloaded: Bool { Self.downloaded(spec) }

    init(spec: Spec) {
        self.spec = spec
    }

    private var model: (any ChatLanguageModel)?
    private var tokenizer: QwenTokenizer?
    private var unloadTask: Task<Void, Never>?
    private var downloading = false

    /// Longest reply, in tokens. Pip answers in a sentence or two; a tool
    /// call with its arguments is well under this.
    private let maxNewTokens = 320
    /// A little randomness keeps replies from looping; low enough that tool
    /// calls stay well-formed.
    private let temperature: Float = 0.3

    // MARK: - Download

    /// Fetches every file, reporting progress from 0 to 1.
    ///
    /// Files are written to their final names only once complete, so an
    /// interrupted download never leaves something that looks finished.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !downloading else { throw Failure(message: "Already downloading.") }
        downloading = true
        defer { downloading = false }
        ActivityLog.write(.download, "brain download started: \(spec.repository)")

        let folder = self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder.deletingLastPathComponent()
        try? excluded.setResourceValues(values)

        // The weights are almost all of it, so they carry almost all of the bar.
        let weights = spec.files.filter { $0.hasSuffix(".safetensors") }
        let small = spec.files.filter { !$0.hasSuffix(".safetensors") }
        for (index, name) in small.enumerated() {
            try await fetch(name, into: folder) { _, _ in }
            progress(0.02 * Double(index + 1) / Double(small.count))
        }
        for (index, name) in weights.enumerated() {
            let share = 0.98 / Double(weights.count)
            let start = 0.02 + share * Double(index)
            try await fetch(name, into: folder) { written, expected in
                guard expected > 0 else { return }
                progress(start + share * Double(written) / Double(expected))
            }
        }
        ActivityLog.write(.download, "brain download finished: \(spec.repository)")
        progress(1)
    }

    private func fetch(_ name: String, into folder: URL,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let destination = folder.appendingPathComponent(name)
        if Self.fileSize(destination) > 0 {
            return    // already here from an earlier, interrupted run
        }
        guard let url = URL(string: "https://huggingface.co/\(spec.repository)/resolve/\(spec.revision)/\(name)") else {
            throw Failure(message: "Bad download address.")
        }
        try await FileDownload(destination: destination, sha256: spec.sha256[name], progress: progress).run(from: url)
    }

    // MARK: - Load

    private func load() throws {
        guard model == nil || tokenizer == nil else { return }
        guard isDownloaded else { throw Failure(message: "My brain isn't downloaded yet.") }
        let folder = self.folder

        // Keep MLX's buffer cache modest; the model itself is what needs room.
        Memory.cacheLimit = 256 * 1024 * 1024

        let configData = try Data(contentsOf: folder.appendingPathComponent("config.json"))
        let configuration = try Qwen35Configuration(data: configData)
        let model: any ChatLanguageModel = Qwen35Model(configuration)
        let quantization = configuration.quantization

        // Large models come in several files; together they're one set of weights.
        var weights: [String: MLXArray] = [:]
        for name in spec.files where name.hasSuffix(".safetensors") {
            weights.merge(try loadArrays(url: folder.appendingPathComponent(name))) { _, new in new }
        }
        weights = model.sanitize(weights)

        // The file stores most layers as 4-bit integers plus a scale and an
        // offset per group of 64. Swap those layers for quantised versions
        // first, so the stored weights have the right shape to land in.
        if let quantization {
            let stored = weights
            quantize(model: model, filter: { path, _ -> (groupSize: Int, bits: Int, mode: QuantizationMode)? in
                guard stored["\(path).scales"] != nil else { return nil }
                return (quantization.groupSize, quantization.bits, .affine)
            })
        }

        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model)
        ActivityLog.write(.brain, "loaded \(spec.folderName)")

        self.model = model
        tokenizer = try QwenTokenizer(folder: folder)
    }

    func unload() {
        if model != nil { ActivityLog.write(.brain, "unloaded \(spec.folderName)") }
        unloadTask?.cancel()
        unloadTask = nil
        model = nil
        tokenizer = nil
        header = nil
        session = nil
        vision = nil
        lookPrompt = nil
        Memory.clearCache()
    }

    /// On battery (set by the app from the power monitor). The brain is
    /// dropped much sooner then — holding 6 GB in memory isn't free.
    nonisolated(unsafe) static var onBattery = false

    private func scheduleUnload() {
        unloadTask?.cancel()
        // A loaded brain that isn't working makes no heat — only loading and
        // thinking do. Unloading quickly just meant loading again (heat) on
        // the next question. So it stays for the idle time, and is let go
        // early only if the Mac runs short of memory (see AppDelegate).
        let seconds: UInt64 = spec.idleSeconds
        unloadTask = Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.unload()
        }
    }

    // MARK: - Chat

    /// The fixed start of the prompt, already read: its text, and the cache
    /// holding its keys and values. Every question copies this instead of
    /// re-reading Pip's instructions and the tool list from scratch.
    private var header: (text: String, cache: [KVCache])?

    /// Loads the model and reads the fixed part of the prompt ahead of time,
    /// so by the time a question arrives the expensive work is done.
    /// - Parameter conversation: what has been said so far (system prompt
    ///   first). Read now, while the user is still speaking or typing, so
    ///   the question only has its own words left to read: "hi, how are
    ///   you?" spent 19.5 of its 25 s re-reading a restored conversation.
    func prewarm(system: String, tools: [[String: Any]], conversation messages: [[String: Any]] = []) {
        unloadTask?.cancel()
        defer { scheduleUnload() }
        let loaded: Bool = MLXGate.locked { (try? load()) != nil }
        guard loaded, let model, let tokenizer else { return }
        let text = QwenChat.header(messages: [["role": "system", "content": system]], tools: tools)
        let header = headerCache(text, model: model, tokenizer: tokenizer)
        guard messages.count > 1 else { return }
        // Exactly as `chat` reads it, up to the cue for the reply.
        let headerText = QwenChat.header(messages: messages, tools: tools)
        let conversation = QwenChat.conversation(messages: messages)
        let cueText = "<|im_start|>assistant\n"
        let bodyText = conversation.hasSuffix(cueText) ? String(conversation.dropLast(cueText.count)) : conversation
        let bodyTokens = tokenizer.encode(bodyText)
        if let session, session.header == headerText, bodyTokens.starts(with: session.tokens),
           session.tokens.count == bodyTokens.count { return }   // already read
        let started = Date()
        let cache: [KVCache]
        let newTokens: ArraySlice<Int>
        if let session, session.header == headerText, bodyTokens.starts(with: session.tokens) {
            cache = session.cache.map { $0.copy() }
            newTokens = bodyTokens[session.tokens.count...]
        } else {
            cache = headerText == text ? header : headerCache(headerText, model: model, tokenizer: tokenizer)
            newTokens = bodyTokens[...]
        }
        prefill(Array(newTokens), model: model, cache: cache)
        session = (headerText, bodyTokens, cache.map { $0.copy() })
        ActivityLog.write(.brain, String(format: "read ahead %ld tokens of the conversation in %.2fs",
                                         newTokens.count, Date().timeIntervalSince(started)))
    }

    /// One reply, in the same shape the Ollama client returns.
    ///
    /// `onPartial` receives the reply as it's written, so the bubble (and
    /// the voice) can start before the answer is finished. It stops being
    /// called if the reply turns out to be a tool call, which isn't for show.
    func chat(messages: [[String: Any]], tools: [[String: Any]],
              onPartial: (@Sendable (String) -> Void)? = nil) throws -> OllamaClient.Reply {
        unloadTask?.cancel()
        defer { scheduleUnload() }
        try MLXGate.locked { try load() }
        guard let model, let tokenizer else { throw Failure(message: "My brain didn't load.") }
        let started = Date()

        let headerText = QwenChat.header(messages: messages, tools: tools)
        let conversation = QwenChat.conversation(messages: messages)

        // The conversation so far, and the cue for the reply. They're read
        // separately so the cache can be kept at the point *before* the cue:
        // the next request — a tool result, or the next question — always
        // continues from exactly there.
        let cueText = "<|im_start|>assistant\n"
        let bodyText = conversation.hasSuffix(cueText) ? String(conversation.dropLast(cueText.count)) : conversation
        var cue = conversation.hasSuffix(cueText) ? cueText : ""
        // The switch for answering directly, without a thinking phase.
        if spec.hybridThinking { cue += "<think>\n\n</think>\n\n" }

        let bodyTokens = tokenizer.encode(bodyText)
        let cueTokens = tokenizer.encode(cue)

        // Reuse what was already read last time if this conversation simply
        // continues it — usually all but the newest message or tool result.
        let cache: [KVCache]
        let newTokens: ArraySlice<Int>
        if let session, session.header == headerText, bodyTokens.starts(with: session.tokens) {
            cache = session.cache.map { $0.copy() }
            newTokens = bodyTokens[session.tokens.count...]
        } else {
            cache = headerCache(headerText, model: model, tokenizer: tokenizer)
            newTokens = bodyTokens[...]
        }
        prefill(Array(newTokens), model: model, cache: cache)
        session = (headerText, bodyTokens, cache.map { $0.copy() })
        let read = Date()

        let output = generate(model: model, cache: cache, input: cueTokens,
                              stop: [tokenizer.endOfTurn, tokenizer.endOfText]) { tokens in
            guard let onPartial else { return true }
            let text = tokenizer.decode(tokens)
            if text.contains("<tool_call>") { return false }
            let visible = OllamaClient.stripThinking(text)
            if !visible.isEmpty { onPartial(visible) }
            return true
        }
        let finished = Date()
        let writeSeconds = finished.timeIntervalSince(read)
        ActivityLog.write(.brain, String(format: "read %ld new tokens (reused %ld) in %.2fs, wrote %ld tokens in %.2fs (%.1f tokens/s)",
              newTokens.count, bodyTokens.count - newTokens.count, read.timeIntervalSince(started),
              output.count, writeSeconds, writeSeconds > 0 ? Double(output.count) / writeSeconds : 0))

        let parsed = QwenChat.parse(tokenizer.decode(output))
        return OllamaClient.Reply(content: parsed.content, toolCalls: parsed.calls, raw: parsed.raw)
    }

    /// The conversation read last time, and the cache holding it — kept so
    /// the next request only reads what's new.
    private var session: (header: String, tokens: [Int], cache: [KVCache])?

    /// Reads tokens into the cache, a slice at a time: smaller slices keep
    /// memory steady on long inputs, and let the voice take the GPU in
    /// between (see `MLXGate`).
    private func prefill(_ tokens: [Int], model: any ChatLanguageModel, cache: [KVCache]) {
        var start = 0
        while start < tokens.count {
            let end = min(start + 512, tokens.count)
            let slice = Array(tokens[start ..< end])
            MLXGate.locked {
                let logits = model(MLXArray(slice).reshaped(1, slice.count), cache: cache)
                eval(logits)
                // The convolution state isn't needed for the logits, so it
                // would otherwise stay unevaluated and keep its inputs alive.
                eval(cache.compactMap { $0.conv })
            }
            start = end
        }
    }

    /// A fresh cache that already holds the header, reading it only if it
    /// changed since last time.
    private func headerCache(_ text: String, model: any ChatLanguageModel, tokenizer: QwenTokenizer) -> [KVCache] {
        if let header, header.text == text {
            return header.cache.map { $0.copy() }
        }
        session = nil
        // Read before? Pip's instructions and tool list are thousands of
        // tokens; reading them is the single biggest burst of work the brain
        // does, and it would happen every time the brain loads. Saved once
        // to disk, it's a quick file read instead.
        if let saved = loadSavedHeader(text, model: model) {
            header = (text, saved)
            ActivityLog.write(.brain, "instructions loaded from disk (no re-reading)")
            return saved.map { $0.copy() }
        }
        let cache = model.newCache()
        let ids = tokenizer.encode(text)
        guard !ids.isEmpty else { return cache }
        prefill(ids, model: model, cache: cache)
        header = (text, cache)
        saveHeader(cache, text: text)
        ActivityLog.write(.brain, "read instructions (\(ids.count) tokens) and saved them")
        return cache.map { $0.copy() }
    }

    // MARK: - Instructions saved to disk

    private var headerFolder: URL {
        AppFolders.caches.appendingPathComponent("Header")
    }

    /// One file per model and exact instructions text (a stable hash of it):
    /// any change to the instructions or tools simply makes a new file.
    private func headerFile(_ text: String) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (spec.folderName + "\u{0}" + text).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return headerFolder.appendingPathComponent("\(spec.folderName)-\(String(hash, radix: 16)).safetensors")
    }

    private func saveHeader(_ cache: [KVCache], text: String) {
        var arrays: [String: MLXArray] = [:]
        var metadata: [String: String] = [:]
        for (index, layer) in cache.enumerated() {
            if let keys = layer.keys { arrays["\(index).keys"] = keys }
            if let values = layer.values { arrays["\(index).values"] = values }
            if let conv = layer.conv { arrays["\(index).conv"] = conv }
            if let recurrent = layer.recurrent { arrays["\(index).recurrent"] = recurrent }
            metadata["\(index).offset"] = String(layer.offset)
        }
        let file = headerFile(text)
        let manager = FileManager.default
        try? manager.createDirectory(at: headerFolder, withIntermediateDirectories: true)
        // Older instructions for this model aren't needed any more.
        for old in (try? manager.contentsOfDirectory(at: headerFolder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix(spec.folderName + "-") && old != file {
            try? manager.removeItem(at: old)
        }
        MLXGate.locked {
            do {
                try MLX.save(arrays: arrays, metadata: metadata, url: file)
            } catch {
                ActivityLog.write(.error, "couldn't save the instructions: \(error.localizedDescription)")
            }
        }
    }

    private func loadSavedHeader(_ text: String, model: any ChatLanguageModel) -> [KVCache]? {
        let file = headerFile(text)
        guard FileManager.default.fileExists(atPath: file.path),
              let loaded = try? loadArraysAndMetadata(url: file) else { return nil }
        let (arrays, metadata) = loaded
        let cache = model.newCache()
        for (index, layer) in cache.enumerated() {
            layer.restore(keys: arrays["\(index).keys"], values: arrays["\(index).values"],
                          offset: Int(metadata["\(index).offset"] ?? "") ?? 0)
            layer.conv = arrays["\(index).conv"]
            layer.recurrent = arrays["\(index).recurrent"]
        }
        // Sanity check: a cache from a different model shape would crash later.
        guard cache.contains(where: { $0.offset > 0 }) else { return nil }
        MLXGate.locked { eval(Array(arrays.values)) }
        return cache
    }

    /// Reads the new part of the prompt, then writes tokens until a stop
    /// token or the limit. `progress` is told about the reply so far after
    /// every token, and can say `false` to stop being told.
    ///
    /// The GPU is taken one step at a time (see `MLXGate`), so Pip's voice
    /// can speak the first sentence while the rest is still being written.
    private func generate(model: any ChatLanguageModel, cache: [KVCache], input: [Int], stop: Set<Int>,
                          progress: ([Int]) -> Bool) -> [Int] {
        guard !input.isEmpty else { return [] }

        // The new tokens in one forward pass. The cache already has the
        // header; this adds the conversation, and the last position's
        // scores are the first token of the reply.
        let first = MLXGate.locked {
            sample(model(MLXArray(input).reshaped(1, input.count), cache: cache)[0, -1])
        }
        return writeOn(from: first, model: model, cache: cache, stop: stop, progress: progress)
    }

    /// The token-by-token part of writing, from the first token on.
    private func writeOn(from first: Int, model: any ChatLanguageModel, cache: [KVCache], stop: Set<Int>,
                         limit: Int? = nil, greedy: Bool = false, progress: ([Int]) -> Bool) -> [Int] {
        var token = first
        var output: [Int] = []
        var reporting = true
        // Already hot: a short breather between words spreads the work out,
        // so the Mac can shed heat while Pip writes (a little slower).
        let thermal = ProcessInfo.processInfo.thermalState
        let breather: useconds_t = thermal == .critical ? 40_000 : thermal == .serious ? 15_000 : 0
        if breather > 0 { ActivityLog.write(.brain, "Mac is hot — writing more gently") }
        for _ in 0 ..< (limit ?? maxNewTokens) {
            if breather > 0 { usleep(breather) }
            // Cancelled (the stop key, or Esc): stop writing at once.
            if stop.contains(token) || Task.isCancelled { break }
            output.append(token)
            if reporting { reporting = progress(output) }
            // Only the new token goes in; the cache supplies the rest.
            let previous = token
            token = MLXGate.locked {
                pick(model(MLXArray([previous]).reshaped(1, 1), cache: cache)[0, -1], greedy: greedy)
            }
        }
        return output
    }

    // MARK: - Looking

    /// Pip's eyes: Qwen3.5's vision encoder, loaded the first time he looks.
    private var vision: (model: Qwen35VisionModel, config: Qwen35VisionConfiguration)?

    /// Whether this brain can see at all.
    nonisolated var canSee: Bool { true }

    private func loadVision() throws -> (model: Qwen35VisionModel, config: Qwen35VisionConfiguration) {
        if let vision { return vision }
        guard canSee else { throw Failure(message: "This brain can't see.") }
        let configData = try Data(contentsOf: folder.appendingPathComponent("config.json"))
        let config = try Qwen35VisionConfiguration(data: configData)

        // The vision weights sit in the same files as the language model's.
        var weights: [String: MLXArray] = [:]
        for name in spec.files where name.hasSuffix(".safetensors") {
            for (key, value) in try loadArrays(url: folder.appendingPathComponent(name)) {
                if key.hasPrefix("vision_tower.") {
                    weights[String(key.dropFirst("vision_tower.".count))] = value
                } else if key.hasPrefix("model.visual.") {
                    weights[String(key.dropFirst("model.visual.".count))] = value
                }
            }
        }
        guard !weights.isEmpty else { throw Failure(message: "My eyes aren't in this download.") }

        let model = Qwen35VisionModel(config)
        weights = model.sanitize(weights)
        if let quantization = try Qwen35Configuration(data: configData).quantization {
            let stored = weights
            quantize(model: model, filter: { path, _ -> (groupSize: Int, bits: Int, mode: QuantizationMode)? in
                guard stored["\(path).scales"] != nil else { return nil }
                return (quantization.groupSize, quantization.bits, .affine)
            })
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model)
        ActivityLog.write(.vision, "eyes loaded")
        vision = (model, config)
        return (model, config)
    }

    /// Looks at a picture and answers `question` about it, in a separate
    /// short exchange — the image never enters the main conversation, so it
    /// doesn't slow down everything after it.
    ///
    /// For many pictures with the same question (photo captions):
    /// `cachePrompt` puts the question before the image, so instructions and
    /// question are read once and reused — only the image and the reply are
    /// new each time; `answerLimit` caps the reply; `greedy` skips sampling.
    func look(at image: CGImage, question: String, maxTokens: Int = 1_024,
              system: String = "You are looking at the user's Mac screen. Answer the question about it "
                  + "briefly and precisely. Quote any text you read exactly.",
              answerLimit: Int? = nil, greedy: Bool = false, cachePrompt: Bool = false) throws -> String {
        unloadTask?.cancel()
        defer { scheduleUnload() }
        try MLXGate.locked { try load() }
        guard let model = model as? Qwen35Model, let tokenizer else {
            throw Failure(message: "I can't see with this brain.")
        }
        let started = Date()
        let eyes = try MLXGate.locked { try loadVision() }
        let config = eyes.config

        // Picture → tokens.
        let (pixels, grid) = try Qwen35ImageInput.prepare(image, config: config, maxTokens: maxTokens)
        let features: MLXArray = MLXGate.locked {
            let f = eyes.model(pixels.asType(eyes.model.patchEmbed.proj.weight.dtype), grid: grid)
            eval(f)
            return f
        }
        let imageTokens = features.dim(0)

        // The prompt: instructions, the image, the question — or, to reuse
        // it, instructions and question, then the image.
        let cue = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        let before = tokenizer.encode("<|im_start|>system\n" + system + "<|im_end|>\n<|im_start|>user\n"
                                      + (cachePrompt ? question + "\n" : ""))
            + [config.visionStartTokenId]
        let after = [config.visionEndTokenId] + tokenizer.encode((cachePrompt ? "" : question) + cue)

        let embed = model.model.embedTokens
        let embeddings: MLXArray = MLXGate.locked {
            let last = embed(MLXArray(after).reshaped(1, after.count))
            let picture = features.asType(last.dtype).reshaped(1, imageTokens, -1)
            if cachePrompt { return concatenated([picture, last], axis: 1) }
            let first = embed(MLXArray(before).reshaped(1, before.count))
            return concatenated([first, picture, last], axis: 1)
        }

        // Positions: text counts up; the image's tokens share one time step
        // and spread over its rows and columns; text after it carries on
        // from just past the image's largest position.
        let merge = config.spatialMergeSize
        let (rows, columns) = (grid.h / merge, grid.w / merge)
        var t: [Int32] = [], h: [Int32] = [], w: [Int32] = []
        for index in 0 ..< before.count {
            t.append(Int32(index)); h.append(Int32(index)); w.append(Int32(index))
        }
        let start = before.count
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                t.append(Int32(start)); h.append(Int32(start + row)); w.append(Int32(start + column))
            }
        }
        var next = start + max(rows, columns)
        for _ in 0 ..< after.count {
            t.append(Int32(next)); h.append(Int32(next)); w.append(Int32(next))
            next += 1
        }
        let total = t.count
        let cache: [KVCache]
        let positions: MLXArray
        if cachePrompt {
            cache = lookPromptCache(before, model: model)
            let skip = before.count
            positions = MLXArray(Array(t.dropFirst(skip)) + Array(h.dropFirst(skip)) + Array(w.dropFirst(skip)))
                .reshaped(3, total - skip)
        } else {
            cache = model.newCache()
            positions = MLXArray(t + h + w).reshaped(3, total)
        }
        let first = MLXGate.locked {
            pick(model(embeddings: embeddings, positions: positions, cache: cache)[0, -1], greedy: greedy)
        }
        // Everything written from here sits after the image in position terms.
        for layer in cache { layer.positionDelta = next - total }
        let read = Date()

        let output = writeOn(from: first, model: model, cache: cache,
                             stop: [tokenizer.endOfTurn, tokenizer.endOfText],
                             limit: answerLimit ?? maxNewTokens, greedy: greedy) { _ in true }
        ActivityLog.write(.vision, String(format: "looked: %ld image tokens (%ldx%ld patches), read in %.2fs, answered %ld tokens in %.2fs",
              imageTokens, grid.w, grid.h, read.timeIntervalSince(started), output.count,
              Date().timeIntervalSince(read)))
        return OllamaClient.stripThinking(tokenizer.decode(output))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The instructions-and-question part of a cached `look`, read once
    /// (per brain load and per prompt) and copied for each picture. Text
    /// only, so its positions are plain counting — the same either way.
    private var lookPrompt: (tokens: [Int], cache: [KVCache])?

    private func lookPromptCache(_ tokens: [Int], model: Qwen35Model) -> [KVCache] {
        if let lookPrompt, lookPrompt.tokens == tokens { return lookPrompt.cache.map { $0.copy() } }
        let cache = model.newCache()
        let count = Int32(tokens.count)
        let steps = Array(0 ..< count)
        MLXGate.locked {
            let embeddings = model.model.embedTokens(MLXArray(tokens).reshaped(1, tokens.count))
            let logits = model(embeddings: embeddings, positions: MLXArray(steps + steps + steps).reshaped(3, tokens.count),
                               cache: cache)
            eval(logits)
            eval(cache.compactMap { $0.conv })
        }
        lookPrompt = (tokens, cache)
        return cache.map { $0.copy() }
    }

    private func pick(_ logits: MLXArray, greedy: Bool) -> Int {
        greedy ? Int(argMax(logits, axis: -1).asType(.int32).item(Int32.self)) : sample(logits)
    }

    private func sample(_ logits: MLXArray) -> Int {
        let choice = temperature <= 0
            ? argMax(logits, axis: -1)
            : MLXRandom.categorical(logits * (1 / temperature))
        return Int(choice.asType(.int32).item(Int32.self))
    }
}

/// One file download with progress, written to its destination only when complete.
/// Also used for Pip's voice (see KokoroEngine) and the photo model.
///
/// With `sha256`, the file is kept only if it matches; otherwise it's
/// deleted and the download fails. Nothing was checked before: a changed or
/// tampered file on the server would have been loaded as it came.
final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let destination: URL
    private let sha256: String?
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    private var lastReported: Int64 = 0

    init(destination: URL, sha256: String? = nil, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.sha256 = sha256
        self.progress = progress
    }

    /// A file's SHA-256 in hex, read 4 MB at a time (the weights are GBs).
    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func run(from url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Every 8 MB is plenty for a progress bar, and far fewer updates.
        guard totalBytesWritten - lastReported >= 8_000_000
                || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastReported = totalBytesWritten
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(LocalBrain.Failure(message: "The download failed (HTTP \(http.statusCode))."))
            return
        }
        if let sha256, Self.sha256(of: location) != sha256 {
            try? FileManager.default.removeItem(at: location)
            ActivityLog.write(.error, "download: \(destination.lastPathComponent) didn't match its checksum — deleted")
            finish(LocalBrain.Failure(message: "\(destination.lastPathComponent) didn't match its checksum, so I deleted it."))
            return
        }
        // Moved here, synchronously: the temporary file is deleted as soon
        // as this method returns.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        if let error { waiting?.resume(throwing: error) } else { waiting?.resume() }
    }
}
