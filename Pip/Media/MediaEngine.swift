import AppKit
import SwiftUI
import Combine

/// What's playing now, best source first: the `media-control` stream (every
/// app, artwork), else polling Spotify / Music scripting and MediaRemote via
/// `osascript`. Design notes: Docs/history/Media.md.
@MainActor
final class MediaEngine: ObservableObject {

    @Published private(set) var now: NowPlaying?
    @Published private(set) var artwork: NSImage?
    /// Colour pulled from the current album art, for tinting the island.
    /// White when there's no artwork, so nothing looks broken.
    @Published private(set) var accent: Color = .white
    /// Music or video, by length and by app. Recomputed when the track changes
    /// or the threshold is moved.
    @Published private(set) var kind: MediaKind = .music
    /// False for about a second after a new track with no duration from an
    /// unlisted app (a browser): its length often comes in the next update.
    /// Only holds back *showing* the island; live radio shows after the wait.
    @Published private(set) var settled = true
    private var settleTask: Task<Void, Never>?
    /// Minutes past which browser media counts as something you're watching.
    /// 0 disables the rule.
    var videoThresholdMinutes = 0 {
        didSet { if videoThresholdMinutes != oldValue { reclassify() } }
    }

    private var stream: MediaControlStream?
    private var pollTimer: Timer?
    private var artworkTask: Task<Void, Never>?
    /// Which track we've already tried to fetch a remote cover for.
    private var fetchedArtworkFor: String?
    private let pollQueue = DispatchQueue(label: "com.himanshu.dynamicnotch.poll")

    // MARK: - Lifecycle

    func start() {
        stop()
        if let binary = MediaControlStream.locateBinary() {
            startStream(binary: binary)
        } else {
            startPolling()
        }
    }

    func stop() {
        stream?.stop()
        stream = nil
        pollTimer?.invalidate()
        pollTimer = nil
        artworkTask?.cancel()
    }

    // MARK: - Route 1: media-control

    private func startStream(binary: String) {
        let stream = MediaControlStream(binary: binary)
        stream.onPayload = { [weak self] payload in
            Task { @MainActor in self?.apply(payload: payload, allowsArtworkData: true) }
        }
        stream.onFailure = { [weak self] in
            Task { @MainActor in
                guard let self, self.stream != nil else { return }
                self.stream = nil
                self.startPolling()
            }
        }
        self.stream = stream
        stream.start()
    }

    // MARK: - Route 2/3: polling

    /// Each poll launches osascript, so it backs off when nothing plays.
    private var pollInterval: TimeInterval { now?.isPlaying == true ? 2.5 : 8 }

    private func startPolling() {
        pollTimer?.invalidate()
        poll()
        scheduleNextPoll()
    }

