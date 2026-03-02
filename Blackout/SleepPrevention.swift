import IOKit.pwr_mgt

final class SleepPrevention {
    private var assertionID: IOPMAssertionID = 0
    private var isActive = false

    func enable() {
        guard !isActive else { return }
        let reason = "Blackout overlay is active" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result == kIOReturnSuccess {
            isActive = true
        }
    }

    func disable() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }
}
