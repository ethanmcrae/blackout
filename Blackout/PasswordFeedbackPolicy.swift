import Foundation

/// Decides what the password marks should show, given what the matcher said.
///
/// Kept separate from the matcher and the view because what the matcher knows
/// and what the screen admits are different things, and the difference needs to
/// live in one small testable place.
///
/// The display follows the matcher's REAL progress. An earlier version counted
/// keystrokes independently, which drifted out of step with the matcher: the
/// matcher does not reset to zero on a wrong key (a wrong key that happens to
/// be the password's first character leaves it at one), so after a failed
/// attempt the two disagreed and typing the correct password showed a string of
/// errors while quietly succeeding. Follow the matcher; do not model it.
struct PasswordFeedbackPolicy {

    enum Display: Equatable {
        case marks(Int)     // normal progress
        case error(Int)     // attempt failed; the count is marks that were showing
        case clear
        case unlock
    }

    /// Marks currently on screen.
    private(set) var displayed = 0

    mutating func reset() { displayed = 0 }

    /// `progress` is the matcher's index AFTER processing the key.
    mutating func register(_ result: PasswordMatcher.Result, progress: Int) -> Display {
        if case .complete = result {
            displayed = 0
            return .unlock
        }

        // With nothing on screen, the first key of an attempt always shows one
        // mark, whatever it was. A first character that visibly succeeds or
        // fails is a free oracle: it lets someone test one character at a time
        // and read the answer off the screen.
        if displayed == 0 {
            // max(progress, 1) rather than a flat 1: a correct first key leaves
            // the matcher at 1 and a wrong one at 0, and both must look the
            // same, but anything higher is real progress worth showing.
            displayed = max(progress, 1)
            return .marks(displayed)
        }

        switch result {
        case .incorrect:
            let failed = displayed
            displayed = 0
            return .error(failed)
        case .correct:
            displayed = max(progress, 1)
            return .marks(displayed)
        case .complete:
            displayed = 0
            return .unlock
        }
    }

    mutating func registerBackspace(progress: Int) -> Display {
        displayed = max(progress, 0)
        return displayed > 0 ? .marks(displayed) : .clear
    }
}


/// Owns the matcher and the display policy together, so the two can never drift
/// apart. Everything the overlay needs to know about password entry goes
/// through here.
final class PasswordEntry {

    private let matcher: PasswordMatcher
    private var policy = PasswordFeedbackPolicy()

    init(password: String) {
        matcher = PasswordMatcher(password: password)
    }

    /// Number of characters in the password, so the marks can lay out a fixed
    /// row rather than re-centring on every keystroke.
    var length: Int { matcher.length }

    func key(_ char: Character) -> PasswordFeedbackPolicy.Display {
        let result = matcher.processKey(char)
        let display = policy.register(result, progress: matcher.progress)
        if case .error = display {
            // A failed attempt starts over completely.
            //
            // The matcher used to keep partial progress here: a wrong key that
            // happened to equal the password's FIRST character left it at index
            // one rather than zero. The password then completed a keystroke
            // earlier than the typist expected, and the marks dissolved while
            // the last cube was still being drawn -- which is what "it vanishes
            // at the second-to-last character" was. It also made the row
            // undercount for the rest of the attempt.
            matcher.reset()
            policy.reset()
        }
        return display
    }

    func backspace() -> PasswordFeedbackPolicy.Display {
        policy.registerBackspace(progress: matcher.processBackspace())
    }

    func reset() {
        matcher.reset()
        policy.reset()
    }
}
