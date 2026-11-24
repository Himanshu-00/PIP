import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var panel: NotchPanel?
    /// The screen setup the panel was built for (see `screenSetup`).
    private var panelScreens = ""
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?

    let state = NotchState()
    let engine = MediaEngine()
    let power = PowerMonitor()
    let prefs = Preferences.shared
    let search = SearchController()
    let occupancy = ScreenOccupancy()
    let downloads = DownloadsWatcher()
    let tidy = FileTidy()
    let screenshotTidy = ScreenshotTidy()
    let shelf = ScreenshotShelf()
    let indexer = ContentIndexer()
    let pet = Pet()
    private(set) lazy var agent = PetAgent(pet: pet, engine: engine, power: power)
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// The live explanation layout's last logged step (see the Pip sink).
    private var lastExplanationStep: String?
    /// This answer has gone wide: it stays wide until the next question.
    private var answerWent = false
    private(set) lazy var voice = VoiceController(agent: agent, search: search,
                                                  openPip: { [weak self] in self?.openPetIfNeeded() })

    #if DEBUG
    @objc private func runSearchChecks() {
        Task { await SearchChecks.run() }
    }

    private func captionNow(_ paths: String) {
        Task {
            for path in paths.split(separator: "|").map(String.init) {
                let url = URL(fileURLWithPath: path)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
                // Read (labels, OCR) first if the indexer hasn't yet; the caption goes on that row.
                _ = await TextExtractor().text(for: Candidate(url: url, displayName: url.lastPathComponent, modified: modified,
                                                              lastOpened: nil, useCount: 0, whereFrom: nil))
                let started = Date()
                let caption = await PhotoCaptions.caption(of: url) ?? "(failed)"
                let seconds = Date().timeIntervalSince(started)
                if let saved = await ContentStore.shared.setCaption(path: path, modified: modified, caption: caption) {
                    await SemanticIndex.shared.add(path: path, modified: modified, title: saved.title,
                                                   text: saved.text, replace: true)
                }
                ActivityLog.write(.search, String(format: "captions: %@ in %.1f s — %@", url.lastPathComponent, seconds, caption))
            }
        }
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        ActivityLog.write(.system, "Pip started")
        NSApp.setActivationPolicy(.accessory)

        // Before anything else. An orphan from a previous run holds its own
        // hotkeys and menu bar item, and two copies fighting over both looks
        // like a dozen unrelated bugs.
        SingleInstance.claim()

        buildStatusItem()
        buildPanel()
        engine.start()

        engine.videoThresholdMinutes = prefs.hideMediaLongerThan
        prefs.$hideMediaLongerThan
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] minutes in
                Task { @MainActor in self?.engine.videoThresholdMinutes = minutes }
            }
            .store(in: &cancellables)

        observeSystemPower()
        installHotKeys()
        observeSearch()
        startSensors()

        occupancy.start()

        // Polling only matters while there is something to hide. Plenty of
        // things go full screen without creating a space — a game, a video
        // player resizing a borderless window — and those fire no
        // notification at all, so the only way to notice is to look.
        Publishers.CombineLatest(state.$hasMedia, state.$indicators)
            .map { hasMedia, indicators in hasMedia || !indicators.isEmpty }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shows in
                Task { @MainActor in self?.occupancy.setIslandWouldShow(shows) }
            }
            .store(in: &cancellables)

        occupancy.$isFullScreen
            .combineLatest(prefs.$hidesInFullScreen)
            .map { full, hides in full && hides }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hide in
                Task { @MainActor in self?.state.isFullScreen = hide }
            }
            .store(in: &cancellables)

        power.onEvent = { [weak self] event in
            Task { @MainActor in self?.state.flash(event) }
        }
        power.start()

        // Reads new documents before anyone searches for them, so the first
        // search for a file you just downloaded is as fast as the second.
        indexer.start()
        #if DEBUG
        // `open DynamicNotch.app --args -captionNow "<path>|<path>…"`: caption these photos now, for checking.
        if let path = UserDefaults.standard.string(forKey: "captionNow") { captionNow(path) }
        // `--args -runSearchChecks YES`: the search checks (off the menu since 2026-11-12).
        if UserDefaults.standard.bool(forKey: "runSearchChecks") { runSearchChecks() }
        // `--args -photoPrecision YES`: photo precision, rated by Pip's vision (slow: ~120 looks).
        // (`-judgePhotos`, its old name, still works.)
        if UserDefaults.standard.bool(forKey: "photoPrecision") || UserDefaults.standard.bool(forKey: "judgePhotos") {
            Task { await SearchChecks.photoPrecision() }
        }
        // `--args -faceCheck YES`: photos-of-me Phase 0 — can Vision's feature print tell my face from others?
        if UserDefaults.standard.bool(forKey: "faceCheck") { Task.detached(priority: .utility) { FaceCheck.run() } }
        #if DEBUG
        // `--args -listenPip YES`: Pip's panel drawn as if listening, to see
        // it — the microphone stays off (turning it on sent the owner's
        // words to Pip during a check).
        if UserDefaults.standard.bool(forKey: "listenPip") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.openPet()
                VoiceActivity.shared.isListening = true
            }
        }
        // `--args -similarTo /path/a.jpg,/path/b.png`: each picture's closest photos and scores.
        if let list = UserDefaults.standard.string(forKey: "similarTo") {
            Task {
                for path in list.split(separator: ",").map(String.init) {
                    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                    let found = await PhotoVectors.shared.similar(to: image, limit: 6)
                    ActivityLog.write(.search, "similar to \((path as NSString).lastPathComponent): "
                                      + found.map { String(format: "%.2f %@", $0.similarity, $0.url.lastPathComponent) }.joined(separator: ", "))
                }
            }
        }
        // `--args -groupSearch "query || query"`: Pip's search for each, then its groups, logged.
        if let list = UserDefaults.standard.string(forKey: "groupSearch") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                for query in list.components(separatedBy: "||").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    let found = await SearchController.forPip.find(query).map(\.url)
                    let started = Date()
                    let groups = await ResultGroups.group(found, query: query)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    ActivityLog.write(.search, "groups for \"\(query)\" (\(found.count) files, \(ms) ms): "
                        + (groups?.map { "\($0.name) [" + $0.urls.map(\.lastPathComponent).joined(separator: ", ") + "]" }
                            .joined(separator: " | ") ?? "none"))
                }
                ActivityLog.write(.search, "group search done")
            }
        }
        // `--args -describeSample 40`: describes that many documents now (not waiting for idle),
        // a mix from every folder, and logs each line — to judge the descriptions.
        let sample = UserDefaults.standard.integer(forKey: "describeSample")
        if sample > 0 {
            Task { @MainActor in
                let pool = await ContentStore.shared.undescribedDocuments(first: [], limit: 600)
                var byFolder: [String: [ContentStore.Undescribed]] = [:]
                for document in pool { byFolder[(document.path as NSString).deletingLastPathComponent, default: []].append(document) }
                // Round-robin across folders, so one big folder doesn't fill the sample.
                var picked: [ContentStore.Undescribed] = []
                var lists = Array(byFolder.values)
                while picked.count < sample, lists.contains(where: { !$0.isEmpty }) {
                    for index in lists.indices where !lists[index].isEmpty && picked.count < sample {
                        picked.append(lists[index].removeFirst())
                    }
                }
                for document in picked {
                    let started = Date()
                    guard let about = await DocumentNotes.describe(document) else { break }
                    if let saved = await ContentStore.shared.setAbout(path: document.path, modified: document.modified,
                                                                      about: about), !about.isEmpty {
                        await SemanticIndex.shared.add(path: document.path, modified: document.modified,
                                                       title: saved.title, text: saved.text, replace: true)
                    }
                    ActivityLog.write(.search, String(format: "describe %.1fs: %@ → %@", Date().timeIntervalSince(started),
                                                      (document.path as NSString).lastPathComponent, about))
                }
                ActivityLog.write(.search, "describe sample done")
            }
        }
        // `--args -musicTree "music://…"`: opens that page in Music and logs its buttons and rows (no play).
        if let page = UserDefaults.standard.string(forKey: "musicTree"), let url = URL(string: page) {
            Task.detached {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let music = await MainActor.run(body: {
                    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first
                }) else { ActivityLog.write(.system, "musicTree: Music not running"); return }
                let app = AXUIElementCreateApplication(music.processIdentifier)
                func value(_ e: AXUIElement, _ k: String) -> String {
                    var v: CFTypeRef?
                    AXUIElementCopyAttributeValue(e, k as CFString, &v)
                    return (v as? String) ?? ""
                }
                var queue: [(AXUIElement, Int)] = [(app, 0)]
                var lines: [String] = []
                while !queue.isEmpty, lines.count < 400 {
                    let (e, depth) = queue.removeFirst()
                    let role = value(e, kAXRoleAttribute)
                    let label = [value(e, kAXTitleAttribute), value(e, kAXDescriptionAttribute), value(e, kAXValueAttribute)]
                        .filter { !$0.isEmpty }.joined(separator: " / ")
                    if ["AXButton", "AXRow", "AXCell", "AXStaticText", "AXGroup"].contains(role), !label.isEmpty || role == "AXRow" {
                        var actions: CFArray?
                        AXUIElementCopyActionNames(e, &actions)
                        lines.append("\(depth) \(role) \(label.prefix(60)) [\((actions as? [String] ?? []).joined(separator: ","))]")
                    }
                    var kids: CFTypeRef?
                    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
                    for kid in (kids as? [AXUIElement]) ?? [] where depth < 25 { queue.append((kid, depth + 1)) }
                }
                ActivityLog.write(.system, "musicTree:\n" + lines.joined(separator: "\n"))
            }
        }
        // `--args -clickAt "671,508"`: click to ask's click at that point (Quartz points), without the tap.
        if let spot = UserDefaults.standard.string(forKey: "clickAt") {
            let xy = spot.split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 { ClickToAsk.shared.debugClick(at: CGPoint(x: xy[0], y: xy[1])) }
        }
        #endif
        // `--args -searchDebug "flight ticket latest"`: one query's top ten and why.
        if let query = UserDefaults.standard.string(forKey: "searchDebug") { Task { await SearchChecks.explain(query) } }
        // `--args -summariseSession 2026-11-07`: that day's summary written now.
        if let day = UserDefaults.standard.string(forKey: "summariseSession") { agent.summariseLater(day: day, after: 1) }
        // `--args -showVocabulary YES`: the words speech recognition is told to expect.
        if UserDefaults.standard.bool(forKey: "showVocabulary") {
            ActivityLog.write(.voice, "vocabulary: " + agent.vocabulary().prefix(60).joined(separator: ", "))
        }
        // `--args -voiceCheck YES`: Pip's recent replies through the voice's G2P, word by word.
        if UserDefaults.standard.bool(forKey: "voiceCheck") { Task.detached(priority: .utility) { VoiceCheck.run() } }
        // `--args -askPip "what colour is my shirt in photo.jpg"`: a question to Pip, as if typed.
        // Several, " || " between them, go a second apart — the later ones
        // arrive while he's busy (the queue).
        if let question = UserDefaults.standard.string(forKey: "askPip") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // `-readAhead YES`: as if ⌥V was pressed first and the question came 30 s later.
                if UserDefaults.standard.bool(forKey: "readAhead") {
                    self.agent.prewarm(force: true)
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
                // `-showPip YES`: in Pip's window, to see it (layout checks).
                if UserDefaults.standard.bool(forKey: "showPip") { self.openPet() }
                for (index, part) in question.components(separatedBy: " || ").enumerated() {
                    if index > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                    self.agent.send(part)
                }
            }
        }
        #endif
        shelf.start()
        wirePet()

        // Rebuild if the display setup changes (docking, resolution, scaling).
        // Only then: the notification also comes for the Dock, the menu bar
        // and spaces — 637 rebuilds in 4 days, bursts of 5–7 a minute.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, Self.screenSetup() != self.panelScreens else { return }
                    self.buildPanel()
                }
            }
            .store(in: &cancellables)

        // Media appearing / disappearing drives collapsed <-> compact.
        // Paused counts as "gone": the island should vanish, not sit there dimmed.
        //
        // `kind` is in here rather than read off `now` because it also changes
        // when the threshold is moved from the menu — the island should correct
        // itself the moment you change the rule, not at the next track.
        //
        // `settled` false (a browser track with no length yet) holds back only
        // showing: nil means "keep what's there", hiding stays immediate.
        Publishers.CombineLatest3(engine.$now, engine.$kind, engine.$settled)
            .map { track, kind, settled -> Bool? in
                guard track?.isValid == true, track?.isPlaying == true, kind == .music else { return false }
                return settled ? true : nil
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hasMedia in
                Task { @MainActor in
                    guard let self, let hasMedia, self.state.hasMedia != hasMedia else { return }
                    self.state.hasMedia = hasMedia
                }
            }
            .store(in: &cancellables)

        // Whether a track exists at all, paused or not and whatever kind. This
        // is what decides if the panel offers a way back to the player; the
        // stricter `hasMedia` above decides whether it opens there.
        engine.$now
            .map { $0?.isValid == true }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hasTrack in
                Task { @MainActor in self?.state.hasTrack = hasTrack }
            }
            .store(in: &cancellables)

        // The drop shelf's row exists only while something is parked on it.
        DropShelf.shared.$items
            .map { !$0.isEmpty }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hasShelf in
                Task { @MainActor in
                    guard let self, self.state.hasDropShelf != hasShelf else { return }
                    self.state.hasDropShelf = hasShelf
                }
            }
            .store(in: &cancellables)
        // Files moved or deleted since they were parked leave it — checked
        // as the panel opens rather than watched, so it costs nothing closed.
        state.$isExpanded
            .removeDuplicates()
            .filter { $0 }
            .sink { _ in Task { @MainActor in DropShelf.shared.refresh() } }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
        // Saving is debounced now, so the last few searches are still in
        // memory when the app is asked to go.
        //
        // Detached, and that is the whole fix. A plain `Task` started here
        // inherits the main actor, so it can't begin until the main thread is
        // free — and the main thread is about to sit in `wait` below. The
        // save never started; the wait always ran its full second and timed
        // out, and the last searches were lost on every quit.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await SearchLog.shared.flush()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1)
        occupancy.stop()
        downloads.stop()
        indexer.stop()
        shelf.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        engine.stop()
        power.stop()
        panel?.teardown()
    }

    /// Idle draw is the whole game for a background app: while the Mac is asleep
    /// or the screen is locked, this one does literally nothing.
    private func observeSystemPower() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepEvents: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        let wakeEvents: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]

        for name in sleepEvents {
            center.publisher(for: name)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.engine.suspend()
                        // Stops the waveform. It's the only thing in the app
                        // that draws continuously, and behind a sleeping
                        // display every frame is pure waste.
                        self?.state.isSuspended = true
                    }
                }
                .store(in: &cancellables)
        }
        for name in wakeEvents {
            center.publisher(for: name)
                .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.engine.resume()
                        self?.state.isSuspended = false
                        self?.screenshotTidy.check()
                    }
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Sensors

    /// Each of these is independently switchable, and a switched-off one isn't
    /// started at all — not started-and-ignored. A feature you turned off
    /// should cost nothing, including no file descriptors and no listeners.
    private func startSensors() {
        applySensorSettings()

        downloads.onFinished = { [weak self] url in
            guard let self, self.prefs.watchesDownloads else { return }
            self.state.flash(.downloaded(name: url.lastPathComponent))
            self.pet.react(.celebrating, "Your download landed!")
            self.refreshUtility()
            // Work out a name and a folder for it; the row updates when ready.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tidy.suggestsFolders = self.prefs.suggestsDownloadFolders
                await self.tidy.prepare(for: url)
                self.refreshUtility()
            }
            // The row is a convenience, not a history. After a few minutes the
            // file isn't "just downloaded" any more and it gets out of the way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
                guard let self, self.downloads.latest == url else { return }
                self.downloads.clearLatest()
                self.refreshUtility()
            }
        }

        downloads.$latest
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.refreshUtility() } }
            .store(in: &cancellables)

        // Old screenshots: looked at once the app is up, and on wake (below).
        Publishers.CombineLatest(screenshotTidy.$offer, screenshotTidy.$done)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in Task { @MainActor in self?.refreshUtility() } }
            .store(in: &cancellables)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.screenshotTidy.check() }

        // Re-apply whenever the switch is flipped.
        prefs.$watchesDownloads
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.applySensorSettings() }
            }
            .store(in: &cancellables)
    }

    private func applySensorSettings() {
        prefs.watchesDownloads ? downloads.start() : downloads.stop()

        refreshIndicators()
        refreshUtility()
    }

    private static let pipTint = Color(red: 0.66, green: 0.88, blue: 0.54)
    private static let downloadTint = Color(red: 0.36, green: 0.68, blue: 1.0)

    private func refreshIndicators() {
        var list: [NotchIndicator] = []
        // Pip at work, so you can close his window and still see he's busy:
        // sparkles while he thinks, a waveform while he talks, an arrow while
        // his brain or voice downloads.
        if agent.isThinking {
            list.append(NotchIndicator(id: "pip", symbol: "sparkles", tint: Self.pipTint, pulses: true))
        } else if PipVoice.shared.isSpeaking {
            list.append(NotchIndicator(id: "pip", symbol: "waveform", tint: Self.pipTint, pulses: true))
        } else if agent.brainProgress != nil || PipVoice.shared.downloadProgress != nil {
            list.append(NotchIndicator(id: "pip", symbol: "arrow.down.circle", tint: Self.pipTint, pulses: true))
        }
        if state.indicators != list { state.indicators = list }
    }

    /// One row, and downloads win: a file that just landed is a thing you are
    /// about to act on, where the next meeting is a thing you're aware of.
    private func refreshUtility() {
        // A timer outranks everything: it's counting down to something now.
        let timer = NotchTimer.shared
        if timer.isActive {
            let title = timer.label ?? "Timer · " + NotchTimer.spoken(timer.length)
            let subtitle: String
            if timer.isPaused {
                subtitle = "Paused · " + NotchTimer.spoken(timer.remaining) + " left"
            } else {
                let end = Date().addingTimeInterval(timer.remaining)
                subtitle = "Ends at " + DateFormatter.localizedString(from: end, dateStyle: .none, timeStyle: .short)
            }
            state.utility = NotchUtility(
                id: "timer:" + (timer.isPaused ? "paused" : "running") + "\(timer.length)",
                symbol: "timer",
                tint: NotchRootView.timerTint,
                title: title,
                subtitle: subtitle,
                actionTitle: timer.isPaused ? "Resume" : "Pause",
                action: { timer.isPaused ? timer.resume() : timer.pause() },
                secondaryTitle: "Cancel",
                secondaryAction: { timer.cancel() })
            return
        }
        if prefs.watchesDownloads, let done = tidy.done {
            state.utility = NotchUtility(
                id: "tidied:" + done.now.path,
                symbol: "checkmark.circle.fill",
                tint: Self.downloadTint,
                title: done.now.lastPathComponent,
                subtitle: "Filed in " + done.now.deletingLastPathComponent().lastPathComponent,
                actionTitle: "Reveal",
                action: { NSWorkspace.shared.activateFileViewerSelecting([done.now]) },
                secondaryTitle: "Undo",
                secondaryAction: { [weak self] in
                    self?.tidy.undo()
                    self?.refreshUtility()
                })
            return
        }
        if prefs.watchesDownloads, let file = downloads.latest,
           let offer = tidy.suggestion, offer.file == file {
            state.utility = tidyUtility(offer)
            return
        }
        if let moved = screenshotTidy.done {
            state.utility = NotchUtility(
                id: "screenshots-moved:\(moved.moves.count)", symbol: "checkmark.circle.fill", tint: Self.downloadTint,
                title: "Moved \(moved.moves.count) screenshots",
                subtitle: "To Pictures ▸ Screenshots",
                actionTitle: "Reveal",
                action: { NSWorkspace.shared.open(moved.folder) },
                secondaryTitle: "Undo",
                secondaryAction: { [weak self] in self?.screenshotTidy.undo() })
            return
        }
        if let offer = screenshotTidy.offer {
            state.utility = NotchUtility(
                id: "screenshots:\(offer.files.count)", symbol: "photo.stack", tint: Self.downloadTint,
                title: "\(offer.files.count) old screenshots on your \(offer.from.lastPathComponent)",
                subtitle: "Move them to Pictures ▸ Screenshots?",
                actionTitle: "Move",
                action: { [weak self] in
                    self?.screenshotTidy.apply()
                    // The Undo row is for a moment, not forever.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                        guard self?.screenshotTidy.done != nil else { return }
                        self?.screenshotTidy.dismiss()
                    }
                },
                secondaryTitle: "Not now",
                secondaryAction: { [weak self] in self?.screenshotTidy.dismiss() })
            return
        }
        if prefs.watchesDownloads, let file = downloads.latest {
            state.utility = NotchUtility(
                id: "download:" + file.path,
                symbol: "arrow.down.circle.fill",
                tint: Self.downloadTint,
                title: file.lastPathComponent,
                subtitle: "Just downloaded",
                actionTitle: "Reveal",
                action: { NSWorkspace.shared.activateFileViewerSelecting([file]) },
                secondaryTitle: nil,
                secondaryAction: nil)
            return
        }

        if state.utility != nil { state.utility = nil }
    }

    /// The download row with Pip's suggestion: a better name, a folder, or
    /// "you already have this".
    private func tidyUtility(_ offer: FileTidy.Suggestion) -> NotchUtility {
        let reveal = { NSWorkspace.shared.activateFileViewerSelecting([offer.file]) }
        if let copy = offer.duplicateOf {
            return NotchUtility(
                id: "tidy-copy:" + offer.file.path, symbol: "doc.on.doc.fill", tint: Self.downloadTint,
                title: offer.file.lastPathComponent,
                subtitle: "Already in " + copy.deletingLastPathComponent().lastPathComponent,
                actionTitle: "Trash copy",
                action: { [weak self] in
                    self?.tidy.trashCopy()
                    self?.downloads.clearLatest()
                    self?.refreshUtility()
                },
                secondaryTitle: "Reveal", secondaryAction: reveal)
        }
        let verb = offer.newName != nil && offer.folder != nil ? "Tidy" : offer.newName != nil ? "Rename" : "Move"
        // "Move to Uni/BIO101?": the folder and the one above it.
        let subtitle = offer.folder.map {
            "Move to " + $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent + "?"
        } ?? "Better name"
        return NotchUtility(
            id: "tidy:" + offer.file.path, symbol: "wand.and.stars", tint: Self.downloadTint,
            title: offer.newName ?? offer.file.lastPathComponent,
            subtitle: subtitle,
            actionTitle: verb,
            action: { [weak self] in
                self?.tidy.apply()
                self?.downloads.clearLatest()
                self?.refreshUtility()
                // The "Undo" row is for a moment, not forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self, self.tidy.done != nil else { return }
                    self.tidy.dismiss()
                    self.refreshUtility()
                }
            },
            // Just dismisses: the plain download row (Reveal) stays.
            secondaryTitle: "Not now", secondaryAction: { [weak self] in
                ActivityLog.write(.system, "tidy: not now for \(offer.file.lastPathComponent)")
                self?.tidy.dismiss()
                self?.refreshUtility()
            })
    }

    // MARK: - Hot keys

    private func installHotKeys() {
        HotKeyCenter.shared.onPress = { [weak self] action in
            guard let self else { return }
            ActivityLog.write(.system, "hotkey: \(action)")
            switch action {
            case .talk:
                // Start loading the brain the instant the key goes down — it
                // loads while you're still speaking.
                self.agent.prewarm(force: true)
                self.voice.talkPressed()
            case .stop:
                self.voice.stopAll()
                self.agent.stopEverything()
            case .search:
                // Pressing it again while the panel is up closes it, so the
                // same shortcut both starts and stops.
                guard !self.search.isOpen else { self.search.close(); return }
                // Loads while you type.
                self.agent.prewarm(force: true)
                self.startSearch()
            case .click:
                // Again while an answer is up: start over.
                if !ClickToAsk.shared.isArmed { SideChat.shared.dismiss() }
                ClickToAsk.shared.toggle()
            }
        }
        HotKeyCenter.shared.onRelease = { [weak self] action in
            if action == .talk { self?.voice.talkReleased() }
        }
        registerHotKeys()
        wireClickToAsk()

        state.onDismissSearch = { [weak self] in self?.search.close() }
        // The hover panel's bar is the full search — it grows into it.
        state.onOpenSearch = { [weak self] in self?.openFullSearch() }

        state.onPointerIdle = { [weak self] in
            guard let self else { return }
            // Typing beats the pointer. Someone working the keyboard has no
            // reason for their mouse to be anywhere in particular, and closing
            // a search mid-word because the cursor was parked elsewhere would
            // be the worst version of this feature.
            if self.search.isOpen {
                // Waiting on the pet is using the panel: a local model takes
                // a few seconds, and letting go of the mouse meanwhile is the
                // natural thing to do.
                if self.search.mode == .pet, self.agent.isThinking || self.voice.isBusy { return }
                // Just answered: time to read it. It closed 2 s after he
                // finished speaking, while you were still reading.
                let since = Date().timeIntervalSince(self.pipLastBusy)
                if self.search.mode == .pet, since < Self.readingTime {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.readingTime - since + 0.1) { [weak self] in
                        // Asked again only if the pointer is still away.
                        guard let self, self.search.isOpen,
                              !self.state.islandScreenRect(for: self.state.presentation)
                                .insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) else { return }
                        self.state.onPointerIdle?()
                    }
                    return
                }
                guard Date().timeIntervalSince(self.search.lastActivity) > 2 else { return }
                self.search.close()
                return
            }
        }

        prefs.$searchHotKeyIndex
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.registerHotKeys() }
            }
            .store(in: &cancellables)
    }

    private func registerHotKeys() {
        HotKeyCenter.shared.register(combo(prefs.searchHotKeyIndex), for: .search)
        HotKeyCenter.shared.register(HotKeyCenter.talkCombo, for: .talk)
        HotKeyCenter.shared.register(HotKeyCenter.stopCombo, for: .stop)
        HotKeyCenter.shared.register(HotKeyCenter.clickCombo, for: .click)
    }

    /// The hint showing in the notch while click to ask is armed.
    private var clickHint: NotchEvent?
    /// When Pip last stopped thinking or speaking.
    private var pipLastBusy = Date.distantPast
    /// How long his window stays, pointer away, after he answers.
    private static let readingTime: TimeInterval = 15

    /// What the side chat's actions need from the app.
    private var askServices: SideChat.Services {
        SideChat.Services(notify: { [weak self] event in self?.state.flash(event) })
    }

    private func wireClickToAsk() {
        SideChat.shared.onDismiss = { ClickToAsk.shared.clearOverlays() }
        ClickToAsk.shared.onHint = { [weak self] text in
            guard let self else { return }
            if let old = self.clickHint { self.state.clearFlash(old) }
            self.clickHint = text.map { .hint(text: $0) }
            if let hint = self.clickHint { self.state.flash(hint) }
        }
        ClickToAsk.shared.onPicture = { [weak self] picture in
            Task { @MainActor in
                guard let self else { return }
                // The panel at once; its lines when Vision has them.
                let target = ClickToAsk.Target.image(picture.image, picture.rect)
                var pending = ClickAnswer.pending(target)
                pending.source = picture.source
                SideChat.shared.show(pending, beside: picture.rect, services: self.askServices)
                var answer = await ClickAnswer.make(for: target)
                answer.source = picture.source
                ActivityLog.write(.system, "click: in window «\(picture.source ?? "untitled")»")
                ActivityLog.write(.system, "click: answer — \(answer.title) | " + answer.lines.joined(separator: " | "))
                SideChat.shared.update(answer)
            }
        }
        ClickToAsk.shared.onText = { [weak self] found in
            Task { @MainActor in
                guard let self else { return }
                let target = ClickToAsk.Target.text(found.text, found.image)
                var pending = ClickAnswer.pending(target)
                pending.source = found.source
                SideChat.shared.show(pending, beside: found.rect, services: self.askServices, near: found.pointer)
                var answer = await ClickAnswer.make(for: target)
                answer.source = found.source
                ActivityLog.write(.system, "click: answer — \(answer.title) | " + answer.lines.joined(separator: " | "))
                SideChat.shared.update(answer)
            }
        }
    }

    private func combo(_ index: Int) -> HotKeyCenter.Combo {
        HotKeyCenter.choices[min(max(index, 0), HotKeyCenter.choices.count - 1)]
    }

    /// Mirrors the controller's phase into the island, and handles the keys
    /// that have to be intercepted before the text field sees them.
    ///
    /// Read the value handed to each sink rather than the property: @Published
    /// fires in willSet, so the property is still the old value while this
    /// runs.
    private func observeSearch() {
        // The island's height follows the number of results, so it has to
        // know. Combined rather than two sinks, or a frame change and a
        // content change land on different ticks and the panel visibly
        // stutters between them.
        Publishers.CombineLatest3(search.$results, search.$prunedCount, search.$showsWeak)
            .receive(on: RunLoop.main)
            .sink { [weak self] results, pruned, revealed in
                Task { @MainActor in
                    guard let self else { return }
                    // Group names take about 0.6 of a row each.
                    let headers = self.search.groupHeaders.count
                    self.state.searchRows = results.count + Int((Double(headers) * 0.6).rounded(.up))
                    self.state.searchHasMore = pruned > 0 && !revealed
                }
            }
            .store(in: &cancellables)

        search.$phase
            .map { $0 != .idle }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] open in
                Task { @MainActor in
                    guard let self else { return }
                    if open { self.state.isExpanded = false }
                    // A question still waiting for a yes can't be answered
                    // once the chat has gone, so closing is a no.
                    if !open, self.agent.confirmation != nil { self.agent.answer(false) }
                    // Closing Pip ends the conversation — unless he's still
                    // working or talking: a click elsewhere closed the panel
                    // and silently dropped the spoken answer. Esc stops all.
                    if !open, !(self.agent.isThinking || self.voice.isBusy) { self.voice.stopAll() }
                    self.state.isSearching = open
                }
            }
            .store(in: &cancellables)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // --- Search: arrows and Return, before the text field sees them ---
            //
            // The field is first responder, so an up-arrow would move the caret
            // rather than the selection. Returning nil from a local monitor is
            // what takes the key away from it.
            // The pet's chat only needs Return; everything else is typing,
            // and arrows belong to the caret, not to a results list.
            if self.search.isOpen, self.search.mode == .pet {
                switch event.keyCode {
                case 53:                                    // escape
                    self.voice.stopAll()
                    self.search.close()
                    return nil
                case 36, 76:                                // return, enter
                    if self.agent.confirmation != nil {
                        self.agent.answer(true)
                    } else if self.search.query.trimmingCharacters(in: .whitespaces).isEmpty,
                              let first = self.agent.found.first {
                        // Nothing typed and something found: Return opens it.
                        NSWorkspace.shared.open(first)
                        self.search.close()
                    } else {
                        // The query stays in the bar, greyed, while Pip
                        // thinks; PipView clears it once he has answered.
                        // The live file search stops: the model needs the Mac.
                        self.search.stopLive()
                        self.agent.send(self.search.query)
                    }
                    return nil
                case 48:                                    // tab
                    self.search.switchToFiles()
                    return nil
                default:
                    return event
                }
            }
            if self.search.isOpen {
                switch event.keyCode {
                case 53:                                    // escape
                    self.search.close()
                    return nil
                case 126:                                   // up
                    self.search.move(by: -1)
                    return nil
                case 125:                                   // down
                    self.search.move(by: 1)
                    return nil
                case 48:                                    // tab
                    // Hand what was typed to Pip instead.
                    self.search.switchToPet()
                    return nil
                case 124:                                   // right
                    // "More" — whatever more means here. Weaker matches if
                    // some were cut, otherwise drop the folder scope and
                    // search everywhere. Both are the same gesture from the
                    // user's side: I don't see it, show me further.
                    if self.search.prunedCount > 0, !self.search.showsWeak {
                        self.search.revealWeaker()
                    } else {
                        self.search.widen()
                    }
                    return nil
                case 36, 76:                                // return, enter
                    // ⌘↩ reveals in Finder instead of opening, the way every
                    // other search field on the system behaves.
                    if event.modifierFlags.contains(.command) {
                        self.search.revealSelected()
                    } else {
                        self.search.openSelected()
                    }
                    return nil
                default:
                    break
                }
            }

            return event
        }
    }

    // MARK: - Panel

    /// What the panel's place depends on: each display, its size, scale and
    /// notch. Not the visible frame — the Dock and menu bar change that.
    private static func screenSetup() -> String {
        NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return "\(id) \(screen.frame) \(screen.backingScaleFactor) \(screen.safeAreaInsets.top)"
        }.joined(separator: "; ")
    }

    private func buildPanel() {
        panelScreens = Self.screenSetup()
        if panel != nil { ActivityLog.write(.system, "notch panel rebuilt (display change: \(NSScreen.screens.count) screen\(NSScreen.screens.count == 1 ? "" : "s"))") }
        panel?.teardown()
        panel = nil

        guard let screen = NotchGeometry.notchedScreen() else { return }
        let metrics = NotchGeometry.metrics(for: screen)
        state.apply(metrics)

        let root = NotchRootView()
            .environmentObject(state)
            .environmentObject(engine)
            .environmentObject(search)
            .environmentObject(shelf)
            .environmentObject(pet)
            .environmentObject(agent)

        let newPanel = NotchPanel(metrics: metrics, state: state, rootView: root)
        newPanel.orderFrontRegardless()
        panel = newPanel
        // `apply` closed the island, but search or Pip may still be open — and
        // then nothing reopens it: voice's `openPetIfNeeded` sees Pip open and
        // returns. A rebuild mid-conversation left the notch shut on the next
        // talk. The new panel follows what's actually open.
        state.isSearching = search.isOpen
    }

    // MARK: - Menu bar item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = NSMenu()
        item.menu?.delegate = self
        statusItem = item
        refreshStatusItem()

        // Menu bar glyph + optional track title follow both the settings and
        // whatever is playing.
        Publishers.CombineLatest4(prefs.$menuBarSymbol,
                                  prefs.$showsTitleInMenuBar,
                                  engine.$now,
                                  engine.$kind)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                Task { @MainActor in self?.refreshStatusItem() }
            }
            .store(in: &cancellables)
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: prefs.menuBarSymbol,
                               accessibilityDescription: "Pip")
        button.image?.isTemplate = true
        button.imagePosition = prefs.showsTitleInMenuBar ? .imageLeading : .imageOnly

        if prefs.showsTitleInMenuBar, engine.kind == .music,
           let track = engine.now, track.isValid {
            var title = track.title
            if title.count > prefs.menuBarTitleLength {
                title = String(title.prefix(prefs.menuBarTitleLength - 1)) + "…"
            }
            button.title = " " + title
        } else {
            button.title = ""
        }
    }

    /// Rebuilt every time the menu opens so the checkmarks are always right.
    ///
    /// The two everyday actions, Settings, Quit. Removed items and settings
    /// that keep their saved values: Docs/history/Core.md.
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        func add(_ title: String, _ action: Selector?, to target: NSMenu, on: Bool? = nil) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            if let on { entry.state = on ? .on : .off }
            target.addItem(entry)
        }

        add("Search Files…", #selector(openFullSearch), to: menu)
        add("Ask \(pet.name)…", #selector(askPip), to: menu)
        // A download of several GB: shown while it runs.
        if let progress = agent.brainProgress {
            let total = Double(LocalBrain.approximateSize.split(separator: " ").first ?? "") ?? 0
            let done = String(format: "%.1f", total * progress)
            let item = NSMenuItem(title: "Downloading \(pet.name)'s Brain… \(Int(progress * 100))%  (\(done) of \(LocalBrain.approximateSize))",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Settings, grouped: Pip, Suggestions, Search, Privacy & Data.
        let settings = NSMenu()
        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu()
            build(menu)
            item.submenu = menu
            settings.addItem(item)
        }

        submenu(pet.name) { pip in
            add("Speak Replies Aloud", #selector(toggleSpeaksReplies), to: pip, on: voice.speaksReplies)
            add("Also Speak Replies to Typed Questions", #selector(toggleSpeaksTyped), to: pip, on: voice.speaksTyped)
            add("\(combo(prefs.searchHotKeyIndex).title) Opens \(pet.name) Instead of Search",
                #selector(toggleShortcutOpensPip), to: pip, on: prefs.searchOpensPip)
            pip.addItem(.separator())
            let neural = PipVoice.shared
            if let progress = neural.downloadProgress {
                let item = NSMenuItem(title: "Downloading Voice… \(Int(progress * 100))%", action: nil, keyEquivalent: "")
                item.isEnabled = false
                pip.addItem(item)
            } else if !KokoroEngine.isDownloaded {
                add("Download Natural Voice (\(KokoroEngine.approximateSize))…", #selector(downloadNaturalVoice), to: pip)
            } else {
                let voices = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
                let voiceMenu = NSMenu()
                let chosen = KokoroEngine.voiceID
                for option in KokoroEngine.voices {
                    let entry = NSMenuItem(title: "\(option.name) (\(option.id.hasPrefix("af") ? "female" : "male"))",
                                           action: #selector(pickNaturalVoice(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = option.id
                    entry.state = option.id == chosen ? .on : .off
                    voiceMenu.addItem(entry)
                }
                voices.submenu = voiceMenu
                pip.addItem(voices)
                add("Remove Natural Voice (\(KokoroEngine.approximateSize))…", #selector(deleteNaturalVoice), to: pip)
            }
            if LocalBrain.isDownloaded, agent.brainProgress == nil {
                add("Remove \(pet.name)'s Model (\(LocalBrain.approximateSize))…", #selector(deleteBrain), to: pip)
            }
        }

        submenu("Suggestions") { suggestions in
            add("Offer to Summarise Copied Text", #selector(toggleClipboardOffers), to: suggestions,
                on: ClipboardWatch.isEnabled)
            add("Suggest Folders for New Downloads", #selector(toggleDownloadFolders), to: suggestions,
                on: prefs.suggestsDownloadFolders)
        }

        // Folders search leaves out hold a .metadata_never_index file
        // (Spotlight's convention).
        submenu("Search") { search in
            add("Exclude a Folder…", #selector(excludeFolder), to: search)
            add("Include an Excluded Folder…", #selector(includeFolder), to: search)
        }

        submenu("Privacy & Data") { privacy in
            add("Keep Conversation History", #selector(toggleSavesConversations), to: privacy,
                on: ConversationLog.isEnabled)
            add("Show Conversation History in Finder", #selector(showSavedConversations), to: privacy)
            add("Forget Today's Conversation", #selector(forgetConversation), to: privacy)
            privacy.addItem(.separator())
            add("Delete Conversation History…", #selector(deleteSavedConversations), to: privacy)
            add("Delete Activity Logs…", #selector(deleteActivityLogs), to: privacy)
        }

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settings
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Pip",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }


    // MARK: - Pet

    /// Feeds the pet what the Mac is doing, and gives its agent a way to
    /// reach the screen. Each input is a publisher that already exists, so
    /// the pet adds listeners, not polling.
    private func wirePet() {
        // So "type this" and "press ⌘S" go to the app you were using, not Pip.
        TargetApp.startTracking()
        // Created now rather than on first use, so the talk key works from launch.
        _ = voice
        // Hovering the notch while Pip is busy, or has an answer waiting,
        // opens Pip rather than the player — that's what you're after.
        state.$isExpanded
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                Task { @MainActor in
                    guard let self, expanded, !self.search.isOpen else { return }
                    // A long copy waiting: hovering the notch means "summarise it".
                    if !self.agent.isThinking, let copied = ClipboardWatch.shared.take() {
                        self.openPet()
                        self.agent.summarizeCopied(copied.text, words: copied.words, fromPhone: copied.fromPhone)
                        return
                    }
                    guard self.agent.isThinking || self.agent.hasUnseenReply || self.voice.isBusy else { return }
                    self.openPet()
                }
            }
            .store(in: &cancellables)

        // Copy something long (here or on the iPhone) → the notch offers to
        // summarise it; hovering accepts (above).
        ClipboardWatch.shared.onOffer = { [weak self] offer in
            self?.state.flash(.copiedLong(words: offer.words, fromPhone: offer.fromPhone))
        }
        ClipboardWatch.shared.start()

        // The notch timer: drawn from `state`, its row refreshed on every
        // change, and a flash and a chime at zero.
        NotchTimer.shared.attach(state)
        NotchTimer.shared.onChange = { [weak self] in self?.refreshUtility() }
        NotchTimer.shared.onFinished = { [weak self] label in
            self?.state.flash(.reminder(text: label.map { "\($0) — time's up" } ?? "Timer done"))
            NSSound(named: "Glass")?.play()
        }

        // Short of memory: let go of the brain and voice (they reload on the
        // next question). Holding 6 GB while macOS starts swapping is what
        // really makes a Mac hot and slow.
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // Photo captions are optional work: stop them (and let the brain go).
                self?.indexer.captions.stop()
                DocumentNotes.shared.stop()
                Task { await PhotoVectors.shared.unloadModels() }
                // No preloading the brain for a while (PetAgent.memoryWarnedAt).
                self?.agent.memoryWarnedAt = .now
                guard let self, !self.agent.isThinking else { return }
                // Critical: always let go. A warning: only if Pip is idle —
                // his window closed and nothing asked for 2 minutes. macOS
                // sends warnings often (33 in three days), and unloading on
                // each meant 15 of 27 questions re-read the whole chat.
                if pressure.data.contains(.critical) {
                    ActivityLog.write(.system, "memory pressure (critical) — unloading the brain and voice")
                } else {
                    let pipOpen = self.search.isOpen && self.search.mode == .pet
                    let idle = Date.now.timeIntervalSince(self.agent.lastActive)
                    guard !pipOpen, idle > 120 else {
                        ActivityLog.write(.system, "memory pressure (warning) — kept the brain "
                                          + (pipOpen ? "(Pip open)" : "(used \(Int(idle)) s ago)"))
                        return
                    }
                    let since = self.agent.lastActive == .distantPast ? "not used since launch" : "idle \(Int(idle)) s"
                    ActivityLog.write(.system, "memory pressure (warning) — unloading the brain and voice, \(since)")
                }
                Task {
                    await LocalBrain.shared.unload()
                    await KokoroEngine.shared.unload()
                }
            }
        }
        pressure.resume()
        memoryPressure = pressure

        // Pip's activity in the closed notch.
        Publishers.CombineLatest4(agent.$isThinking, PipVoice.shared.$isSpeaking,
                                  agent.$brainProgress.map { $0 != nil }, PipVoice.shared.$downloadProgress.map { $0 != nil })
            .removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshIndicators() }
            }
            .store(in: &cancellables)

        // Photo captions use the same brain; Pip comes first.
        indexer.captions.pipInUse = { [weak self] in
            guard let self else { return false }
            return self.agent.isThinking || self.voice.isBusy || PipVoice.shared.isSpeaking
        }
        DocumentNotes.shared.pipInUse = indexer.captions.pipInUse
        // When Pip last stopped working: his window stays a while after.
        Publishers.CombineLatest(agent.$isThinking, PipVoice.shared.$isSpeaking)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.pipLastBusy = .now }
            }
            .store(in: &cancellables)
        // Pip went quiet: search results he found can be described now.
        Publishers.CombineLatest(agent.$isThinking, PipVoice.shared.$isSpeaking)
            .filter { !$0 && !$1 }
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { _ in Task { @MainActor in DocumentNotes.shared.pipBecameIdle() } }
            .store(in: &cancellables)
        Publishers.CombineLatest(agent.$isThinking, PipVoice.shared.$isSpeaking)
            .filter { $0 || $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.indexer.captions.stop(forPip: true)
                    DocumentNotes.shared.stop(forPip: true)
                }
            }
            .store(in: &cancellables)

        // Finished while his window was closed: show the start of the answer
        // in the notch, so you know it's ready.
        agent.$isThinking
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] thinking in
                Task { @MainActor in
                    guard let self, !thinking else { return }
                    let pipOpen = self.state.isSearching && self.search.mode == .pet
                    guard !pipOpen, let reply = self.agent.latest, !reply.isEmpty else { return }
                    let short = reply.count > 60 ? String(reply.prefix(57)) + "…" : reply
                    self.state.flash(.pipReplied(text: short))
                    self.agent.markUnseen()
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(power.$percent, power.$isPluggedIn)
            .receive(on: RunLoop.main)
            .sink { [weak self] percent, plugged in
                LocalBrain.onBattery = !plugged
                if !plugged { Task { @MainActor in self?.indexer.captions.stop(); DocumentNotes.shared.stop() } }
                Task { @MainActor in self?.pet.setBattery(percent: percent, pluggedIn: plugged) }
            }
            .store(in: &cancellables)

        state.$hasMedia
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                Task { @MainActor in self?.pet.setMusic(playing: playing) }
            }
            .store(in: &cancellables)

        // Running hot: the system's own judgement, delivered as a
        // notification, rather than sampling CPU load ourselves.
        let hot = { () -> Bool in
            let thermal = ProcessInfo.processInfo.thermalState
            return thermal == .serious || thermal == .critical
        }
        pet.setRunningHot(hot())
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.pet.setRunningHot(hot()) }
            }
            .store(in: &cancellables)

        // Pip's window is as tall as what's in it, so the island has to know
        // what that is: dots, a reply of so many lines, files, a question.
        // Files: what he found, or — while you type — the live apps and files.
        Publishers.CombineLatest4(agent.$found.map { $0.count }.combineLatest(
                                      search.$results.combineLatest(search.$query).map { results, query in
                                          MainActor.assumeIsolated {
                                              SearchController.pipRows(results: results, query: query,
                                                                       answered: self.agent.latest != nil).count
                                          }
                                      }),
                                  agent.$confirmation,
                                  Publishers.CombineLatest4(agent.$latest, agent.$partial, agent.$voiceSynced,
                                                            // Sized for the whole sentence being spoken.
                                                            agent.$caption.combineLatest(agent.$captionAhead)
                                                                .map { caption, ahead in caption == nil ? nil : (ahead ?? caption) }),
                                  // Busy, or your last spoken words still settling.
                                  agent.$isThinking.combineLatest(agent.$awaitingSpeech).map { ($0, $1) })
            .receive(on: RunLoop.main)
            .sink { [weak self] counts, _, _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let count = counts.1 > 0 && self.search.mode == .pet ? counts.1 : counts.0
                    // Read live, as PipView does: by the time this runs, newer
                    // values may have landed than the ones it was sent.
                    let agent = self.agent
                    let confirmation = agent.confirmation
                    let (latest, partial, synced) = (agent.latest, agent.partial, agent.voiceSynced)
                    let caption = agent.caption == nil ? nil : (agent.captionAhead ?? agent.caption)
                    let asking = confirmation != nil
                    // The same rules PipView uses: when he's speaking, the
                    // words appear with his voice; otherwise as they stream.
                    let (thinking, settling) = (agent.isThinking, agent.awaitingSpeech)
                    let showsThinking = !asking && (settling || (synced ? caption == nil : (thinking && partial == nil)))
                    let reply = showsThinking ? nil
                        : (confirmation?.question ?? (synced ? caption : (partial ?? latest)))
                    // Only write what changed: every write to a @Published
                    // re-renders the whole island, and this runs per token.
                    // Thinking: one line ("Thinking…", or what he's doing)
                    // under big Pip. Below big Pip (listening), the text has
                    // the whole row.
                    // A reply in the explanation shape: its own layout and
                    // height, live as it's written or said (not when asking).
                    let shows = !showsThinking && !asking && !self.state.pipVoiceLayout
                    let expected = PipExplanation.expects(self.agent.lastQuestion)
                    let live = shows ? PipExplanation.live(written: partial ?? latest, spoken: caption, synced: synced,
                                                           streaming: partial != nil, expected: expected) : nil
                    // Long (more than three lines, or a tall explanation, at
                    // the usual width): the window widens and it's laid out
                    // at the wider width. The text only grows while he
                    // writes, so it widens once and stays wide. Judged from
                    // the written reply, which is ahead of his voice: spoken,
                    // the window widens before he starts, not mid-answer.
                    // An explain question is wide from the first word, and an
                    // answer that's gone wide stays wide until the next
                    // question, so text is never re-wrapped while you read.
                    if partial == nil, latest == nil { self.answerWent = false }
                    let writtenText = synced ? (partial ?? latest) : reply
                    let measured = writtenText.map { text in
                        if let shaped = PipExplanation.parse(text, streaming: partial != nil,
                                                             shapeKnown: expected && partial != nil) {
                            return shaped.height(width: NotchState.pipTextWidth) > NotchState.pipLongExplanationHeight
                        }
                        return PipReply.lines(text, width: NotchState.pipTextWidth) > NotchState.pipLongAnswerLines
                    } ?? false
                    let long = shows && (expected || self.answerWent || measured)
                    if long { self.answerWent = true }
                    if self.state.pipLongAnswer != long { self.state.pipLongAnswer = long }
                    let width = self.state.pipVoiceLayout ? NotchState.pipVoiceTextWidth
                        : long ? NotchState.pipLongTextWidth : NotchState.pipTextWidth
                    let lines = showsThinking ? 1 : (reply.map { PipReply.lines($0, width: width) } ?? 0)
                    let explained = live.map { min($0.explanation.height(width: width), PipExplanation.maxHeight) } ?? 0
                    if self.state.pipExplanationHeight != explained { self.state.pipExplanationHeight = explained }
                    let done = live?.done ?? false
                    if self.state.pipExplanationDone != done { self.state.pipExplanationDone = done }
                    // Each step of the live layout, once: headline, paragraph,
                    // points, done — and whether it's following the writing or
                    // the voice.
                    let step = live.map { live in
                        "explanation \(done ? "done" : synced ? "live (spoken)" : "live (written)"): headline"
                            + (live.explanation.body.isEmpty ? "" : ", paragraph")
                            + (live.explanation.points.isEmpty ? "" : ", \(live.explanation.points.count) point(s)")
                            + String(format: ", %.0f pt tall, %.0f wide", explained, width)
                    }
                    if step != self.lastExplanationStep {
                        self.lastExplanationStep = step
                        if let step { ActivityLog.write(.system, step) }
                    }
                    if self.state.pipThinking != showsThinking { self.state.pipThinking = showsThinking }
                    if self.state.pipBusy != thinking { self.state.pipBusy = thinking }
                    if self.state.pipReplyLines != lines { self.state.pipReplyLines = lines }
                    if self.state.pipResults != count { self.state.pipResults = count }
                    if self.state.pipConfirming != asking { self.state.pipConfirming = asking }
                }
            }
            .store(in: &cancellables)

        // Group names above what Pip found, when it splits (not over live typing rows).
        agent.$foundHeaders
            .receive(on: RunLoop.main)
            .sink { [weak self] headers in
                Task { @MainActor in
                    guard let self else { return }
                    let typing = !SearchController.pipRows(results: self.search.results, query: self.search.query,
                                                           answered: self.agent.latest != nil).isEmpty
                    let shown = typing ? 0 : min(headers.keys.filter { $0 < NotchState.pipMaxResults }.count,
                                                 NotchState.pipMaxGroupHeaders)
                    if self.state.pipResultHeaders != shown { self.state.pipResultHeaders = shown }
                }
            }
            .store(in: &cancellables)

        // Pictures from the web: their rows in Pip's window.
        agent.$pictures
            .map { pictures in
                min(NotchState.pipMaxPictureRows,
                    (pictures.count + NotchState.pipPicturesPerRow - 1) / NotchState.pipPicturesPerRow)
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] rows in
                Task { @MainActor in
                    guard let self, self.state.pipPictureRows != rows else { return }
                    self.state.pipPictureRows = rows
                }
            }
            .store(in: &cancellables)

        // Listening: Pip big, your words below him (`pipVoiceLayout`).
        VoiceActivity.shared.$isListening
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] voice in
                Task { @MainActor in
                    guard let self, self.state.pipVoiceLayout != voice else { return }
                    self.state.pipVoiceLayout = voice
                }
            }
            .store(in: &cancellables)

        // The orb goes to the corner while he listens (`NotchState.pipCompact`).
        VoiceActivity.shared.$isListening
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] listening in
                Task { @MainActor in
                    guard let self, self.state.pipListening != listening else { return }
                    self.state.pipListening = listening
                }
            }
            .store(in: &cancellables)

        // Chips go as soon as a conversation starts (spec: not after the first message).
        agent.$lines
            .map { !$0.isEmpty }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] has in
                Task { @MainActor in
                    // The first conversation ever retires the suggestions for good.
                    if has, !NotchState.pipSuggestionsRetired { NotchState.pipSuggestionsRetired = true }
                    if self?.state.pipHasHistory != has { self?.state.pipHasHistory = has }
                }
            }
            .store(in: &cancellables)

        agent.$noteOffer
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] offered in
                Task { @MainActor in if self?.state.pipNoteOffer != offered { self?.state.pipNoteOffer = offered } }
            }
            .store(in: &cancellables)

        search.$mode
            .map { $0 == .pet }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isPet in
                Task { @MainActor in self?.state.searchIsPet = isPet }
            }
            .store(in: &cancellables)

        // A reply arriving counts as activity, so the panel's idle close
        // starts counting from when you could read it, not from when you
        // stopped typing.
        agent.$isThinking
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] thinking in
                Task { @MainActor in if !thinking { self?.search.noteActivity() } }
            }
            .store(in: &cancellables)
    }

    private func openPet() {
        search.open(in: nil, mode: .pet)
        agent.refreshStatus()
    }

    /// Opens Pip only if he isn't already the one on screen — voice calls
    /// this on every turn of a conversation.
    private func openPetIfNeeded() {
        guard !(search.isOpen && search.mode == .pet) else { return }
        openPet()
    }

    @objc private func toggleSpeaksReplies() {
        voice.speaksReplies.toggle()
    }

    @objc private func excludeFolder() { chooseFolder(exclude: true) }
    @objc private func includeFolder() { chooseFolder(exclude: false) }

    private func chooseFolder(exclude: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = exclude ? "Search will leave out this folder and everything in it."
                                : "Choose a folder that was excluded, to search it again."
        panel.prompt = exclude ? "Exclude" : "Include"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        DirectScan.setExcluded(folder, exclude)
        ActivityLog.write(.search, "\(exclude ? "excluded" : "included again"): \(folder.path)")
    }

    @objc private func toggleSpeaksTyped() {
        voice.speaksTyped.toggle()
    }

    @objc private func toggleClipboardOffers() {
        ClipboardWatch.isEnabled.toggle()
        if !ClipboardWatch.isEnabled { ClipboardWatch.shared.clear() }
    }

    @objc private func toggleDownloadFolders() {
        prefs.suggestsDownloadFolders.toggle()
        ActivityLog.write(.system, "suggest where downloads go: \(prefs.suggestsDownloadFolders ? "on" : "off")")
    }

    @objc private func toggleSavesConversations() {
        ConversationLog.isEnabled.toggle()
    }

    @objc private func showSavedConversations() {
        ConversationLog.reveal()
    }

    @objc private func forgetConversation() {
        voice.stopAll()
        agent.forgetConversation()
    }

    @objc private func deleteSavedConversations() {
        let alert = NSAlert()
        alert.messageText = "Delete all saved conversations?"
        alert.informativeText = "Every conversation with \(pet.name) — the files and his memory of them — will be deleted. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ConversationLog.deleteAll()
        ConversationStore.shared.deleteAll()
    }

    @objc private func deleteActivityLogs() {
        let alert = NSAlert()
        alert.messageText = "Delete the activity logs?"
        alert.informativeText = "The record of what \(pet.name) did (kept 7 days) will be deleted. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ActivityLog.deleteAll()
    }

    @objc private func pickNaturalVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        PipVoice.shared.pickNeuralVoice(id)
    }

    @objc private func downloadNaturalVoice() {
        PipVoice.shared.downloadNeuralVoice()
    }

    @objc private func deleteNaturalVoice() {
        let alert = NSAlert()
        alert.messageText = "Delete \(pet.name)'s natural voice?"
        alert.informativeText = "This frees about \(KokoroEngine.approximateSize). \(pet.name) will be quiet until it's downloaded again."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        PipVoice.shared.stop()
        Task {
            await KokoroEngine.shared.unload()
            try? FileManager.default.removeItem(at: KokoroEngine.folder)
        }
    }

    /// The shortcut: Pip by default, or the full panel if that's the choice.
    @objc private func startSearch() {
        if prefs.searchOpensPip { openPet() } else { openFullSearch() }
    }

    @objc private func openFullSearch() {
        // Whatever Finder is showing, or everywhere. Searching the folder
        // you're looking at is the common case by a distance, and it's also
        // the fast one — Spotlight scoped to a folder returns in a fraction of
        // the time it takes across a home directory.
        search.open(in: FolderTarget.currentIfObvious())
    }

    @objc private func askPip() { openPet() }

    /// Frees the disk space the on-device model uses. Pip offers to download
    /// it again the next time he's asked something.
    @objc private func deleteBrain() {
        let alert = NSAlert()
        alert.messageText = "Delete \(pet.name)'s brain?"
        alert.informativeText = "This frees about \(LocalBrain.approximateSize). \(pet.name) can download it again later."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await LocalBrain.shared.unload()
            try? FileManager.default.removeItem(at: LocalBrain.folder)
        }
    }

    @objc private func toggleShortcutOpensPip() {
        prefs.searchOpensPip.toggle()
    }


    // MARK: - NSMenuDelegate

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuildMenu(menu) }
    }
}
