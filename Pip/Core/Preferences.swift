import SwiftUI

/// User-facing settings, persisted in UserDefaults.
/// Deliberately tiny — every option here is one the user actually asked for.
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    /// SF Symbols offered for the menu bar item.
    static let symbolChoices: [(title: String, symbol: String)] = [
        ("Notch",        "rectangle.tophalf.inset.filled"),
        ("Island",       "capsule.fill"),
        ("Waveform",     "waveform"),
        ("Note",         "music.note"),
        ("Circle",       "circle.dashed.inset.filled"),
        ("Sparkle",      "sparkles")
    ]

    private enum Key {
        static let symbol = "menuBarSymbol"
        static let showsTitle = "showsTitleInMenuBar"
        static let titleLength = "menuBarTitleLength"
        static let downloads = "watchesDownloads"
        static let videoMinutes = "hideMediaLongerThanMinutes"
        static let searchHotKey = "searchHotKeyIndex"
        static let hidesFullScreen = "hidesInFullScreen"
        static let opensPip = "searchOpensPip"
        static let suggestsFolders = "suggestsDownloadFolders"
    }

    /// Feature switches, on by default.
    private static let defaultsOn = [Key.downloads, Key.hidesFullScreen, Key.suggestsFolders]

    @Published var menuBarSymbol: String {
        didSet { defaults.set(menuBarSymbol, forKey: Key.symbol) }
    }

    /// Show the current track next to the menu bar glyph.
    @Published var showsTitleInMenuBar: Bool {
        didSet { defaults.set(showsTitleInMenuBar, forKey: Key.showsTitle) }
    }

    /// Which of `HotKeyCenter.choices` opens search.
    @Published var searchHotKeyIndex: Int {
        didSet { defaults.set(searchHotKeyIndex, forKey: Key.searchHotKey) }
    }

    /// Hide browser media longer than this many minutes. 0 shows everything.
    ///
    /// A threshold rather than a clever guess. macOS reports one now-playing
    /// for the whole machine and won't say what kind it is, and every attempt
    /// to infer it is wrong in some case someone cares about — so the rule is
    /// one you can state in a sentence and change when it's wrong for you.
    ///
    /// 8 minutes by default for new installs: long enough for a song or a
    /// music video, short enough to catch most YouTube videos and every film.
    /// A value already chosen is kept.
    @Published var hideMediaLongerThan: Int {
        didSet { defaults.set(hideMediaLongerThan, forKey: Key.videoMinutes) }
    }


    /// Collapse the island when something is running full screen.
    ///
    /// On by default, and switchable because the detection is a heuristic
    /// about other applications' windows and heuristics are wrong sometimes.
    /// A setting is cheaper than being wrong with no way out.
    @Published var hidesInFullScreen: Bool {
        didSet { defaults.set(hidesInFullScreen, forKey: Key.hidesFullScreen) }
    }

    @Published var watchesDownloads: Bool {
        didSet { defaults.set(watchesDownloads, forKey: Key.downloads) }
    }

    /// A finished download offers the folder files like it live in
    /// ("Move to Uni/BIO101?"). Never moves anything without the click.
    @Published var suggestsDownloadFolders: Bool {
        didSet { defaults.set(suggestsDownloadFolders, forKey: Key.suggestsFolders) }
    }

    /// How many characters of the title to show before truncating.
    @Published var menuBarTitleLength: Int {
        didSet { defaults.set(menuBarTitleLength, forKey: Key.titleLength) }
    }

    /// What the search shortcut opens: Pip, who you can just ask, or the
    /// full search panel with its list and detail card. Pip by default.
    @Published var searchOpensPip: Bool {
        didSet { defaults.set(searchOpensPip, forKey: Key.opensPip) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        menuBarSymbol = defaults.string(forKey: Key.symbol) ?? Self.symbolChoices[0].symbol
        showsTitleInMenuBar = defaults.bool(forKey: Key.showsTitle)
        let stored = defaults.integer(forKey: Key.titleLength)
        menuBarTitleLength = stored == 0 ? 24 : stored
        // integer(forKey:) returns 0 for a key that was never set, which is a
        // real index — so a non-zero default has to be written on first launch
        // rather than inferred.
        if defaults.object(forKey: Key.searchHotKey) == nil {
            defaults.set(HotKeyCenter.choices.count - 1, forKey: Key.searchHotKey)   // ⌥F
        }
        searchHotKeyIndex = defaults.integer(forKey: Key.searchHotKey)

        // bool(forKey:) returns false for a key that was never written, so
        // anything meant to default to ON has to be seeded rather than read.
        for key in Self.defaultsOn where defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
        }
        hidesInFullScreen = defaults.bool(forKey: Key.hidesFullScreen)
        watchesDownloads = defaults.bool(forKey: Key.downloads)
        suggestsDownloadFolders = defaults.bool(forKey: Key.suggestsFolders)
        if defaults.object(forKey: Key.videoMinutes) == nil {
            defaults.set(8, forKey: Key.videoMinutes)
        }
        hideMediaLongerThan = defaults.integer(forKey: Key.videoMinutes)
        if defaults.object(forKey: Key.opensPip) == nil {
            defaults.set(true, forKey: Key.opensPip)
        }
        searchOpensPip = defaults.bool(forKey: Key.opensPip)
    }
}
