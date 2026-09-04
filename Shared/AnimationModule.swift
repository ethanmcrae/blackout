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
    /// Fixed seed for the simulation's randomness. Nil means pick one at
    /// random, which is what the app ships with; the verification harness sets
    /// it so a run can be reproduced exactly.
    var seed: UInt64? = nil
}

// MARK: - Seeded Randomness

/// SplitMix64. Small, fast, and identical across platforms and toolchains,
/// which Swift's own generator is not -- so a recorded frame hash stays valid.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
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
    case walkers   = "walkers"
    case wave      = "wave"
    case ripple    = "ripple"
    case terrain   = "terrain"
    case noise     = "noise"
    case rain      = "rain"
    case flow      = "flow"
    case waveField = "wavefield"
    case random    = "random"

    var displayName: String {
        switch self {
        case .walkers:   return "Walkers"
        case .wave:      return "Wave"
        case .ripple:    return "Ripple"
        case .terrain:   return "Terrain"
        case .noise:     return "Drift"
        case .rain:      return "Rain"
        case .flow:      return "Flow"
        case .waveField: return "Wave Field"
        case .random:    return "Random"
        }
    }

    static var selectable: [MovementType] {
        allCases.filter { $0 != .random }
    }

    var resolved: MovementType {
        self == .random ? Self.selectable.randomElement()! : self
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
