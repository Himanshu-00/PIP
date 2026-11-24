import Foundation

/// The time window a query names ("last month", "oct", "past 2 weeks"),
/// used as an early filter. A file's name counts too ("Invoice_SEP.jpg").
enum QueryTime {

    struct Window: Equatable, Sendable {
        let start: Date
        let end: Date
        /// Months the window covers (1–12), for matching month names in file
        /// names. Empty for windows of a year or more, where a month in a
        /// name says nothing.
        let months: Set<Int>
        /// Years the window covers, so "SEP_2024.pdf" isn't counted for
        /// September 2026.
        let years: Set<Int>
        let label: String
        /// A month named without a year ("around jan"): that month in *any*
        /// year. Taking only the latest January hid January 2025's photos.
        var anyYearMonth: Int? = nil

        /// Whether a file belongs: changed or created inside the window, or
        /// named for one of its months (and not for another year).
        func contains(modified: Date?, created: Date?, name: String) -> Bool {
            if let month = anyYearMonth {
                let calendar = Calendar.current
                if let modified, calendar.component(.month, from: modified) == month { return true }
                if let created, calendar.component(.month, from: created) == month { return true }
                return QueryTime.nameDates(name).months.contains(month)
            }
            if let modified, modified >= start, modified <= end { return true }
            if let created, created >= start, created <= end { return true }
            guard !months.isEmpty else { return false }
            let named = QueryTime.nameDates(name)
            guard !named.months.isDisjoint(with: months) else { return false }
            return named.years.isEmpty || !named.years.isDisjoint(with: years)
        }
    }

    // MARK: - Parsing

    private static let monthNames: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
        "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9,
        "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]

    /// A month name or a year — words that say when, not what a file contains.
    static func isTimeWord(_ word: String) -> Bool {
        if monthNames[word] != nil { return true }
        if word.count == 4, let year = Int(word), (1990...2100).contains(year) { return true }
        return false
    }

    /// The window the text describes, or nil when it doesn't say when.
    static func window(in text: String, now: Date = Date(), calendar: Calendar = .current) -> Window? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let joined = " " + words.joined(separator: " ") + " "
        let today = calendar.startOfDay(for: now)

        func make(_ start: Date, _ end: Date, _ label: String) -> Window {
            var months = Set<Int>()
            var years = Set<Int>()
            // Months only for windows under about four months.
            if end.timeIntervalSince(start) < 120 * 86_400 {
                var cursor = start
                while cursor <= end {
                    months.insert(calendar.component(.month, from: cursor))
                    years.insert(calendar.component(.year, from: cursor))
                    guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
                    cursor = next
                }
                months.insert(calendar.component(.month, from: end))
            }
            years.insert(calendar.component(.year, from: start))
            years.insert(calendar.component(.year, from: end))
            return Window(start: start, end: end, months: months, years: years, label: label)
        }
        func interval(_ unit: Calendar.Component, containing date: Date) -> DateInterval? {
            calendar.dateInterval(of: unit, for: date)
        }
        func unit(_ word: String) -> Calendar.Component? {
            switch word {
            case "day", "days": return .day
            case "week", "weeks": return .weekOfYear
            case "month", "months": return .month
            case "year", "years": return .year
            default: return nil
            }
        }

