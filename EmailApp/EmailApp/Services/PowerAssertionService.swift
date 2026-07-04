import IOKit.pwr_mgt
import Foundation

/// Prevents the Mac from sleeping while a sync is actually in flight —
/// released the instant it finishes. Only engages at all if Settings >
/// General > "Keep computer awake during sync" is on.
enum PowerAssertionService {
    private static var assertionID: IOPMAssertionID = 0
    private static var isHeld = false

    @MainActor
    static func beginSyncIfEnabled() {
        guard AppSettings.shared.keepAwakeDuringSync, !isHeld else { return }
        let reason = "EmailApp is syncing mail" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        isHeld = result == kIOReturnSuccess
    }

    static func endSync() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        isHeld = false
    }
}
