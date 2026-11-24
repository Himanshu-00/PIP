import Foundation

/// A local Ollama server (`localhost:11434`), behind `status()` and `chat`.
struct OllamaClient {

    enum Status: Equatable {
        case ready(model: String)
        /// Ollama is running but has no model the pet can use.
        case noModel
        /// Nothing is listening — not installed, or not started.
        case notRunning
    }

    struct Failure: Error {
        let message: String
    }

    /// One reply from the model: some text, some tool calls, or both.
    struct Reply {
        var content: String
        var toolCalls: [(name: String, arguments: [String: Any])]
        /// The assistant message exactly as Ollama sent it, to be appended to
        /// the history so the model sees its own tool calls next turn.
        var raw: [String: Any]
    }

    private let base = URL(string: "http://127.0.0.1:11434")!

    /// Models in the order the pet prefers them. Small, good at tool calling,
    /// permissively licensed. The first one installed wins; a model named in
    /// the `petModel` default overrides the list.
    static let preferred = ["qwen3:4b-instruct", "qwen3:4b", "qwen3", "qwen2.5", "llama3.2", "llama3.1"]

    // MARK: - Status

    func status() async -> Status {
        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return .notRunning }

        let names = models.compactMap { $0["name"] as? String }
        if let chosen = UserDefaults.standard.string(forKey: "petModel"), names.contains(chosen) {
            return .ready(model: chosen)
        }
        for wanted in Self.preferred {
            if let match = names.first(where: { $0 == wanted || $0.hasPrefix(wanted + ":") || $0.hasPrefix(wanted + "-") }) {
                return .ready(model: match)
            }
        }
        return names.first.map { Status.ready(model: $0) } ?? .noModel
    }

    // MARK: - Chat

    /// One round trip. No streaming: replies are a sentence or two, and a
    /// tool call has to arrive whole before it can be run anyway.
    func chat(model: String,
              messages: [[String: Any]],
              tools: [[String: Any]]) async throws -> Reply {
        do {
            return try await send(model: model, messages: messages, tools: tools, disableThinking: true)
        } catch let failure as Failure where failure.message.lowercased().contains("think") {
            // Older Ollama, or a model without a thinking mode, can refuse the
            // `think` flag outright. Asking again without it is cheaper than
            // working out in advance which it is.
            return try await send(model: model, messages: messages, tools: tools, disableThinking: false)
        }
    }

    private func send(model: String,
                      messages: [[String: Any]],
                      tools: [[String: Any]],
                      disableThinking: Bool) async throws -> Reply {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": tools,
            "stream": false,
            // Keeps the model in memory for a while after a chat, so the next
            // question doesn't pay the load time again — and lets it go after.
            "keep_alive": "10m",
            "options": ["temperature": 0.3],
        ]
        // Qwen3 thinks out loud before answering by default. For a pet that
        // replies in one sentence that's seconds of waiting for nothing.
        if disableThinking { body["think"] = false }

        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(message: "Couldn't reach Ollama.")
        }
        let data = result.0
        let response = result.1

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: (json["error"] as? String) ?? "Ollama returned an error.")
        }
        guard let message = json["message"] as? [String: Any] else {
            throw Failure(message: "Ollama sent back something unexpected.")
        }

        var calls: [(name: String, arguments: [String: Any])] = []
        for call in message["tool_calls"] as? [[String: Any]] ?? [] {
            guard let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }
            // Normally an object; some models hand back a JSON string.
            var arguments = function["arguments"] as? [String: Any] ?? [:]
            if arguments.isEmpty, let text = function["arguments"] as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                arguments = parsed
            }
            calls.append((name, arguments))
        }

        let content = Self.stripThinking(message["content"] as? String ?? "")
        return Reply(content: content, toolCalls: calls, raw: message)
    }

    /// Keeps only the final answer: removes `<think>` blocks, complete or not.
    static func stripThinking(_ text: String) -> String {
        var answer = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "",
                                               options: .regularExpression)
        // Reasoning that started before the content did: keep what follows it.
        if let close = answer.range(of: "</think>", options: .backwards) {
            answer = String(answer[close.upperBound...])
        }
        // Reasoning that never finished: there's no answer after it to keep.
        if let open = answer.range(of: "<think>") {
            answer = String(answer[..<open.lowerBound])
        }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
