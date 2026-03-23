import Cocoa

// MARK: - Animation Configuration

/// Shared configuration passed to any animation module.
struct AnimationConfig {
    let accentR: CGFloat
    let accentG: CGFloat
    let accentB: CGFloat
    let lightMode: Bool
    let movementType: MovementType
    var showFPS: Bool = false
}

// MARK: - Animation Module Protocol

/// Protocol for pluggable animation modules.
/// Each module is an NSView that knows how to generate and animate a pattern.
protocol AnimationModule: NSView {
    init(frame: NSRect, config: AnimationConfig)
    func startAnimation()
    func stopAnimation()
    /// Tick externally (for screen saver where the host drives the timer).
    /// Call this from animateOneFrame() instead of startAnimation().
    func externalTick()
}

// MARK: - Accent Color

enum AccentColor: String, CaseIterable {
    case blue   = "blue"
    case pink   = "pink"
    case green  = "green"
    case white  = "white"
    case random = "random"

    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .blue:   return (0.078, 0.404, 1.0)     // #1467FF
        case .pink:   return (0.957, 0.251, 0.639)   // #F440A3
        case .green:  return (0.125, 0.988, 0.561)    // #20FC8F
        case .white:  return (1.0, 1.0, 1.0)          // #FFFFFF
        case .random: return Self.allNonRandom.randomElement()!.rgb
        }
    }

    static let allNonRandom: [AccentColor] = [.blue, .pink, .green, .white]

    var displayName: String {
        switch self {
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .green: return "Green"
        case .white: return "White"
        case .random: return "Random"
        }
    }
}

// MARK: - Movement Type

enum MovementType: String, CaseIterable {
    case walkers = "walkers"
    case wave    = "wave"
    case ripple  = "ripple"
    case random  = "random"

    var displayName: String {
        switch self {
        case .walkers: return "Walkers"
        case .wave:    return "Wave"
        case .ripple:  return "Ripple"
        case .random:  return "Random"
        }
    }

    var resolved: MovementType {
        if self == .random {
            return [.walkers, .wave, .ripple].randomElement()!
        }
        return self
    }
}

// MARK: - Module Registry

/// All available animation modules. To add a new one:
/// 1. Create a new file in Shared/ implementing AnimationModule
/// 2. Add it to this list
enum AnimationModuleType: String, CaseIterable {
    case isometric = "isometric"

    var displayName: String {
        switch self {
        case .isometric: return "Isometric Grid"
        }
    }

    func createView(frame: NSRect, config: AnimationConfig) -> NSView & AnimationModule {
        switch self {
        case .isometric:
            return IsometricModule(frame: frame, config: config)
        }
    }
}
