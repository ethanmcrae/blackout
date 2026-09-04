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

    /// True once startAnimation() has been called and stopAnimation() has not.
    private var wantsAnimation = false
    /// Set while the display is asleep or the window is fully occluded.
    private var isPaused = false
    /// Rate-limit the FPS text, which re-rasterises on the CPU when it changes.
    private var lastFPSTextUpdate: CFTimeInterval = 0

    var showFPS: Bool = false {
        didSet { updateFPSLayerVisibility() }
    }

    /// Set BLACKOUT_DISABLE_METAL=1 to exercise the Core Graphics path on a
    /// machine that has a working GPU. That path is the fallback for Macs
    /// without Metal, and without a way to reach it deliberately it would only
    /// ever be tested by the hardware nobody here owns.
    private static func makeRenderer() -> IsometricMetalRenderer? {
        if ProcessInfo.processInfo.environment["BLACKOUT_DISABLE_METAL"] == "1" { return nil }
        return IsometricMetalRenderer()
    }

    /// True when frames are going through the GPU.
    var isUsingMetal: Bool { metal != nil }

    /// Frame rate this module wants, for hosts that drive frames themselves.
    var preferredFPS: Double { sim.preferredFPS }

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
        self.metal = Self.makeRenderer()
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
        self.metal = Self.makeRenderer()
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
            // Two is enough at 24-30fps with a sub-millisecond GPU frame, and
            // it keeps the drawable wait itself a pacing signal rather than
            // letting the CPU run a frame ahead. The renderer's 3-slot
            // in-flight semaphore guards a different resource (CPU writes to
            // the instance buffers) and only needs to be >= this.
            mLayer.maximumDrawableCount = 2
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
        wantsAnimation = true
        sim.setSize(bounds.size)
        sim.start(now: CACurrentMediaTime())
        observeVisibility()
        resumeIfVisible()
    }

    func stopAnimation() {
        wantsAnimation = false
        stopTimer()
        stopObservingVisibility()
        sim.stop()
    }

    private func startTimer() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / sim.preferredFPS, repeats: true) { [weak self] _ in
            self?.step()
        }
        // No tolerance. This looked like a free power win, but the panel's
        // slowest refresh is 41.7ms, so several milliseconds of allowed
        // lateness is enough on its own to miss a refresh and judder. Pacing
        // wins over the handful of coalesced wakeups it would have bought.
        timer.tolerance = 0
        // Add to .common mode so it fires in screen savers and modal panels too
        RunLoop.current.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: Visibility

    /// Animating a surface nobody can see is pure waste, and this app is
    /// designed to sit untouched for hours. Pause on display sleep and on full
    /// window occlusion; resume on wake.
    private func observeVisibility() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(visibilityChanged),
                       name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(displaysSlept),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        wc.addObserver(self, selector: #selector(displaysWoke),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    private func stopObservingVisibility() {
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        let wc = NSWorkspace.shared.notificationCenter
        wc.removeObserver(self, name: NSWorkspace.screensDidSleepNotification, object: nil)
        wc.removeObserver(self, name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private func displaysSlept() { isPaused = true; stopTimer() }
    @objc private func displaysWoke()  { isPaused = false; resumeIfVisible() }

    @objc private func visibilityChanged(_ note: Notification) {
        guard let w = note.object as? NSWindow, w === window else { return }
        if w.occlusionState.contains(.visible) { resumeIfVisible() } else { stopTimer() }
    }

    private func resumeIfVisible() {
        guard wantsAnimation, !isPaused else { return }
        // A window with no occlusion information yet is treated as visible.
        if let w = window, !w.occlusionState.contains(.visible) { return }
        // Re-anchor the clock so the simulation does not jump on resume.
        // tick() clamps dt to 0.05 anyway, but this keeps it exact.
        sim.resyncClock(to: CACurrentMediaTime())
        startTimer()
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
            renderer.render(frame: frame_, params: renderParams, layer: mLayer,
                            minimumDuration: 1.0 / sim.preferredFPS)
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
        // Writing CATextLayer.string re-rasterises text on the CPU and commits
        // a CoreAnimation transaction alongside the Metal present. Once a
        // second is plenty for a counter that only changes once a second.
        let now = CACurrentMediaTime()
        guard now - lastFPSTextUpdate >= 1.0 else { return }
        lastFPSTextUpdate = now
        let backend = isUsingMetal ? "GPU" : "CPU"
        fpsLayer.string = "\(sim.currentFPS) FPS | \(sim.litEdgeCount) lit | " +
                          "\(sim.totalEdgeCount) total | \(backend)"
    }

    // MARK: - Cleanup

    deinit {
        animationTimer?.invalidate()
        animationTimer = nil
        stopObservingVisibility()
    }
}
