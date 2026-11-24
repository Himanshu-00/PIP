import AppKit
import SwiftUI

/// An explanation in Pip's reply (headline, paragraph, up to three points,
/// one key phrase), or plain text with the markdown removed. Also measures
/// the layout's height.
struct PipExplanation: Equatable {

    var headline: String
    var body: String
    var points: [String]
    /// A line after the points ("Let me know if you want more").
    var closing = ""

    /// Text column: the most it's ever set at (lines stay readable).
    static let maxWidth: CGFloat = 640
    /// Taller than this, it scrolls with a fade at the bottom.
    static let maxHeight: CGFloat = 300
    /// 15.5 semibold, body 13.5 (owner, 2026-11-22: smaller again; 20 bold
    /// and 14.5, then 17 and 14, the same day — the mockup's panel is twice
    /// as wide as Pip's).
    static let headlineSize: CGFloat = 15.5
    static let headlineWeight: NSFont.Weight = .semibold
    static let bodySize: CGFloat = 13.5
    static let bodyLineSpacing: CGFloat = 3
    static let headlineGap: CGFloat = 6
    static let pointsGap: CGFloat = 10
    static let pointGap: CGFloat = 6
    /// The number badge and the gap after it.
    static let badge: CGFloat = 16
    static let badgeGap: CGFloat = 8

    // MARK: - Reading

    /// The explanation in `reply`, or nil. `streaming`: still being written;
    /// `shapeKnown`: the full reply is one already; `expected`: the question
    /// asked for one, so a one-line reply stays formatted.
    ///
    /// A finished reply that fails the full check falls back to the check
    /// used while it was being written, so nothing laid out live ever goes
    /// back to plain text at the end.
    static func parse(_ reply: String, streaming: Bool = false, shapeKnown: Bool = false,
                      expected: Bool = false) -> PipExplanation? {
        if let shaped = read(reply, streaming: streaming, shapeKnown: shapeKnown, expected: expected) {
            return shaped
        }
        if streaming {
            // An unfinished last line that doesn't fit yet ("**Ac" of "Action
            // items:", the "2" of "2.") waits for the rest of its line.
            guard let cut = reply.lastIndex(where: \.isNewline), cut != reply.index(before: reply.endIndex)
            else { return nil }
            return read(String(reply[...cut]), streaming: true, shapeKnown: shapeKnown, expected: expected)
        }
        // Only a reply with lines, or one to an explain question: a one-line
        // answer ("Volume set to 40%.") stays plain.
        guard expected || reply.contains(where: \.isNewline) else { return nil }
        return read(reply + "\n", streaming: true, shapeKnown: expected, expected: expected)
    }

    private static func read(_ reply: String, streaming: Bool, shapeKnown: Bool,
                             expected: Bool) -> PipExplanation? {
        var lines = reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if streaming {
            // The first line isn't finished until its line break arrives.
            guard let first = lines.first, point(first) == nil else { return nil }
            guard shapeKnown || (reply.contains(where: \.isNewline)
                  && withoutLeadIn(first).split(whereSeparator: \.isWhitespace).count >= 4) else { return nil }
            if lines.count > 1, let last = lines.last,
               last.range(of: #"^([-*•]|\d{1,2}[.)])?$"#, options: .regularExpression) != nil {
                lines.removeLast()
            }
            if lines.count == 1 {
                let (head, rest) = firstSentence(first)
                return PipExplanation(headline: headlineText(head), body: rest.map(strip) ?? "", points: [])
            }
        }
        if expected, !streaming, lines.count == 1, point(lines[0]) == nil {
            let (head, rest) = firstSentence(lines[0])
            guard withoutLeadIn(head).split(whereSeparator: \.isWhitespace).count >= 3 else { return nil }
            return PipExplanation(headline: headlineText(head), body: rest.map(strip) ?? "", points: [])
        }
        guard lines.count >= 2, point(lines[0]) == nil else { return nil }
        // Several sentences on line 1: the first is the headline.
        let (head, rest) = firstSentence(lines[0])
        lines[0] = head
        if let rest { lines.insert(rest, at: 1) }
        var body: [String] = []
        var points: [String] = []
        var closing: [String] = []
        for line in lines.dropFirst() {
            // A short section label ("Action items:") among the points: skipped.
            if !points.isEmpty, isLabel(line) { continue }
            if let item = point(line), closing.isEmpty {
                points.append(item)
            } else if points.isEmpty {
                body.append(line)
            } else {
                // Text after the points closes it.
                closing.append(point(line) ?? line)
            }
        }
        // Three or more separate lines with no markers are a list written
        // plainly (a summary, one point a line); a paragraph comes as one line.
        if points.isEmpty, body.count >= 3 {
            points = body
            body = []
        }
        let headline = withoutLeadIn(lines[0])
        let headlineWords = headline.split(whereSeparator: \.isWhitespace).count
        let bodyWords = body.joined(separator: " ").split(whereSeparator: \.isWhitespace).count
        // Points, or a real paragraph under a real sentence: two short lines
        // ("Opened it.\nAnything else?") are just a reply.
        // No limits on length or count: past the window's height it scrolls,
        // and a limit is a reply that flips to plain text when it's crossed.
        guard streaming || !points.isEmpty || (headlineWords >= 4 && bodyWords >= 8) else { return nil }
        return PipExplanation(headline: headlineText(lines[0]), body: body.joined(separator: " "), points: points,
                              closing: closing.map(strip).joined(separator: " "))
    }

