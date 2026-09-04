import Cocoa

var bad = 0

// 1. Does the password length actually reach the marks view?
let win = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                        styleMask: .borderless, backing: .buffered, defer: false)
win.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
win.passwordSlots = 8
win.showProgress(count: 3)          // installs the marks view
if win.marksSlotCount == 8 {
    print("  PASS  the password length reaches the marks view")
} else {
    print("  FAIL  marks view has slotCount \(win.marksSlotCount), expected 8"); bad += 1
}

// setting the length AFTER the view exists must also propagate
win.passwordSlots = 5
if win.marksSlotCount == 5 {
    print("  PASS  a later length change propagates too")
} else {
    print("  FAIL  marks view has slotCount \(win.marksSlotCount), expected 5"); bad += 1
}

// 2. Does the draw speed follow typing speed?
let marks = PasswordMarksView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
print("\n  gap since last key -> how long the mark takes to draw:")
var previous = Double.infinity
var monotonic = true
for gap in [0.05, 0.10, 0.20, 0.35, 0.60, 1.50] {
    marks.resetRhythm()
    _ = marks.entranceDuration(now: 100.0)          // seed the rhythm
    let d = marks.entranceDuration(now: 100.0 + gap)
    print(String(format: "     %5.2fs  ->  %.3fs", gap, d))
    if d > previous + 1e-9 { } else if previous != Double.infinity && d < previous { monotonic = false }
    previous = d
}
// use a non-zero base: zero is the "no history yet" sentinel
marks.resetRhythm(); _ = marks.entranceDuration(now: 500.0)
let fastest = marks.entranceDuration(now: 500.001)
marks.resetRhythm(); _ = marks.entranceDuration(now: 500.0)
let slowest = marks.entranceDuration(now: 510.0)
if fastest >= 0.049 && fastest <= 0.051 && slowest >= 0.199 && slowest <= 0.201 {
    print("  PASS  clamped to 0.05s at the fast end and 0.20s at the slow end")
} else {
    print("  FAIL  clamps are \(fastest) and \(slowest)"); bad += 1
}
if monotonic {
    print("  PASS  a shorter pause always draws at least as fast")
} else {
    print("  FAIL  draw time is not monotonic in the gap"); bad += 1
}
print("")
print(bad == 0 ? "ALL PASSED" : "\(bad) FAILED")
exit(bad == 0 ? 0 : 1)
