import Foundation

/// One track as the media sources report it.
struct NowPlaying: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var bundleID: String = ""
    var isPlaying: Bool = false
    var duration: Double = 0            // seconds
    var elapsed: Double = 0             // seconds, at `elapsedAt`
    var elapsedAt: Date = .now
    var artworkFingerprint: String = "" // changes when the artwork changes

    var isValid: Bool { !title.isEmpty }

    /// The position now, extrapolated from the last report.
    func currentElapsed() -> Double {
        guard duration > 0 else { return 0 }
        let drift = isPlaying ? Date().timeIntervalSince(elapsedAt) : 0
        return min(max(elapsed + drift, 0), duration)
    }

    var appName: String {
        switch bundleID {
        case "com.spotify.client":          return "Spotify"
        case "com.apple.Music":             return "Music"
        case "com.apple.WebKit.GPU",
             "com.apple.Safari":            return "Safari"
        case "com.google.Chrome":           return "Chrome"
        case "com.apple.podcasts":          return "Podcasts"
        case "com.colliderli.iina":         return "IINA"
        case "org.videolan.vlc":            return "VLC"
        case "com.apple.QuickTimePlayerX":  return "QuickTime"
        case "com.github.th-ch.youtube-music": return "YouTube Music"
        case "company.thebrowser.Browser":  return "Arc"
        case "com.apple.TV":                return "TV"
        case "com.brave.Browser":           return "Brave"
        case "org.mozilla.firefox":         return "Firefox"
        case "com.microsoft.edgemac":       return "Edge"
        case "tv.plex.desktop":             return "Plex"
        case "com.tidal.desktop":           return "TIDAL"
        default:
            guard !bundleID.isEmpty else { return "" }
            return bundleID.split(separator: ".").last.map(String.init)?.capitalized ?? bundleID
        }
    }

    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
