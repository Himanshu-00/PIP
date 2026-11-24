import Foundation
import IOKit.ps

/// Watches the battery via IOKit and reports *changes* worth flashing,
/// not a continuous readout — the island should blip, then get out of the way.
@MainActor
final class PowerMonitor: ObservableObject {

    @Published private(set) var percent: Int = 100
    @Published private(set) var isPluggedIn = false

    /// Called on the main actor when something noteworthy happens.
    var onEvent: ((NotchEvent) -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var lastPlugged: Bool?
    private var lastFull = false
    private var warnedLow = false

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { raw in
            guard let raw else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(raw).takeUnretainedValue()
            Task { @MainActor in monitor.refresh() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        refresh(silent: true)   // prime state without flashing on launch
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
    }

    func refresh(silent: Bool = false) {
        guard let now = snapshot() else { return }
        percent = now.percent
        isPluggedIn = now.plugged

        defer { lastPlugged = now.plugged }
        guard !silent else {
            lastFull = now.plugged && now.percent >= 100
            warnedLow = now.percent <= 20 && !now.plugged
            return
        }

        // Only plugging IN is worth a blip. You unplug the cable yourself —
        // you were there, you did it, and an island announcing it back to you
        // is pure noise. Plugging in is the one where confirmation helps,
        // because you often can't tell whether the connector seated.
        if let was = lastPlugged, was != now.plugged, now.plugged {
            onEvent?(.pluggedIn(percent: now.percent))
        }

        let full = now.plugged && now.percent >= 100
        if full && !lastFull { onEvent?(.fullyCharged) }
        lastFull = full

        if now.percent <= 20 && !now.plugged {
            if !warnedLow {
                warnedLow = true
                onEvent?(.lowBattery(percent: now.percent))
            }
        } else if now.percent > 25 || now.plugged {
            warnedLow = false
        }
    }

    /// Whether the machine is running off the battery right now.
    ///
    /// Nonisolated and static because the background indexer asks it from
    /// outside the main actor, and a one-off IOKit read is cheaper than
    /// plumbing a published property through to a thing that only wants to
    /// know whether to do optional work.
    ///
    /// Defaults to "not on battery" when the answer is unavailable — a desktop
    /// has no power source to report, and refusing to index on a Mac mini
    /// because IOKit said nothing would be the wrong way round.
    nonisolated static var isOnBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            return state == kIOPSBatteryPowerValue
        }
        return false
    }

    private func snapshot() -> (percent: Int, charging: Bool, plugged: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else { continue }

            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            return (percent, charging, plugged)
        }
        return nil
    }
}
