import AppKit
import Carbon.HIToolbox

/// Global hotkeys, registered through Carbon's `RegisterEventHotKey`.
///
/// The modern-looking alternative — `NSEvent.addGlobalMonitorForEvents` — needs
/// Accessibility permission, because a process that can watch every keystroke
/// system-wide is a keylogger. Carbon hotkeys ask the window server to deliver
/// specific combinations and nothing else, so they need no permission at all.
/// An old API, but the right trade.
@MainActor
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    /// What a registered key does. The raw value is the Carbon hot key id, so
    /// the callback can tell which one fired.
    enum Action: UInt32, CaseIterable {
        /// Search files. The only one left after the Claude features went —
        /// the raw value stays at 5 rather than being renumbered, because it
        /// is a Carbon hot key id and reusing a retired one risks colliding
        /// with a registration the system hasn't finished letting go of.
        case search = 5
        /// Hold to talk to Pip; release to send.
        case talk = 6
        /// Stop whatever Pip is doing, right now.
        case stop = 7
        // 8 was Circle to Search: retired, not reused (see `search`).
        /// Click to ask: point at anything and Pip explains it.
        case click = 9
    }

    /// Hold-to-talk, fixed rather than chosen: ⌥V, for voice.
    static let talkCombo = Combo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey), title: "⌥V")
    /// The emergency stop: ⌃⎋. Not ⌥⎋ — macOS uses that to read selected text aloud.
    static let stopCombo = Combo(keyCode: UInt32(kVK_Escape), modifiers: UInt32(controlKey), title: "⌃⎋")
    /// Click to ask: ⌥⇧A, for ask.
    static let clickCombo = Combo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | shiftKey), title: "⌥⇧A")

    struct Combo: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var title: String
    }

    /// Deliberately avoids ⌥Space — that's Spotlight on this machine.
    static let choices: [Combo] = [
        Combo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey),              title: "⌥A"),
        Combo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey),              title: "⌥S"),
        Combo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey),              title: "⌥D"),
        Combo(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(optionKey),              title: "⌥E"),
        Combo(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(optionKey),              title: "⌥G"),
        Combo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | cmdKey),     title: "⌥⌘A"),
        Combo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | cmdKey),     title: "⌥⌘S"),
        Combo(keyCode: UInt32(kVK_Space),  modifiers: UInt32(optionKey | shiftKey),   title: "⌥⇧Space"),
        Combo(keyCode: UInt32(kVK_Space),  modifiers: UInt32(controlKey | optionKey), title: "⌃⌥Space"),
        Combo(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey | cmdKey),     title: "⌥⌘1"),
        // Appended rather than inserted: these indices are stored in
        // preferences, so putting a new choice in the middle would silently
        // change everyone's existing shortcuts.
        Combo(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey),              title: "⌥F"),
    ]

    /// Called on the main actor when one of the combinations is pressed.
    var onPress: ((Action) -> Void)?
    /// And when it's let go — only hold-to-talk cares.
    var onRelease: ((Action) -> Void)?

    private var refs: [Action: EventHotKeyRef] = [:]
    private var registered: Set<Action> = []
    private var handlerRef: EventHandlerRef?
    private var installed = false

    private init() {}

    /// False when another app already owns the combination — worth surfacing,
    /// because otherwise it fails completely silently.

    @discardableResult
    func register(_ combo: Combo, for action: Action) -> Bool {
        unregister(action)
        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x444E4348 /* "DNCH" */),
                                       id: action.rawValue)
        let status = RegisterEventHotKey(combo.keyCode,
                                         combo.modifiers,
                                         identifier,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &reference)
        guard status == noErr, let reference else { return false }
        refs[action] = reference
        registered.insert(action)
        return true
    }

    func unregister(_ action: Action) {
        if let reference = refs[action] { UnregisterEventHotKey(reference) }
        refs[action] = nil
        registered.remove(action)
    }

    func unregisterAll() {
        Action.allCases.forEach(unregister)
    }

    /// One process-wide handler, installed lazily. Registering another key
    /// doesn't reinstall it — that would stack duplicate callbacks and fire
    /// every action once per past registration.
    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            // Which key fired is carried in the event, not in the closure —
            // a C function pointer can't capture anything.
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &identifier)
            guard status == noErr,
                  let action = Action(rawValue: identifier.id) else { return noErr }

            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // No "already held" bookkeeping: if a release ever went
                    // missing, it would block every later press. Repeats are
                    // handled by whoever receives them instead.
                    let center = HotKeyCenter.shared
                    if released {
                        center.onRelease?(action)
                    } else {
                        center.onPress?(action)
                    }
                }
            }
            return noErr
        }, specs.count, &specs, nil, &handlerRef)
    }
}