    /// "One. Two. Three" → ("One.", "Two. Three"); no rest for one sentence.
    private static func firstSentence(_ line: String) -> (String, String?) {
        guard let end = line.range(of: #"[.!?]["”')]?\s+(?=\S)"#, options: .regularExpression) else { return (line, nil) }
        let head = line[..<end.upperBound].trimmingCharacters(in: .whitespaces)
        let rest = line[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return (head, rest.isEmpty ? nil : rest)
    }

    /// The first line as shown: no lead-in, no markers, no full stop (mockup).
    private static func headlineText(_ line: String) -> String {
        let shown = strip(withoutLeadIn(line)).trimmingCharacters(in: .whitespaces)
        return shown.hasSuffix(".") && !shown.hasSuffix("..") ? String(shown.dropLast()) : shown
    }

    /// The explanation as it should look now, and whether it's done; spoken,
    /// it follows the voice, matched back onto the written text.
    static func live(written: String?, spoken: String?, synced: Bool, streaming: Bool,
                     expected: Bool = false) -> (explanation: PipExplanation, done: Bool)? {
        guard let written, !written.isEmpty else { return nil }
        // Still being written or said, and asked to explain: the shape is
        // taken as known from the start.
        let early = expected && (streaming || synced)
        if synced, early {
            guard let spoken, !spoken.isEmpty, let said = spokenPrefix(of: written, spoken: spoken) else { return nil }
            // Once it's all written, the written reply has the last word.
            if !streaming, parse(written, expected: true) == nil { return nil }
            return parse(said, streaming: true, shapeKnown: true).map { ($0, false) }
        }
        if early, streaming {
            return parse(written, streaming: true, shapeKnown: true).map { ($0, false) }
        }
        if synced {
            // Spoken: the written reply decides the shape, the voice what's shown.
            guard let spoken, !spoken.isEmpty, parse(written, streaming: streaming) != nil,
                  let said = spokenPrefix(of: written, spoken: spoken) else { return nil }
            return parse(said, streaming: true, shapeKnown: true).map { ($0, false) }
        }
        return parse(written, streaming: streaming, expected: expected).map { ($0, !streaming) }
    }

    /// The part of `written` that `spoken` covers, markers and spacing ignored.
    /// Nil if they don't line up.
    static func spokenPrefix(of written: String, spoken: String) -> String? {
        let skipped: Set<Character> = ["*", "#", "-", "•", "_", "`"]
        func ignored(_ character: Character) -> Bool { character.isWhitespace || skipped.contains(character) }
        var index = written.startIndex
        for character in spoken where !ignored(character) {
            while index < written.endIndex, ignored(written[index]) { index = written.index(after: index) }
            guard index < written.endIndex, written[index] == character else { return nil }
            index = written.index(after: index)
        }
        while index < written.endIndex, written[index].isWhitespace { index = written.index(after: index) }
        return String(written[..<index])
    }

    /// Whether a question asks for an explanation ("explain", "what is", "why"…),
    /// not for numbers or quick facts.
    static func expects(_ question: String?) -> Bool {
        guard let question = question?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !question.contains(where: \.isNumber) else { return false }
        let quick = ["weather", "time", "date", "today", "price", "cost", "score", "temperature", "my "]
        guard !quick.contains(where: question.contains) else { return false }
        return question.range(of: #"^(please |can you |could you |pip,? )?(explain|what (is|are|was|were|does|do)\b|what's (a|an|the)\b|how (does|do|did|is|are|can|would)\b(?! (you|u|ya|we)\b)|why\b|describe|tell me about|teach me|eli5|summari[sz]e)"#,
                              options: .regularExpression) != nil
    }

    /// "Action items:", "**Key points:**": a heading, not a sentence.
    private static func isLabel(_ line: String) -> Bool {
        let bare = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        return bare.hasSuffix(":") && bare.split(whereSeparator: \.isWhitespace).count <= 4
    }

    /// "- x", "* x", "• x" or "1. x" → "x".
    private static func point(_ line: String) -> String? {
        guard let range = line.range(of: #"^([-*•]|\d{1,2}[.)])\s+"#, options: .regularExpression) else { return nil }
        let item = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    /// "Based on the file, it's…" → "It's…", in case the model wrote one anyway.
    private static func withoutLeadIn(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #"(?i)^(based on [^,.]{0,80},|according to [^,.]{0,60},)\s*"#,
                                             with: "", options: .regularExpression)
        if let first = text.first, first.isLowercase { text = first.uppercased() + text.dropFirst() }
        return text
    }

    /// Markdown markers out: "**" and heading "#"s.
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
    }

    /// A reply that isn't an explanation, as plain text: no "**", and
    /// points as "• ".
    static func plain(_ reply: String) -> String {
        strip(reply).replacingOccurrences(of: #"(?m)^(\s*)[-*]\s+"#, with: "$1• ", options: .regularExpression)
    }

    /// The text with its first **key phrase** marked: (before, key, after).
    /// Any further ** are just taken out.
    static func keyPhrase(in text: String) -> (String, String?, String) {
        guard let open = text.range(of: "**"),
              let close = text.range(of: "**", range: open.upperBound..<text.endIndex),
              close.lowerBound > open.upperBound
        else { return (strip(text), nil, "") }
        return (strip(String(text[..<open.lowerBound])), String(text[open.upperBound..<close.lowerBound]),
                strip(String(text[close.upperBound...])))
    }

    // MARK: - Measuring

    /// The laid-out height at `width`, the way `PipView` sets it.
    func height(width: CGFloat) -> CGFloat {
        let width = min(width, Self.maxWidth)
        var total = Self.measure(headline, size: Self.headlineSize, weight: Self.headlineWeight, spacing: 0, width: width)
        if !body.isEmpty {
            total += Self.headlineGap + Self.measure(Self.strip(body), size: Self.bodySize, weight: .regular,
                                                     spacing: Self.bodyLineSpacing, width: width)
        }
        if !points.isEmpty {
            total += Self.pointsGap
            for (index, item) in points.enumerated() {
                let text = Self.measure(Self.strip(item), size: Self.bodySize, weight: .regular,
                                        spacing: Self.bodyLineSpacing, width: width - Self.badge - Self.badgeGap)
                total += max(text, Self.badge) + (index > 0 ? Self.pointGap : 0)
            }
        }
        if !closing.isEmpty {
            total += Self.pointsGap + Self.measure(Self.strip(closing), size: Self.bodySize, weight: .regular,
                                                   spacing: Self.bodyLineSpacing, width: width)
        }
        // Slack: SwiftUI's line heights round up a little differently.
        return ceil(total) + 4
    }

    private static func measure(_ text: String, size: CGFloat, weight: NSFont.Weight, spacing: CGFloat,
                                width: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = spacing
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .paragraphStyle: style,
        ])
        return ceil(attributed.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }
}

/// An explanation drawn: headline, paragraph, numbered points with dark grey
/// badges, the key phrase underlined. Pip's window and the click-to-ask
/// panel both use it; the sizes default to Pip's (which his window measures).
struct ExplanationLayout: View {

    let explanation: PipExplanation
    var headlineSize: CGFloat = PipExplanation.headlineSize
    var bodySize: CGFloat = PipExplanation.bodySize
    var bodyOpacity: Double = 0.75

    /// The key phrase's soft underline: Pip's violet.
    static let keyUnderline = Color(red: 0x8F / 255, green: 0x7D / 255, blue: 0xFF / 255)
    /// The points' number badges: dark grey.
    static let badgeFill = Color(white: 0.26)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(explanation.headline)
                .font(.system(size: headlineSize, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !explanation.body.isEmpty {
                Self.keyed(explanation.body)
                    .font(.system(size: bodySize))
                    .lineSpacing(PipExplanation.bodyLineSpacing)
                    .foregroundStyle(.white.opacity(bodyOpacity))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, PipExplanation.headlineGap)
            }
            if !explanation.points.isEmpty {
                VStack(alignment: .leading, spacing: PipExplanation.pointGap) {
                    ForEach(Array(explanation.points.enumerated()), id: \.offset) { index, point in
                        HStack(alignment: .top, spacing: PipExplanation.badgeGap) {
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: PipExplanation.badge, height: PipExplanation.badge)
                                .background(Circle().fill(Self.badgeFill))
                            Self.keyed(point)
                                .font(.system(size: bodySize))
                                .lineSpacing(PipExplanation.bodyLineSpacing)
                                .foregroundStyle(.white.opacity(bodyOpacity))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, PipExplanation.pointsGap)
            }
            if !explanation.closing.isEmpty {
                Self.keyed(explanation.closing)
                    .font(.system(size: bodySize))
                    .lineSpacing(PipExplanation.bodyLineSpacing)
                    .foregroundStyle(.white.opacity(bodyOpacity))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, PipExplanation.pointsGap)
            }
        }
    }

    /// The text with its **key phrase** in white, softly underlined; the
    /// markers never show.
    static func keyed(_ text: String) -> Text {
        let (before, key, after) = PipExplanation.keyPhrase(in: text)
        guard let key else { return Text(before) }
        return Text(before)
            + Text(key).foregroundColor(.white).underline(true, color: keyUnderline.opacity(0.7))
            + Text(after)
    }
}
