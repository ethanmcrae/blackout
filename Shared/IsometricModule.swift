import Cocoa
import Metal
import QuartzCore

// MARK: - Isometric Module

/// Hosts `IsometricSimulation` and draws it.
///
/// The simulation is pure (no AppKit, no drawing) and hands each frame to a
/// renderer. On any Metal-capable Mac that renderer is `IsometricMetalRenderer`,
/// which draws the whole frame in one instanced draw call on the GPU; if Metal
/// is unavailable the view falls back to `IsometricCGRenderer` through the
/// normal `draw(_:)` path. Both renderers consume the identical frame data, so
/// Harness/ can diff them pixel-for-pixel.
final class IsometricModule: NSView, AnimationModule {

    // MARK: State

    private let config: AnimationConfig
    private let sim: IsometricSimulation
    private var frame_ = IsometricFrame()

    private let metal: IsometricMetalRenderer?
    private let cg = IsometricCGRenderer()

    private var animationTimer: Timer?
    private var fpsLayer: CATextLayer?

    var showFPS: Bool = false {
        didSet { updateFPSLayerVisibility() }
    }

    /// True when frames are going through the GPU.
    var isUsingMetal: Bool { metal != nil }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    private var renderParams: IsometricRenderParams {
        var p = IsometricRenderParams(size: bounds.size, scale: backingScale, config: config)
        p.lineWidth = 1.2
        return p
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    // MARK: Lifecycle

    /// Protocol-required init: creates module from AnimationConfig.
    required init(frame frameRect: NSRect, config: AnimationConfig) {
        self.config = config
        self.sim = IsometricSimulation(config: config, size: frameRect.size)
        self.metal = IsometricMetalRenderer()
        super.init(frame: frameRect)
        self.showFPS = config.showFPS
        commonSetup()
    }

    convenience init(frame frameRect: NSRect, accentR: CGFloat, accentG: CGFloat, accentB: CGFloat,
                     lightMode: Bool = false, movementType: MovementType = .walkers) {
        self.init(frame: frameRect,
                  config: AnimationConfig(accentR: accentR, accentG: accentG, accentB: accentB,
                                          lightMode: lightMode, movementType: movementType))
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect,
                  config: AnimationConfig(accentR: 0.078, accentG: 0.404, accentB: 1.0,
                                          lightMode: false, movementType: .walkers))
    }

    required init?(coder: NSCoder) {
        self.config = AnimationConfig(accentR: 0.078, accentG: 0.404, accentB: 1.0,
                                      lightMode: false, movementType: .walkers)
        self.sim = IsometricSimulation(config: config, size: .zero)
        self.metal = IsometricMetalRenderer()
        super.init(coder: coder)
        commonSetup()
    }

    private func commonSetup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        if let mLayer = metalLayer, let renderer = metal {
            mLayer.device = renderer.device
            mLayer.pixelFormat = .bgra8Unorm
            mLayer.framebufferOnly = true
            mLayer.isOpaque = true
            mLayer.backgroundColor = (config.lightMode ? NSColor.white : NSColor.black).cgColor
            mLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            mLayer.contentsScale = backingScale
            mLayer.drawableSize = CGSize(width: bounds.width * backingScale,
                                         height: bounds.height * backingScale)
            // Never block the animation timer waiting on a drawable.
            mLayer.allowsNextDrawableTimeout = true
        } else {
            layer?.backgroundColor = (config.lightMode ? NSColor.white : NSColor.black).cgColor
        }
        // Must run after `wantsLayer`, otherwise there is no parent layer to
        // attach the counter to and it silently never appears.
        updateFPSLayerVisibility()
    }

    override func makeBackingLayer() -> CALayer {
        if metal != nil { return CAMetalLayer() }
        return super.makeBackingLayer()
    }

    // MARK: Geometry changes

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sim.setSize(newSize)
        syncDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDrawableSize()
    }

    private func syncDrawableSize() {
        guard let mLayer = metalLayer else { return }
        let scale = backingScale
        mLayer.contentsScale = scale
        let px = CGSize(width: max(bounds.width * scale, 1),
                        height: max(bounds.height * scale, 1))
        if mLayer.drawableSize != px { mLayer.drawableSize = px }
    }

    // MARK: Animation

    func startAnimation() {
        sim.setSize(bounds.size)
        sim.start(now: CACurrentMediaTime())
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / sim.preferredFPS, repeats: true) { [weak self] _ in
            self?.step()
        }
        // Add to .common mode so it fires in screen savers and modal panels too
        RunLoop.current.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        sim.stop()
    }

    /// For screen saver: host calls this each frame instead of using internal timer.
    func externalTick() {
        sim.setSize(bounds.size)
        sim.start(now: CACurrentMediaTime())
        step()
    }

    private func step() {
        sim.tick(now: CACurrentMediaTime())
        sim.fill(frame: &frame_)
        updateFPSLayerText()

        if let renderer = metal, let mLayer = metalLayer {
            renderer.setGeometry(sim.edgeEndpoints, generation: frame_.generation)
            renderer.render(frame: frame_, params: renderParams, layer: mLayer)
        } else {
            needsDisplay = true
        }
    }

    // MARK: CPU fallback drawing

    override func draw(_ dirtyRect: NSRect) {
        guard metal == nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        cg.setGeometry(sim.edgeEndpoints, generation: frame_.generation)
        cg.draw(frame: frame_, params: renderParams, in: ctx)
    }

    // MARK: FPS overlay

    private func updateFPSLayerVisibility() {
        if showFPS {
            if fpsLayer == nil {
                let text = CATextLayer()
                text.fontSize = 12
                text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                text.foregroundColor = (config.lightMode ? NSColor.black : NSColor.white)
                    .withAlphaComponent(0.5).cgColor
                text.contentsScale = backingScale
                text.frame = CGRect(x: 10, y: 10, width: 420, height: 16)
                layer?.addSublayer(text)
                fpsLayer = text
            }
            fpsLayer?.isHidden = false
        } else {
            fpsLayer?.isHidden = true
        }
    }

    private func updateFPSLayerText() {
        guard showFPS, let fpsLayer else { return }
        let backend = isUsingMetal ? "GPU" : "CPU"
        fpsLayer.string = "\(sim.currentFPS) FPS | \(sim.litEdgeCount) lit | " +
                          "\(sim.totalEdgeCount) total | \(backend)"
    }

    // MARK: - Cleanup

    deinit {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}
