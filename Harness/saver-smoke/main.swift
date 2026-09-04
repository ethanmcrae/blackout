import Cocoa
import ScreenSaver

// Does the built .saver bundle actually load and animate?
//
// build.sh does not codesign the bundle and nothing else here ever loads it,
// so a bundle that macOS refuses to open, or whose principal class is wrong,
// would ship silently broken. This loads it the way System Settings does.

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: saver-smoke <path to .saver>")
    exit(64)
}
let path = args[1]

guard let bundle = Bundle(path: path) else {
    print("FAIL: could not open bundle at \(path)")
    exit(1)
}
guard bundle.load() else {
    print("FAIL: bundle refused to load (code signature, architecture, or link error)")
    exit(1)
}
guard let cls = bundle.principalClass as? ScreenSaverView.Type else {
    print("FAIL: principal class is \(String(describing: bundle.principalClass)), not a ScreenSaverView")
    exit(1)
}
print("loaded principal class: \(cls)")

guard let view = cls.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), isPreview: false) else {
    print("FAIL: principal class would not initialise")
    exit(1)
}
print("instantiated: \(type(of: view))")

view.startAnimation()
// Drive frames the way the screen saver host does.
for _ in 0..<60 {
    view.animateOneFrame()
    RunLoop.current.run(until: Date().addingTimeInterval(0.001))
}
view.stopAnimation()

// It must have built a real grid, not an empty one.
let mirror = Mirror(reflecting: view)
print("subviews after start: \(view.subviews.count)")
guard !view.subviews.isEmpty else {
    print("FAIL: no animation view was installed")
    exit(1)
}
_ = mirror
print("PASS: saver bundle loads, instantiates and ticks 60 frames")
exit(0)
