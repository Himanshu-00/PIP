import SwiftUI

/// A short-lived thing the island flashes and then forgets — the macOS
/// equivalent of the iPhone's charging / silent-mode / Face ID blips.
enum NotchEvent: Equatable {
    case pluggedIn(percent: Int)
    case fullyCharged
    case lowBattery(percent: Int)
    case downloaded(name: String)
    case copied(summary: String)
    case failed(what: String)
    /// A reminder the pet was asked to set.
    case reminder(text: String)
    /// Pip finished something while his window was closed: the start of his answer.
    case pipReplied(text: String)
    /// A long piece of text was copied: hover the notch and Pip summarises it.
    case copiedLong(words: Int, fromPhone: Bool)
    /// Click to ask is armed (⌥⇧A): what to do next, or what's missing.
    case hint(text: String)

    var symbol: String {
        switch self {
        case .pluggedIn:                    return "bolt.fill"
        case .fullyCharged:                 return "bolt.badge.checkmark.fill"
        case .lowBattery:                   return "battery.25"
        case .downloaded:                   return "arrow.down.circle.fill"
        case .copied:                       return "doc.on.clipboard.fill"
        case .failed:                       return "exclamationmark.triangle.fill"
        case .reminder:                     return "bell.fill"
        case .pipReplied:                   return "sparkles"
        case .copiedLong(_, let phone):     return phone ? "iphone" : "doc.text"
        // Click to ask's "on" light: a small dot in Pip's green, as macOS
        // shows the camera or mic in use — not a mark by the pointer.
        case .hint:                         return "circle.fill"
        }
    }

    /// Battery events: the charge as 0…1 and whether it's charging, for the
    /// drawn battery (`BatteryGlyph`). Nil for everything else.
    var battery: (level: Double, charging: Bool)? {
        switch self {
        case .pluggedIn(let p):  return (Double(p) / 100, true)
        case .fullyCharged:      return (1, true)
        case .lowBattery(let p): return (Double(p) / 100, false)
        default:                 return nil
        }
    }

    /// The glyph's point size: the hint's dot is small.
    var glyphSize: CGFloat {
        if case .hint = self { return 7 }
        return 13
    }

    var tint: Color {
        switch self {
        // Apple's own battery green and red.
        case .pluggedIn, .fullyCharged: return Color(red: 0.20, green: 0.84, blue: 0.29)
        case .lowBattery:               return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .downloaded:               return Color(red: 0.36, green: 0.68, blue: 1.0)
        case .copied:                   return Color(red: 0.36, green: 0.68, blue: 1.0)
        case .failed:                   return Color(red: 1.0, green: 0.37, blue: 0.34)
        case .reminder:                 return Color(red: 1.0, green: 0.72, blue: 0.3)
        case .pipReplied:               return Color(red: 0.66, green: 0.88, blue: 0.54)
        case .copiedLong:               return Color(red: 0.36, green: 0.68, blue: 1.0)
        case .hint:                     return Color(red: 0.66, green: 0.88, blue: 0.54)
        }
    }

    /// Shown between the glyph and the trailing value. Only the wider events
    /// have one — a percentage needs no explaining, a filename does.
    var title: String? {
        switch self {
        case .downloaded(let name):
            return name
        case .copied:
            return "Copied to clipboard"
        case .failed(let what):
            return what
        case .reminder(let text):
            return text
        case .pipReplied(let text):
            return text
        case .copiedLong(_, let phone):
            // Short: there's ~85 pt left of the camera ("Hover to summarise"
            // ran under the notch). The icon says whether it's from the iPhone.
            return "Summarise"
        case .hint(let text):
            // Empty: the dot alone (click to ask is on).
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    var trailing: String? {
        switch self {
        case .pluggedIn(let p), .lowBattery(let p): return "\(p)%"
        case .fullyCharged:                        return "100%"
        case .copied(let summary):                 return summary
        case .copiedLong(let words, _):            return "\(words) words"
        case .downloaded, .failed, .reminder, .pipReplied, .hint:  return nil
        }
    }

    /// How long it stays on screen.
    var duration: TimeInterval {
        switch self {
        case .lowBattery:   return 4.5
        case .downloaded:   return 3.5
        case .copied:       return 2.6
        case .failed:       return 4.0
        case .reminder:     return 8.0
        case .pipReplied:   return 6.0
        case .copiedLong:   return 7.0
        // As long as click to ask stays armed; disarming clears it sooner.
        case .hint:         return 10.0
        default:            return 2.8
        }
    }
}

/// A persistent glyph in the compact island — Pip thinking or talking.
///
/// Distinct from an event: an event happened, an indicator *is happening*, so
/// it stays for as long as it's true rather than timing out.
struct NotchIndicator: Equatable, Identifiable {
    var id: String
    var symbol: String
    var tint: Color
    /// Gently pulses — for something in progress, like Pip thinking.
    var pulses = false
}

/// One line of context at the bottom of the expanded island — a timer, or
/// the download that just landed — with a single button.
///
/// The action is excluded from equality because closures aren't Equatable, and
/// because `id` already changes whenever the action would mean something
/// different.
struct NotchUtility: Identifiable {
    var id: String
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
}

extension NotchUtility: Equatable {
    static func == (a: NotchUtility, b: NotchUtility) -> Bool {
        a.id == b.id && a.title == b.title && a.subtitle == b.subtitle
            && a.actionTitle == b.actionTitle && a.secondaryTitle == b.secondaryTitle
    }
}