        if joined.contains(" today ") { return make(today, now, "today") }
        if joined.contains(" yesterday "), let start = calendar.date(byAdding: .day, value: -1, to: today) {
            return make(start, today.addingTimeInterval(-1), "yesterday")
        }
        for (phrase, component) in [("week", Calendar.Component.weekOfYear), ("month", .month), ("year", .year)] {
            if joined.contains(" this \(phrase) "), let current = interval(component, containing: now) {
                return make(current.start, now, "this \(phrase)")
            }
            if joined.contains(" last \(phrase) ") || joined.contains(" previous \(phrase) "),
               let earlier = calendar.date(byAdding: component, value: -1, to: now),
               let previous = interval(component, containing: earlier) {
                return make(previous.start, previous.end.addingTimeInterval(-1), "last \(phrase)")
            }
        }
        // "3 days ago", "2 weeks ago": that day / week / month.
        for index in words.indices.dropLast(2) where words[index + 2] == "ago" {
            if let count = Int(words[index]), count > 0, count < 400, let component = unit(words[index + 1]),
               let then = calendar.date(byAdding: component, value: -count, to: now),
               let span = interval(component == .day ? .day : component, containing: then) {
                return make(span.start, span.end.addingTimeInterval(-1), "\(count) \(words[index + 1]) ago")
            }
        }
        // "past 2 weeks", "last 10 days": up to now.
        for index in words.indices.dropLast(2) where ["past", "last"].contains(words[index]) {
            if let count = Int(words[index + 1]), count > 0, count < 400, let component = unit(words[index + 2]),
               let start = calendar.date(byAdding: component, value: -count, to: today) {
                return make(start, now, "past \(count) \(words[index + 2])")
            }
        }
        // A month name, perhaps with a year: "oct", "september 2026", "in march".
        let currentYear = calendar.component(.year, from: now)
        for (index, word) in words.enumerated() {
            guard let month = monthNames[word] else { continue }
            let next = index + 1 < words.count ? words[index + 1] : ""
            let previous = index > 0 ? words[index - 1] : ""
            let statedYear = Int(next).flatMap { (1990...2100).contains($0) ? $0 : nil }
                ?? Int(previous).flatMap { (1990...2100).contains($0) ? $0 : nil }
            // "may" is usually a verb: a month only beside a year or "in/from/of".
            if word == "may", statedYear == nil, !["in", "from", "of", "during", "since"].contains(previous) {
                continue
            }
            // "march" as a verb is rare enough to accept.
            // No year said: that month in any year.
            guard let year = statedYear else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM"
                let name = formatter.monthSymbols.indices.contains(month - 1)
                    ? String(formatter.shortMonthSymbols[month - 1]) : word
                return Window(start: .distantPast, end: now, months: [month], years: [],
                              label: "\(name) (any year)", anyYearMonth: month)
            }
            var parts = DateComponents()
            parts.year = year
            parts.month = month
            parts.day = 1
            guard let first = calendar.date(from: parts), let span = interval(.month, containing: first) else { continue }
            let end = min(span.end.addingTimeInterval(-1), now)
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM yyyy"
            return make(span.start, end, formatter.string(from: span.start))
        }
        // "in 2025", "from 2024": the whole year.
        for index in words.indices.dropLast() where ["in", "from", "during"].contains(words[index]) {
            if let year = Int(words[index + 1]), (1990...currentYear).contains(year) {
                var parts = DateComponents()
                parts.year = year
                parts.month = 1
                parts.day = 1
                if let first = calendar.date(from: parts), let span = interval(.year, containing: first) {
                    return make(span.start, min(span.end.addingTimeInterval(-1), now), "\(year)")
                }
            }
        }
        return nil
    }

    /// Months and years a file name mentions: "Invoice_SEP.jpg" → [9];
    /// "Statement_Oct_2025.pdf" → [10], [2025].
    static func nameDates(_ name: String) -> (months: Set<Int>, years: Set<Int>) {
        // Letters and digits apart, so "SEP15" is "sep" and "15".
        var pieces: [String] = []
        var current = ""
        var lastWasDigit: Bool?
        for character in name.lowercased() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { pieces.append(current) }
                current = ""
                lastWasDigit = nil
                continue
            }
            let isDigit = character.isNumber
            if let lastWasDigit, lastWasDigit != isDigit, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current.append(character)
            lastWasDigit = isDigit
        }
        if !current.isEmpty { pieces.append(current) }

        var months = Set<Int>()
        var years = Set<Int>()
        for piece in pieces {
            if let month = monthNames[piece] { months.insert(month) }
            if piece.count == 4, let year = Int(piece), (1990...2100).contains(year) { years.insert(year) }
        }
        return (months, years)
    }
}
