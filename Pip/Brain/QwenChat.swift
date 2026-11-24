import Foundation

/// Qwen3.5's chat format: how a conversation and a list of tools become one
/// prompt, and how the model's reply becomes text and tool calls again.
///
/// This is the model's `chat_template.jinja` written out in Swift. It has to
/// match closely — the model was trained on exactly this layout, and small
/// differences (a missing newline, tools listed in another shape) make it
/// noticeably worse at calling tools.
///
/// Messages use the same dictionaries Ollama's API does, so the agent's
/// history works with either brain unchanged.
enum QwenChat {

    // MARK: - Prompt

    /// The fixed start of every prompt (tools, then Pip's instructions): the
    /// same bytes every time, so its cache is computed once and reused.
    static func header(messages: [[String: Any]], tools: [[String: Any]]) -> String {
        let firstIsSystem = (messages.first?["role"] as? String) == "system"
        let systemText = firstIsSystem
            ? (messages.first?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        guard !tools.isEmpty else {
            return firstIsSystem ? "<|im_start|>system\n" + systemText + "<|im_end|>\n" : ""
        }
        var out = "<|im_start|>system\n# Tools\n\nYou have access to the following functions:\n\n<tools>"
        for tool in tools { out += "\n" + json(tool) }
        out += "\n</tools>"
        out += "\n\nIf you choose to call a function ONLY reply in the following format with NO suffix:\n\n"
        out += "<tool_call>\n<function=example_function_name>\n<parameter=example_parameter_1>\nvalue_1\n"
        out += "</parameter>\n<parameter=example_parameter_2>\nThis is the value for the second parameter\n"
        out += "that can span\nmultiple lines\n</parameter>\n</function>\n</tool_call>\n\n<IMPORTANT>\nReminder:\n"
        out += "- Function calls MUST follow the specified format: an inner <function=...></function> block "
        out += "must be nested within <tool_call></tool_call> XML tags\n"
        out += "- Required parameters MUST be specified\n"
        out += "- You may provide optional reasoning for your function call in natural language BEFORE the "
        out += "function call, but NOT after\n"
        out += "- If there is no function call available, answer the question like normal with your current "
        out += "knowledge and do not tell the user about function calls\n</IMPORTANT>"
        if !systemText.isEmpty { out += "\n\n" + systemText }
        out += "<|im_end|>\n"
        return out
    }

    /// Everything after the header, ending with the cue for the assistant to speak.
    static func conversation(messages: [[String: Any]]) -> String {
        var out = ""
        for (index, message) in messages.enumerated() {
            let role = message["role"] as? String ?? ""
            var content = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            switch role {
            case "user":
                out += "<|im_start|>user\n" + content + "<|im_end|>\n"
            case "assistant":
                if let close = content.range(of: "</think>") {
                    content = String(content[close.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                out += "<|im_start|>assistant\n"
                // On every assistant turn, not just those after the newest
                // question (as Qwen's template does). Dropping it from older
                // turns changed the start of the conversation each time a new
                // question arrived, so the brain's cache never matched and it
                // re-read the whole chat: "reused 0", 6–16 s per question.
                // The block is empty anyway — Pip answers without thinking.
                out += "<think>\n\n</think>\n\n"
                out += content
                let calls = message["tool_calls"] as? [[String: Any]] ?? []
                for (callIndex, call) in calls.enumerated() {
                    let function = call["function"] as? [String: Any] ?? call
                    let name = function["name"] as? String ?? ""
                    if callIndex == 0 {
                        out += content.isEmpty ? "<tool_call>\n<function=\(name)>\n" : "\n\n<tool_call>\n<function=\(name)>\n"
                    } else {
                        out += "\n<tool_call>\n<function=\(name)>\n"
                    }
                    let arguments = function["arguments"] as? [String: Any] ?? [:]
                    for key in arguments.keys.sorted() {
                        out += "<parameter=\(key)>\n" + parameterText(arguments[key]!) + "\n</parameter>\n"
                    }
                    out += "</function>\n</tool_call>"
                }
                out += "<|im_end|>\n"
            case "tool":
                let previous = index > 0 ? messages[index - 1]["role"] as? String : nil
                let next = index + 1 < messages.count ? messages[index + 1]["role"] as? String : nil
                if previous != "tool" { out += "<|im_start|>user" }
                out += "\n<tool_response>\n" + content + "\n</tool_response>"
                if next != "tool" { out += "<|im_end|>\n" }
            default:
                break
            }
        }
        out += "<|im_start|>assistant\n"
        return out
    }

    /// An argument as the template writes it: text as-is, lists and objects as JSON.
    private static func parameterText(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case is [String: Any], is [Any]: return json(value)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "True" : "False" }
            return number.stringValue
        default: return "\(value)"
        }
    }

    /// `<function=name><parameter=key>value</parameter>…</function>`, Qwen3.5's call format.
    private static func parseXMLCall(_ body: String) -> (name: String, arguments: [String: Any])? {
        let ns = body as NSString
        guard let function = try? NSRegularExpression(pattern: #"<function=([^>\n]+)>"#),
              let match = function.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        var arguments: [String: Any] = [:]
        if let parameter = try? NSRegularExpression(pattern: #"(?s)<parameter=([^>\n]+)>\n?(.*?)\n?</parameter>"#) {
            for found in parameter.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: found.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let raw = ns.substring(with: found.range(at: 2))
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
                   let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
                    arguments[key] = object
                } else {
                    arguments[key] = raw
                }
            }
        }
        return name.isEmpty ? nil : (name, arguments)
    }

    // MARK: - Reply

    /// Splits generated text into the reply and any `<tool_call>` blocks.
    ///
    /// Returns the assistant message too, shaped like Ollama's, so it can go
    /// back into the history and be rendered by `prompt` next turn.
    static func parse(_ generated: String)
        -> (content: String, calls: [(name: String, arguments: [String: Any])], raw: [String: Any]) {
        var text = generated
        var calls: [(name: String, arguments: [String: Any])] = []

        let pattern = #"(?s)<tool_call>\s*(.*?)\s*</tool_call>"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let body = ns.substring(with: match.range(at: 1))
                if body.contains("<function="), let call = parseXMLCall(body) {
                    calls.append(call)
                    continue
                }
                guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                      let name = object["name"] as? String else { continue }
                var arguments = object["arguments"] as? [String: Any] ?? [:]
                if arguments.isEmpty, let string = object["arguments"] as? String,
                   let parsed = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] {
                    arguments = parsed
                }
                calls.append((name, arguments))
            }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                  withTemplate: "")
        }
        // An unfinished tool call at the very end is not part of the answer.
        if let open = text.range(of: "<tool_call>") { text = String(text[..<open.lowerBound]) }

        let content = OllamaClient.stripThinking(text)
        var raw: [String: Any] = ["role": "assistant", "content": content]
        if !calls.isEmpty {
            raw["tool_calls"] = calls.map { call in
                ["function": ["name": call.name, "arguments": call.arguments] as [String: Any]]
            }
        }
        return (content, calls, raw)
    }

    // MARK: - JSON, the way the template writes it

    /// JSON with Python's default separators (`", "` and `": "`), which is
    /// what the template's `tojson` produces and therefore what the model saw
    /// in training. Keys in a stable, readable order rather than whatever
    /// order a Swift dictionary happens to iterate in.
    static func json(_ value: Any) -> String {
        switch value {
        case let dictionary as [String: Any]:
            let keys = dictionary.keys.sorted { order($0, $1) }
            return "{" + keys.map { "\(quote($0)): \(json(dictionary[$0]!))" }.joined(separator: ", ") + "}"
        case let array as [Any]:
            return "[" + array.map { json($0) }.joined(separator: ", ") + "]"
        case let string as String:
            return quote(string)
        case let number as NSNumber:
            // Booleans arrive as NSNumber too, and `as? Bool` would happily
            // turn a 1 into `true` — so ask Core Foundation which it really is.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        default:
            return "null"
        }
    }

    private static let preferredOrder = ["type", "function", "name", "description",
                                         "parameters", "properties", "required", "enum"]

    private static func order(_ a: String, _ b: String) -> Bool {
        let first = preferredOrder.firstIndex(of: a) ?? Int.max
        let second = preferredOrder.firstIndex(of: b) ?? Int.max
        return first != second ? first < second : a < b
    }

    private static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
