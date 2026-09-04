import IOKit.pwr_mgt
import Foundation

/// Holds an IOKit assertion so the display does not sleep while the overlay is up.
///
/// Holding the panel on is by far the largest power draw this app is
/// responsible for -- orders of magnitude more than drawing the animation. The
/// overlay stays up and stays locked whether or not the display is on, so
/// keeping it awake is a preference, not a requirement. `Keep Display Awake`
/// in the menu controls it and defaults to on, which is the long-standing
/// behaviour.
final class SleepPrevention {
    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false

    static let keepAwakeKey = "keepDisplayAwake"

    /// Defaults to true so behaviour is unchanged unless the user opts out.
    static var keepDisplayAwake: Bool {
        get {
            if UserDefaults.standard.object(forKey: keepAwakeKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: keepAwakeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: keepAwakeKey) }
    }

    func enable() {
        guard !isHeld, Self.keepDisplayAwake else { return }
        var id: IOPMAssertionID = 0
        // kIOPMAssertionTypeNoDisplaySleep is the legacy alias; the modern
        // name says exactly what is being prevented.
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            "Blackout overlay is active" as CFString,
            "Screen is intentionally blacked out and locked" as CFString,
            nil, nil, 0, nil,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            isHeld = true
        }
    }

    func disable() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHeld = false
    }
}
