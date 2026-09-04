import Foundation

var failures = 0

/// Type `typed` into a fresh matcher and collect what the screen would show.
func run(_ typed: String, password: String) -> [PasswordFeedbackPolicy.Display] {
    let entry = PasswordEntry(password: password)
    var out: [PasswordFeedbackPolicy.Display] = []
    for ch in typed {
        let d = entry.key(ch)
        out.append(d)
        if d == .unlock { break }
    }
    return out
}

func check(_ name: String, _ typed: String, _ expected: [PasswordFeedbackPolicy.Display],
           password: String = "alpha") {
    let got = run(typed, password: password)
    if got == expected {
        print("  PASS  \(name)")
    } else {
        print("  FAIL  \(name)")
        print("        typed \"\(typed)\" against \"\(password)\"")
        print("        got      \(got)")
        print("        expected \(expected)")
        failures += 1
    }
}

print("password feedback policy   (password \"alpha\" unless stated)\n")

check("the correct password unlocks cleanly", "alpha",
      [.marks(1), .marks(2), .marks(3), .marks(4), .unlock])

check("a wrong first key still shows one mark", "z", [.marks(1)])

check("a wrong start is revealed on the second key", "zz",
      [.marks(1), .error(1)])

check("a wrong second key is revealed", "az",
      [.marks(1), .error(1)])

// The reported bug: type a wrong password, then type the real one. The display
// used to report an error on EVERY subsequent key while the matcher was
// quietly succeeding, then unlock out of nowhere.
print("\nregression: typing the real password after a failed attempt")
check("  recovers after one error and then tracks progress", "zzzalpha",
      [.marks(1), .error(1), .marks(1),
       .marks(1), .marks(2), .marks(3), .marks(4), .unlock])

check("  a longer wrong prefix still recovers", "qwertyalpha",
      [.marks(1), .error(1),
       .marks(1), .error(1),
       .marks(1), .error(1),
       .marks(1),                       // 'a', disguised first key of a new attempt
       .marks(2), .marks(3), .marks(4), .unlock])

// The reported "it vanishes at the second-to-last character" bug. A wrong key
// that equals the password's FIRST character used to leave the matcher at
// index one, so the password completed a keystroke early and the marks
// dissolved mid-draw.
print("\nregression: a failed attempt must not leave partial progress behind")
// A failed attempt starts over completely, so the retype must include the
// first character. Continuing from where the mistake happened does NOT work,
// and that is the point: it is what used to unlock a keystroke early.
check("  retyping after a same-as-first mistake needs the FULL password",
      "aaabcdefgh",
      [.marks(1), .error(1),
       .marks(1), .marks(2), .marks(3), .marks(4),
       .marks(5), .marks(6), .marks(7), .unlock],
      password: "abcdefgh")

check("  continuing from the mistake instead of restarting does not unlock",
      "aabcdefgh",
      [.marks(1), .error(1),
       .marks(1), .error(1), .marks(1), .error(1),
       .marks(1), .error(1), .marks(1)],
      password: "abcdefgh")

check("  and the unlock lands on the last key, not the one before it",
      "abcdefgh",
      [.marks(1), .marks(2), .marks(3), .marks(4),
       .marks(5), .marks(6), .marks(7), .unlock],
      password: "abcdefgh")

check("  a half-typed password then a mistake then the real one", "alxalpha",
      [.marks(1), .marks(2), .error(2),
       .marks(1), .marks(2), .marks(3), .marks(4), .unlock])

print("\nno run of the real password should ever produce two errors in a row:")
var consecutive = 0
for prefix in ["z", "zz", "zzz", "q", "qq", "lp", "hh", "ax"] {
    let seq = run(prefix + "alpha", password: "alpha")
    var lastWasError = false
    var bad = false
    for d in seq {
        if case .error = d {
            if lastWasError { bad = true }
            lastWasError = true
        } else { lastWasError = false }
    }
    let unlocked = seq.last == .unlock
    if bad || !unlocked {
        print("  FAIL  prefix \"\(prefix)\": \(seq)")
        failures += 1
    } else { consecutive += 1 }
}
if consecutive == 8 { print("  PASS  all 8 wrong prefixes recover and unlock") }

print("\nthe first keystroke must look identical whatever was typed:")
var firstDisplays = Set<String>()
for code in 97...122 {
    let ch = Character(UnicodeScalar(code)!)
    let entry = PasswordEntry(password: "alpha")
    firstDisplays.insert("\(entry.key(ch))")
}
if firstDisplays.count == 1 {
    print("  PASS  all 26 first characters produce \(firstDisplays.first!)")
} else {
    print("  FAIL  \(firstDisplays.count) distinct displays: \(firstDisplays)")
    failures += 1
}

print("\nedge cases:")
check("  single-character password unlocks immediately", "x", [.unlock], password: "x")
check("  wrong key on a single-character password", "q", [.marks(1)], password: "x")

do {
    let entry = PasswordEntry(password: "alpha")
    _ = entry.key("a")
    _ = entry.key("l")
    let d1 = entry.backspace()
    let d2 = entry.backspace()
    if d1 == .marks(1) && d2 == .clear {
        print("  PASS  backspace walks the row back and then clears")
    } else {
        print("  FAIL  backspace gave \(d1), \(d2)"); failures += 1
    }
}

print("")
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