    private func scheduleNextPoll() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isSuspended else { return }
                self.poll()
                self.scheduleNextPoll()
            }
        }
        timer.tolerance = pollInterval * 0.25   // let the OS coalesce wakeups
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Suspend / resume

    private(set) var isSuspended = false

    /// Sleep or screen lock: the stream and every timer stop.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        stream?.stop()
        stream = nil
        pollTimer?.invalidate()
        pollTimer = nil
        artworkTask?.cancel()
        now = nil
        setArtwork(nil, key: "")
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        start()
    }

    private func poll() {
        pollQueue.async { [weak self] in
            // Player-specific first: it also gives us artwork.
            var payload = ScriptBridge.spotify() ?? ScriptBridge.appleMusic()
            if payload == nil || (payload?["playing"] as? Bool) != true {
                if let system = ScriptBridge.systemNowPlaying() {
                    // Prefer the system answer when it points at a different app
                    // (e.g. a YouTube tab) or when nothing local is playing.
                    let systemBundle = system["bundleIdentifier"] as? String ?? ""
                    let localBundle = payload?["bundleIdentifier"] as? String ?? ""
                    if payload == nil || systemBundle != localBundle {
                        payload = system
                    }
                }
            }
            let snapshot = payload
            Task { @MainActor in self?.apply(payload: snapshot, allowsArtworkData: false) }
        }
    }

    // MARK: - Applying payloads

    private func apply(payload: [String: Any]?, allowsArtworkData: Bool) {
        guard let payload, let title = payload["title"] as? String, !title.isEmpty else {
            if now != nil { now = nil; setArtwork(nil, key: ""); kind = .music }
            return
        }

        var track = NowPlaying()
        track.title = title
        track.artist = payload["artist"] as? String ?? ""
        track.album = payload["album"] as? String ?? ""
        track.bundleID = payload["bundleIdentifier"] as? String ?? ""
        track.isPlaying = payload["playing"] as? Bool ?? false
        track.duration = Self.double(payload["duration"])
        track.elapsed = Self.double(payload["elapsedTime"])
        track.elapsedAt = Self.timestamp(payload["timestamp"]) ?? .now
        track.artworkFingerprint = "\(track.title)|\(track.artist)|\(track.album)"

        let trackChanged = now?.artworkFingerprint != track.artworkFingerprint
        // Kind before the track, so the island never pairs a new track with the old kind.
        let nextKind = MediaClassifier.kind(for: track, longerThan: videoThresholdMinutes)
        if nextKind != kind || trackChanged {
            ActivityLog.write(.system, "media: \(track.bundleID) \(Int(track.duration)) s → \(nextKind)")
        }
        // A browser's first lengths aren't the video's: Brave said 0 s, then
        // 300 s, and only 3 s later 3841 s — music flashed up and closed. A
        // new track there that looks like music waits a few seconds first.
        let maybeVideo = nextKind == .music && videoThresholdMinutes > 0 && MediaClassifier.isUnlisted(track)
        if MediaClassifier.isUnsure(track, longerThan: videoThresholdMinutes) || (maybeVideo && (trackChanged || !settled)) {
            if trackChanged || settleTask == nil { waitForDuration(seconds: maybeVideo ? 4 : 1) }
        } else {
            settle()
        }
        if nextKind != kind { kind = nextKind }
        now = track

        if trackChanged {
            setArtwork(nil, key: track.artworkFingerprint)
            fetchedArtworkFor = nil
        }

        // Artwork often arrives a payload after the track: taken whenever it comes.
        if artwork == nil,
           allowsArtworkData,
           let base64 = payload["artworkData"] as? String,
           let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
           let image = NSImage(data: data) {
            setArtwork(image, key: track.artworkFingerprint)
            return
        }

        // A remote cover is fetched once per track.
        if artwork == nil, fetchedArtworkFor != track.artworkFingerprint {
            fetchedArtworkFor = track.artworkFingerprint
            loadArtworkFallback(for: track, urlString: payload["artworkURL"] as? String)
        }
    }

    private func loadArtworkFallback(for track: NowPlaying, urlString: String?) {
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            var image: NSImage?

            if let urlString, let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true {
                if let (data, _) = try? await URLSession.shared.data(from: url) {
                    image = NSImage(data: data)
                }
            }
            if image == nil, track.bundleID == "com.apple.Music" {
                image = await Task.detached { ScriptBridge.appleMusicArtwork() }.value
            }

            guard !Task.isCancelled, let image else { return }
            await MainActor.run { [weak self] in
                guard let self, self.now?.artworkFingerprint == track.artworkFingerprint else { return }
                self.setArtwork(image, key: track.artworkFingerprint)
            }
        }
    }

    private func reclassify() {
        guard let now else { settle(); kind = .music; return }
        let next = MediaClassifier.kind(for: now, longerThan: videoThresholdMinutes)
        if next != kind { kind = next }
    }

    private func waitForDuration(seconds: Int = 1) {
        settleTask?.cancel()
        if settled { settled = false }
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    private func settle() {
        settleTask?.cancel()
        settleTask = nil
        if !settled { settled = true }
    }

    /// Artwork and its accent colour change together (views animate the accent).
    private func setArtwork(_ image: NSImage?, key: String) {
        artwork = image
        accent = image.map { ArtworkColour.accent(from: $0, key: key) } ?? .white
    }

    // MARK: - Controls

    /// Seek to a fraction (0...1) of the current track.
    func seek(toFraction fraction: Double) {
        guard var track = now, track.duration > 0 else { return }
        // Never land exactly on the end — some players treat that as "next track".
        let target = min(min(max(fraction, 0), 1) * track.duration, track.duration - 0.5)
        let bundleID = track.bundleID

        // Move the bar immediately; the player will catch up.
        track.elapsed = target
        track.elapsedAt = .now
        now = track

        DispatchQueue.global(qos: .userInitiated).async {
            ScriptBridge.seek(to: target, bundleID: bundleID)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Task { @MainActor in
                guard let self, self.stream == nil else { return }
                self.poll()
            }
        }
    }

    func send(_ command: PlaybackCommand) {
        let bundleID = now?.bundleID ?? ""
        let route = ScriptBridge.control(command, bundleID: bundleID)
        ActivityLog.write(.system, "media: \(command) via \(route) [\(bundleID)]")

        // Optimistic UI so the button feels instant.
        if command == .playPause, var track = now {
            track.elapsed = track.currentElapsed()
            track.elapsedAt = .now
            track.isPlaying.toggle()
            now = track
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            Task { @MainActor in
                guard let self, self.stream == nil else { return }
                self.poll()
            }
        }
    }

    // MARK: - Helpers

    private static func double(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    /// `media-control` emits an ISO-8601 timestamp for when `elapsedTime` was sampled.
    private static func timestamp(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

