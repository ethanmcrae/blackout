import Foundation
import CoreGraphics

// MARK: - Render Parameters

/// Everything a renderer needs besides the per-frame instance list.
struct IsometricRenderParams {
    /// Logical size in points.
    var size: CGSize
    /// Backing scale factor (2.0 on Retina).
    var scale: CGFloat
    var accentR: CGFloat
    var accentG: CGFloat
    var accentB: CGFloat
    var lightMode: Bool
    var lineWidth: CGFloat = 1.2

    init(size: CGSize, scale: CGFloat, config: AnimationConfig) {
        self.size = size
        self.scale = scale
        self.accentR = config.accentR
        self.accentG = config.accentG
        self.accentB = config.accentB
        self.lightMode = config.lightMode
    }
}

// MARK: - Reference (CPU) Renderer

/// Core Graphics renderer. This is the *reference* implementation: the Metal
/// renderer is verified against its output pixel-for-pixel by Harness/.
///
/// Colour model (shared with the Metal shader): every segment is the accent
/// colour drawn source-over at `alpha = lit` on a black (or white, in light
/// mode) ground. That is algebraically identical to the old opaque
/// `accent * lit` / `lerp(white, accent, lit)` formulas for a single segment,
/// and blends more correctly where two segments cross.
final class IsometricCGRenderer {

    private(set) var endpoints: [SIMD4<Float>] = []
    private var generation: Int = -1

    /// Colours are built in an explicit sRGB space. `CGColor(red:green:blue:alpha:)`
    /// carries an unspecified space, which makes Core Graphics convert it into
    /// the destination on every stroke and shifts the accent hue in dim pixels.
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Stroke colours cached per quantised alpha -- one CGColor per segment
    /// otherwise dominates the cost of this path.
    private var strokeCache: [Int: CGColor] = [:]
    private var cachedAccent: (CGFloat, CGFloat, CGFloat) = (-1, -1, -1)

    private func strokeColor(_ params: IsometricRenderParams, alpha: CGFloat) -> CGColor {
        let accent = (params.accentR, params.accentG, params.accentB)
        if accent != cachedAccent {
            cachedAccent = accent
            strokeCache.removeAll(keepingCapacity: true)
        }
        let key = Int((alpha * 255).rounded())
        if let c = strokeCache[key] { return c }
        let c = CGColor(colorSpace: Self.colorSpace,
                        components: [params.accentR, params.accentG, params.accentB,
                                     CGFloat(key) / 255.0])!
        strokeCache[key] = c
        return c
    }

    var name: String { "CoreGraphics" }

    /// Re-upload static geometry when the simulation regenerates.
    func setGeometry(_ newEndpoints: [SIMD4<Float>], generation newGeneration: Int) {
        guard newGeneration != generation else { return }
        endpoints = newEndpoints
        generation = newGeneration
    }

    /// Draw one frame. `ctx` must be y-up with the origin at the bottom-left
    /// and already scaled to points (i.e. 1 unit == 1 point).
    func draw(frame: IsometricFrame, params: IsometricRenderParams, in ctx: CGContext) {
        let ground: CGFloat = params.lightMode ? 1 : 0
        ctx.setFillColor(CGColor(colorSpace: Self.colorSpace,
                                 components: [ground, ground, ground, 1])!)
        ctx.fill(CGRect(origin: .zero, size: params.size))

        guard !endpoints.isEmpty else { return }

        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)
        ctx.setLineWidth(params.lineWidth)
        ctx.setShouldAntialias(true)

        for inst in frame.instances {
            let idx = Int(inst.edge)
            guard idx >= 0, idx < endpoints.count else { continue }
            let e = endpoints[idx]
            let ax = CGFloat(e.x), ay = CGFloat(e.y)
            let dx = CGFloat(e.z) - ax, dy = CGFloat(e.w) - ay
            let t0 = CGFloat(inst.t0), t1 = CGFloat(inst.t1)
            if t1 <= t0 { continue }

            ctx.setStrokeColor(strokeColor(params, alpha: CGFloat(inst.lit)))
            ctx.move(to: CGPoint(x: ax + dx * t0, y: ay + dy * t0))
            ctx.addLine(to: CGPoint(x: ax + dx * t1, y: ay + dy * t1))
            ctx.strokePath()
        }
    }
}
