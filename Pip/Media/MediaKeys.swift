import AppKit

/// Posts the hardware media keys (any player; needs Accessibility).
enum MediaKeys {

    enum Key: Int32 {
        case playPause = 16   // NX_KEYTYPE_PLAY
        case next      = 17   // NX_KEYTYPE_NEXT
        case previous  = 18   // NX_KEYTYPE_PREVIOUS
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func post(_ key: Key) {
        send(key, down: true)
        send(key, down: false)
    }

    private static func send(_ key: Key, down: Bool) {
        let flags: Int = down ? 0xA00 : 0xB00
        let data1 = Int((key.rawValue << 16) | Int32(flags))
        guard let event = NSEvent.otherEvent(with: .systemDefined,
                                             location: .zero,
                                             modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                                             timestamp: 0,
                                             windowNumber: 0,
                                             context: nil,
                                             subtype: 8,
                                             data1: data1,
                                             data2: -1) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
