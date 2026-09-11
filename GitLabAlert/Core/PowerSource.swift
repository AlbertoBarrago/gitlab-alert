import Foundation
import IOKit.ps

/// Whether the Mac is currently running off the battery.
///
/// Used to widen the poll cadence. `ProcessInfo.isLowPowerModeEnabled` only
/// covers the explicit Low Power Mode switch, which most people never touch —
/// being on battery at all is the signal that matters for a background poller.
enum PowerSource {

    static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            // A desktop Mac reports no battery source at all, in which case we
            // fall through and answer false — which is the right answer.
            if let state = description[kIOPSPowerSourceStateKey as String] as? String {
                return state == (kIOPSBatteryPowerValue as String)
            }
        }
        return false
    }
}
