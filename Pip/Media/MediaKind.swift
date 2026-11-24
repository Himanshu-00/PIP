import AppKit

/// Music or video: by app (lists below), else by length against a threshold.
/// Design notes: Docs/history/Media.md.
enum MediaKind: Equatable {
    case music
    case video
}

enum MediaClassifier {

    /// Apps that are never music.
    private static let videoApps: Set<String> = [
        "com.apple.QuickTimePlayerX",
        "com.apple.TV",
        "com.colliderli.iina",
        "org.videolan.vlc",
        "io.mpv",
        "tv.plex.desktop",
        "com.plexapp.plex",
        "com.firecore.infuse",
        "com.netflix.Netflix",
    ]

    /// Apps that are always music, whatever the length.
    private static let musicApps: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.iTunes",
        "com.apple.podcasts",
        "com.tidal.desktop",
        "com.deezer.deezer-desktop",
        "com.soundcloud.desktop",
        "co.hyperkey.doppler",
        "com.github.th-ch.youtube-music",
    ]

    /// A browser (or any unlisted app) with no duration yet: often the
    /// first update of a long video, before its length arrives.
    static func isUnsure(_ track: NowPlaying, longerThan minutes: Int) -> Bool {
        minutes > 0 && track.duration <= 0
            && !musicApps.contains(track.bundleID) && !videoApps.contains(track.bundleID)
    }

    /// `longerThan` is in minutes; 0 means never hide anything.
    static func kind(for track: NowPlaying, longerThan minutes: Int) -> MediaKind {
        if musicApps.contains(track.bundleID) { return .music }
        if videoApps.contains(track.bundleID) { return .video }

        guard minutes > 0 else { return .music }
        // No duration (live radio): music.
        guard track.duration > 0 else { return .music }

        return track.duration > Double(minutes) * 60 ? .video : .music
    }
}
