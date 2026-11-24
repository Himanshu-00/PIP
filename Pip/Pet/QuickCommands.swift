import AppKit

/// Everyday one-meaning commands ("volume 40", "open Safari") matched by
/// pattern and run without the model, through Pip's own tools and checks.
@MainActor
enum QuickCommands {

    struct Command {
        let tool: String
        let arguments: [String: Any]
    }

    static func match(_ input: String) -> Command? {
        let text = normalize(input)
        guard !text.isEmpty, text.count < 80 else { return nil }
        // --- Timer (before the "and" check: "1 hour and 30 minutes") ---
        if matches(text, #"^(?:pause|hold) (?:the |my )?timer$"#) {
            return Command(tool: "timer", arguments: ["action": "pause"])
        }
        if matches(text, #"^(?:resume|continue|unpause|restart) (?:the |my )?timer$"#) {
            return Command(tool: "timer", arguments: ["action": "resume"])
        }
        if matches(text, #"^(?:cancel|stop|end|clear|delete|remove) (?:the |my )?timer$"#) {
            return Command(tool: "timer", arguments: ["action": "cancel"])
        }
        if matches(text, #"^(?:how (?:much time|long) (?:is )?left|time left)(?: on (?:the |my )?timer)?$"#) {
            return Command(tool: "timer", arguments: ["action": "status"])
        }
        // "add 5 minutes" — only with a unit or the word timer, so "add 2
        // eggs to my list" stays a job for the model.
        if text.hasPrefix("add "),
           ["timer", "min", "hour", "hr", "sec"].contains(where: { text.contains($0) }),
           let seconds = NotchTimer.duration(in: text) {
            return Command(tool: "timer", arguments: ["action": "add", "minutes": seconds / 60])
        }
        // Shaped like a command ("set…", "timer…", "10 minute timer"), so
        // "find my timer screenshots from 3 days ago" stays a file search.
        if text.contains("timer") || text.hasPrefix("countdown"),
           matches(text, #"^(?:(?:set|start|make|put on|give me)\b|timer\b|countdown\b|\d|an? \d)"#) {
            // "timer 10 min", "set a timer for 25 minutes", "10 minute timer",
            // "timer 4 min for tea" — the part after " for " (once a
            // duration's been given) is the label.
            var spec = text
            var label = ""
            if let range = text.range(of: #" (?:for|called|named) (?![0-9]|half|a quarter)(.+)$"#, options: .regularExpression) {
                label = String(text[range]).replacingOccurrences(of: #"^ (?:for|called|named) "#, with: "",
                                                                 options: .regularExpression)
                spec = String(text[..<range.lowerBound])
            }
            if let seconds = NotchTimer.duration(in: spec) {
                var arguments: [String: Any] = ["action": "start", "minutes": seconds / 60]
                if !label.isEmpty { arguments["label"] = label }
                return Command(tool: "timer", arguments: arguments)
            }
        }

        // --- Screenshots on the Desktop into a folder (before the comma
        // check: speech writes "to the folder, called screenshots"). The
        // model invented paths for this twice and moved the wrong 30. ---
        let screenshotsMove = #"^(?:move|put) (?:all (?:of )?)?(?:my |the )?screen ?shots? (?:that are )?(?:on|from|in) "#
            + #"(?:the |my )?(?:desktop|downloads)(?: folder)?,? (?:to|into|in) (?:the |a |my )?(?:folder|directory)?,? ?"#
            + #"(?:called |named )?(.+?)(?: folder)?(?: (?:on|in) (?:the |my )?(?:desktop|downloads))?$"#
        if let folder = first(text, screenshotsMove), !folder.isEmpty,
           let from = first(text, #"(?:on|from|in) (?:the |my )?(desktop|downloads)"#) {
            return Command(tool: "collect_files",
                           arguments: ["query": "screenshot", "from": from, "folder": folder, "mode": "move"])
        }

        // More than one step is a job for the model.
        if text.contains(" and ") || text.contains(" then ") || text.contains(",") { return nil }

        // --- Sound ---
        if let level = first(text, #"^(?:set |turn |change )?(?:the )?(?:volume|sound)(?: level)? (?:to |at )?(\d{1,3})(?: ?%| percent)?$"#)
            ?? first(text, #"^(?:set |turn )?(?:the )?(?:volume|sound) (?:to )?(\d{1,3})$"#) {
            return Command(tool: "set_volume", arguments: ["level": Int(level) ?? 50])
        }
        if matches(text, #"^(?:turn (?:it |the volume |the sound )?up|volume up|louder|(?:make it |a bit |little )?louder|increase (?:the )?volume|raise (?:the )?volume)$"#) {
            return Command(tool: "volume_step", arguments: ["direction": "up"])
        }
        if matches(text, #"^(?:turn (?:it |the volume |the sound )?down|volume down|quieter|(?:make it |a bit |little )?quieter|softer|lower (?:the )?volume|decrease (?:the )?volume)$"#) {
            return Command(tool: "volume_step", arguments: ["direction": "down"])
        }
        if matches(text, #"^(?:mute|silence)(?: (?:the )?(?:sound|volume|mac|audio))?$"#) {
            return Command(tool: "mute", arguments: ["on": true])
        }
        if matches(text, #"^unmute(?: (?:the )?(?:sound|volume|mac|audio))?$"#) {
            return Command(tool: "mute", arguments: ["on": false])
        }

        // --- Music ---
        if matches(text, #"^(?:play|pause|resume|stop)(?: (?:the )?(?:music|song|track|it))?$"#) || text == "play pause" {
            return Command(tool: "media_control", arguments: ["action": "playpause"])
        }
        // "play coldplay", "play my running playlist", "play yellow on
        // apple music": straight to Music, no model.
        if let what = first(text, #"^(?:play|put on)(?: some)? (.+?)(?: (?:on|in|from) (?:apple )?music)?$"#),
           !["pause", "it", "music", "the music", "song", "the song", "track", "the track"].contains(what) {
            let name = what.replacingOccurrences(of: #"^(?:my |the )"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #" (?:playlist|album)$"#, with: "", options: .regularExpression)
            return Command(tool: "play_music", arguments: ["what": name])
        }
        if matches(text, #"^(?:next|skip)(?: (?:this )?(?:song|track|one))?$"#) {
            return Command(tool: "media_control", arguments: ["action": "next"])
        }
        if matches(text, #"^(?:previous|last|go back a)(?: (?:song|track|one))?$"#) {
            return Command(tool: "media_control", arguments: ["action": "previous"])
        }
        if matches(text, #"^what(?:'s| is) (?:playing|this song)(?: now)?$"#) {
            return Command(tool: "now_playing", arguments: [:])
        }

        // --- Time and battery ---
        if matches(text, #"^(?:what(?:'s| is) the )?(?:time|date)(?: is it)?(?: now)?$"#) || matches(text, #"^what (?:time|day) is it(?: now| today)?$"#) {
            return Command(tool: "tell_time", arguments: [:])
        }
        if matches(text, #"^(?:how much )?battery(?: level| left| status)?$"#) || matches(text, #"^how much battery(?: do i have)?(?: left)?$"#) {
            return Command(tool: "battery_status", arguments: [:])
        }

        // --- Web: opened in the default browser, one step ---
        // (Pip no longer drives the browser; these just open a page.)
        if let query = first(text, #"^(?:google|search (?:google|the web|online|the internet)(?: for)?|look up) (.+)$"#)
            ?? first(text, #"^search (?:for )?(.+) (?:on google|online|on the web)$"#) {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            return Command(tool: "open_website", arguments: ["url": "https://www.google.com/search?q=\(encoded)"])
        }
        if let site = first(text, #"^(?:open|go to|visit|load) ((?:https?://)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/\S*)?)$"#) {
            return Command(tool: "open_website", arguments: ["url": site])
        }

        // Pictures of something from the web ("my pictures of…" is your photos).
        if let subject = first(text, #"^(?:(?:show|get|find|give|display|pull up|bring up|search(?: for)?)(?: me)?(?: some| a few| the)? )?(?:pictures|picture|photos|photo|images|image|pics|pic) of (?!my |me |mine )(.+)$"#),
           subject.count >= 2 {
            return Command(tool: "web_search", arguments: ["query": subject, "kind": "images"])
        }

        // --- Screenshots: off the model's list, typed here ---
        if matches(text, #"^(?:take|grab) (?:a )?screenshot(?: of (?:the |this )?window)?$"#) {
            return Command(tool: "take_screenshot", arguments: ["target": text.hasSuffix("window") ? "window" : "screen"])
        }

        // --- Undo the last file change Pip made (see UndoLog) ---
        if matches(text, #"^(?:undo|undo (?:that|it|this|the (?:last|organi[sz]e|organi[sz]ing|renam(?:e|ing)|move))|put (?:them|it|everything|the files) back)(?: please)?$"#) {
            return Command(tool: "undo_files", arguments: [:])
        }

        // Files: searched straight away, no model.
        let aboutTheWeb = ["web", "online", "internet", "google", "youtube", "images of", "pictures of",
                           "photos of", "news", "weather", "price"].contains { text.contains($0) }
        if !aboutTheWeb,
           let what = first(text, #"^(?:find|search for|search my|look for|locate|where(?:'s| is| are| did i (?:put|save)))(?: me)?(?: my| the| a| an| that| this)? (.+?)(?: file| files| document)?(?: on my (?:mac|device|computer|laptop))?\??$"#),
           what.count >= 2 {
            return Command(tool: "find_files", arguments: ["query": what])
        }

        // --- Apps ---
        if let name = first(text, #"^(?:open|launch|start|run) (?:the )?(?:app )?(.+?)(?: app)?$"#),
           let app = InstalledApps.find(name) {
            return Command(tool: "open_app", arguments: ["name": app])
        }
        if let name = first(text, #"^(?:switch to|go to|show|bring up) (?:the )?(.+?)(?: app)?$"#),
           let app = InstalledApps.running(name) {
            return Command(tool: "switch_to_app", arguments: ["name": app])
        }
        if let name = first(text, #"^(?:quit|close|exit|kill) (?:the )?(.+?)(?: app)?$"#),
           !["window", "this window", "the window", "tab", "this tab"].contains(name),
           let app = InstalledApps.running(name) {
            return Command(tool: "quit_app", arguments: ["name": app])
        }
        return nil
    }

    // MARK: - Text

    /// Lowercased, without "hey Pip", "please", "can you" and end punctuation.
    static func normalize(_ input: String) -> String {
        var text = input.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let leading = #"^(?:(?:hey|hi|ok|okay) pip|pip|please|kindly|can you|could you|would you|will you|just|now|go ahead and|i want you to)[,\s]+"#
        let trailing = #"[,\s]+(?:please|for me|now|pip|thanks|thank you)$"#
        var previous = ""
        while previous != text {
            previous = text
            text = text.replacingOccurrences(of: leading, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: trailing, with: "", options: .regularExpression)
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?, "))
        }
        return text
    }

    /// A question only the web can answer, as the search to run before the
    /// model's first step. Nil for anything about your Mac, files or Pip.
    static func webQuestion(_ input: String) -> String? {
        // "do you know who is…", "can you tell me what…": the question is the rest.
        let text = normalize(input).replacingOccurrences(
            of: #"^(?:do (?:you|u) know|did (?:you|u) know|(?:can|could) (?:you|u) tell me) +"#,
            with: "", options: .regularExpression)
        guard !text.isEmpty, text.count < 120 else { return nil }
        let personal = [" my ", " me ", " i ", " this ", " that ", " it ", " here ", "screen", "file", "folder",
                        "document", "photo", "picture", "download", "desktop", "pip", " you ", " your "]
        // "tell me about X" is about X, not about "me".
        let padded = " " + text.replacingOccurrences(of: #"^tell me about "#, with: "", options: .regularExpression) + " "
        guard !personal.contains(where: padded.contains) else { return nil }
        // Conversions and sums go to the web too (owner: "all conversions or
        // questions always go through the web"): rates change, and the
        // results check the model's arithmetic.
        if text.hasPrefix("convert ")
            || text.range(of: #"^[\d.,]+\s*[a-z$€£¥₹%°]+[a-z.]*\s+(?:to|in|into)\s+[a-z$€£¥₹°]+"#, options: .regularExpression) != nil
            || text.range(of: #"^how many \w+ (?:in|are in|is in) "#, options: .regularExpression) != nil
            || text.range(of: #"^(?:(?:what is|what's|whats|calculate|how much is) )?[\d\s.,+\-*/x×÷%()]+(?: of [\d.,]+)?$"#,
                          options: .regularExpression) != nil {
            return text
        }
        // A file name ("what is in IMG_0533.jpg") is about the Mac, not the web.
        guard text.range(of: #"[\w-]\.[a-z0-9]{2,5}\b"#, options: .regularExpression) == nil else { return nil }
        if let topic = first(text, #"^(?:who (?:is|was|are|were)|what (?:is|was|are|were)|what's|when (?:is|was|did)|where (?:is|was)|how (?:old|tall|rich) (?:is|was)|tell me about|search (?:the web |online |the internet )?for) (.+)$"#),
           topic.count >= 2 {
            return topic
        }
        if ["weather", "news", "price of", "stock price", "score"].contains(where: text.contains) { return text }
        // Any other question about the world (owner, 2026-11-23: "all
        // questions go to web search"), searched as asked. Follow-ups that
        // lean on the last answer ("her most famous drama?") are the model's
        // to search, with the name filled in (its prompt says to).
        let words = text.split(separator: " ").map(String.init)
        let question = input.contains("?")
            || ["who", "what", "whats", "when", "where", "why", "how", "which", "is", "are", "was", "were", "does",
                "did", "do", "can", "could", "should", "tell", "explain", "describe", "define"].contains(words.first ?? "")
        let leaning: Set<String> = ["he", "she", "her", "his", "him", "they", "them", "their", "its", "these", "those",
                                    "more", "another", "else", "other", "also"]
        guard question, words.count >= 3, !words.contains(where: leaning.contains) else { return nil }
        return text
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The first capture group, if the pattern matches.
    private static func first(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }
}
