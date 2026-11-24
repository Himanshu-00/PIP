import AppKit

/// Without `media-control`: now-playing through `osascript` (MediaRemote,
/// system-wide) and Spotify / Music scripting; playback control; seeking.
/// Design notes: Docs/history/Media.md.
enum ScriptBridge {

    // MARK: - Shell

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 4) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return (-1, "") }

        // A watchdog ends a hung process; the read then returns.
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()

        let text = String(data: data, encoding: .utf8) ?? ""
        return (task.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func osascript(_ source: String, language: String? = nil) -> String {
        var args: [String] = []
        if let language { args += ["-l", language] }
        args += ["-e", source]
        return run("/usr/bin/osascript", args).output
    }

    // MARK: - System-wide (MediaRemote via an entitled Apple binary)

    private static let jxaNowPlaying = """
    ObjC.import('Foundation');
    function run() {
      var fw = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
      if (!fw.load) { return 'null'; }
      var out = {};
      try {
        var path = $.MRNowPlayingRequest.localNowPlayingPlayerPath;
        if (path && !path.isNil()) {
          var client = path.client;
          if (client && !client.isNil()) {
            out.bundleIdentifier = ObjC.unwrap(client.bundleIdentifier) || '';
          }
        }
      } catch (e) { out.bundleIdentifier = ''; }
      try {
        var item = $.MRNowPlayingRequest.localNowPlayingItem;
        if (!item || item.isNil()) { return 'null'; }
        var info = item.nowPlayingInfo;
        if (!info || info.isNil()) { return 'null'; }
        var get = function (key) {
          var v = info.objectForKey(key);
          if (!v || v.isNil()) { return null; }
          return ObjC.unwrap(v);
        };
        out.title = get('kMRMediaRemoteNowPlayingInfoTitle') || '';
        out.artist = get('kMRMediaRemoteNowPlayingInfoArtist') || '';
        out.album = get('kMRMediaRemoteNowPlayingInfoAlbum') || '';
        out.duration = get('kMRMediaRemoteNowPlayingInfoDuration') || 0;
        out.elapsedTime = get('kMRMediaRemoteNowPlayingInfoElapsedTime') || 0;
        out.playing = (get('kMRMediaRemoteNowPlayingInfoPlaybackRate') || 0) > 0;
      } catch (e) { return 'null'; }
      if (!out.title) { return 'null'; }
      return JSON.stringify(out);
    }
    """

    static func systemNowPlaying() -> [String: Any]? {
        let output = osascript(jxaNowPlaying, language: "JavaScript")
        guard !output.isEmpty, output != "null",
              let data = output.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    // MARK: - Player-specific

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static let sep = "|~|"

    static func spotify() -> [String: Any]? {
        guard isRunning("com.spotify.client") else { return nil }
        let script = """
        tell application id "com.spotify.client"
            if player state is stopped then return ""
            set theURL to ""
            try
                set theURL to artwork url of current track
            end try
            return (player state as text) & "\(sep)" & (name of current track) & "\(sep)" & \
                   (artist of current track) & "\(sep)" & (album of current track) & "\(sep)" & \
                   ((duration of current track) / 1000 as text) & "\(sep)" & (player position as text) & "\(sep)" & theURL
        end tell
        """
        return parsePlayer(osascript(script), bundleID: "com.spotify.client")
    }

    static func appleMusic() -> [String: Any]? {
        guard isRunning("com.apple.Music") else { return nil }
        let script = """
        tell application id "com.apple.Music"
            if player state is stopped then return ""
            return (player state as text) & "\(sep)" & (name of current track) & "\(sep)" & \
                   (artist of current track) & "\(sep)" & (album of current track) & "\(sep)" & \
                   (duration of current track as text) & "\(sep)" & (player position as text) & "\(sep)" & ""
        end tell
        """
        return parsePlayer(osascript(script), bundleID: "com.apple.Music")
    }

    private static func parsePlayer(_ output: String, bundleID: String) -> [String: Any]? {
        let parts = output.components(separatedBy: sep)
        guard parts.count >= 6, !parts[1].isEmpty else { return nil }
        return [
            "bundleIdentifier": bundleID,
            "playing": parts[0].lowercased() == "playing",
            "title": parts[1],
            "artist": parts[2],
            "album": parts[3],
            "duration": Double(parts[4]) ?? 0,
            "elapsedTime": Double(parts[5]) ?? 0,
            "artworkURL": parts.count > 6 ? parts[6] : ""
        ]
    }

    /// Album art for Apple Music, exported to a temp file (AppleScript can't hand back raw data).
    static func appleMusicArtwork() -> NSImage? {
        guard isRunning("com.apple.Music") else { return nil }
        let path = NSTemporaryDirectory() + "dynamicnotch-artwork.tiff"
        let script = """
        tell application id "com.apple.Music"
            if player state is stopped then return ""
            try
                set theArt to (get raw data of artwork 1 of current track)
            on error
                return ""
            end try
        end tell
        set theFile to open for access POSIX file "\(path)" with write permission
        set eof theFile to 0
        write theArt to theFile
        close access theFile
        return "ok"
        """
        guard osascript(script) == "ok" else { return nil }
        defer { try? FileManager.default.removeItem(atPath: path) }
        return NSImage(contentsOfFile: path)
    }

    // MARK: - Playback control

    /// Jump to an absolute position, in seconds.
    static func seek(to seconds: Double, bundleID: String) {
        let target = max(0, seconds)
        switch bundleID {
        case "com.spotify.client" where isRunning("com.spotify.client"):
            _ = osascript("tell application id \"com.spotify.client\" to set player position to \(target)")

        case "com.apple.Music" where isRunning("com.apple.Music"):
            _ = osascript("tell application id \"com.apple.Music\" to set player position to \(target)")

        default:
            guard let binary = MediaControlStream.locateBinary() else { return }
            // Plain seconds (microseconds jumped to the end of the track).
            _ = run(binary, ["seek", String(format: "%.2f", target)])
        }
    }

    /// Play/pause, next, previous: the player's own scripting, else
    /// `media-control`, else media keys (which need Accessibility).
    @discardableResult
    static func control(_ command: PlaybackCommand, bundleID: String) -> String {
        switch bundleID {
        case "com.spotify.client" where isRunning("com.spotify.client"):
            _ = osascript("tell application id \"com.spotify.client\" to \(command.appleScriptVerb)")
            return "applescript"
        case "com.apple.Music" where isRunning("com.apple.Music"):
            _ = osascript("tell application id \"com.apple.Music\" to \(command.appleScriptVerb)")
            return "applescript"
        default:
            break
        }

        if let binary = MediaControlStream.locateBinary() {
            for verb in command.mediaControlVerbs where run(binary, [verb], timeout: 4).status == 0 {
                return "media-control \(verb)"
            }
        }

        MediaKeys.post(command.mediaKey)
        return MediaKeys.isTrusted ? "media key" : "media key (NOT TRUSTED — no Accessibility permission)"
    }
}

enum PlaybackCommand: Equatable {
    case playPause, next, previous

    var appleScriptVerb: String {
        switch self {
        case .playPause: return "playpause"
        case .next:      return "next track"
        case .previous:  return "previous track"
        }
    }

    /// Subcommand spellings across CLI releases, tried in order.
    var mediaControlVerbs: [String] {
        switch self {
        case .playPause: return ["toggle-play-pause", "playpause", "toggle", "play-pause"]
        case .next:      return ["next-track", "next", "skip-next"]
        case .previous:  return ["previous-track", "previous", "skip-previous"]
        }
    }

    var mediaKey: MediaKeys.Key {
        switch self {
        case .playPause: return .playPause
        case .next:      return .next
        case .previous:  return .previous
        }
    }
}
