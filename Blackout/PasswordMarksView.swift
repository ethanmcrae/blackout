import Cocoa

/// The marks shown while a password is being typed.
///
/// Each mark is a small isometric cube: a hexagon silhouette with three
/// interior spokes, which is what a cube looks like viewed down its body
/// diagonal. That silhouette is one the grid behind never produces at this
/// scale, so the marks separate from a busy animated background by structure
/// rather than by brightness -- which matters, because this sits on a lock
/// screen and must not be readable from across a room.
final class PasswordMarksView: NSView {

    // MARK: Geometry

    private let slotWidth: CGFloat = 42
    private let markRadius: CGFloat = 11
    private let lineWidth: CGFloat = 3.0

    /// Marks beyond this are not drawn, so password length cannot be counted
    /// off a photograph. See `overflowMarks`.
    private let maxVisibleMarks = 8

    // MARK: State

    private(set) var count: Int = 0
    private var isError = false

    /// How many slots the row is laid out for: the password's length, capped
    /// at `maxVisibleMarks`. With this set, the row is centred once for the
    /// finished password and marks fill left to right into fixed positions, so
    /// nothing shifts as you type. Zero falls back to centring on whatever is
    /// currently shown.
    ///
    /// This does tell an onlooker how long the password is. That is a
    /// deliberate trade for a row that holds still.
    var slotCount: Int = 0 {
        didSet { needsDisplay = true }
    }

    /// 0...1, how far the newest mark is through being drawn on.
    /// Internal rather than private so the render harness can pose a frame.
    var entrancePhase: CGFloat = 1
    /// 0...1, the unlock animation. Internal for the same reason.
    var successPhase: CGFloat = 0

    private var entranceTimer: Timer?
    private var successTimer: Timer?

    /// When the last mark arrived, so the next one can be drawn at a speed that
    /// matches how fast you are typing.
    private var lastGrowTime: CFTimeInterval = 0

    /// The slot a mark is being un-drawn from, and how much of it is left.
    /// Backspace reverses the entrance rather than snapping the mark away.
    private var removingIndex: Int?
    var removalPhase: CGFloat = 0
    private var removalTimer: Timer?

    /// Cancel an un-draw immediately. Needed when a new mark claims the same
    /// slot: a slot cannot be erasing and drawing at the same time, so the
    /// retreating mark has to go at once rather than fight the new one.
    /// Forget the typing rhythm, so a new attempt starts at the default speed.
    func resetRhythm() { lastGrowTime = 0 }

    private func cancelRemoval() {
        removalTimer?.invalidate()
        removalTimer = nil
        removingIndex = nil
        removalPhase = 0
    }

    /// Marks are drawn against the ground, not in the animation's accent
    /// colour: matching the accent made them camouflage against the very thing
    /// they have to stay legible over. White on the dark ground, black on the
    /// light one.
    var lightMode: Bool = false {
        didSet { needsDisplay = true }
    }
    /// Stroke brightness: white 0.30 on the dark ground, mirrored on the light
    /// one. A little above the 0.15 the original asterisks used, and well below
    /// full. Legibility comes mostly from the dark plate behind each mark
    /// rather than from the strokes being bright, which is what lets them stay
    /// this quiet. One number, easy to move either way.
    var markLevel: CGFloat = 0.30
    private var markColour: NSColor {
        NSColor(white: lightMode ? 1.0 - markLevel : markLevel, alpha: 1)
    }
    private var errorColour: NSColor {
        lightMode ? NSColor(red: 1.0, green: 0.62, blue: 0.62, alpha: 1)
                  : NSColor(red: 0.60, green: 0.0, blue: 0.0, alpha: 1)
    }
    /// The plate blanks the artwork under a mark, so it has to be the ground
    /// colour, and its shadow has to fade toward the ground too.
    private var plateWhite: CGFloat { lightMode ? 0.98 : 0.02 }
    private var shadowWhite: CGFloat { lightMode ? 1.0 : 0.0 }

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    // MARK: Updating

    func setCount(_ newCount: Int, error: Bool) {
        let grew = newCount > count && !error
        let shrank = newCount < count && !error
        let vacated = count - 1
        count = newCount
        isError = error
        successPhase = 0
        successTimer?.invalidate(); successTimer = nil

        if grew {
            // A new mark takes the slot, so anything retreating there goes now.
            cancelRemoval()
            entrancePhase = 0
            animate(\.entrancePhase, over: entranceDuration()) { self.entranceTimer = $0 }
        } else if shrank {
            entrancePhase = 1
            cancelRemoval()
            removingIndex = vacated
            removalPhase = 1
            animate(\.removalPhase, over: 0.18, from: 1, to: 0) { self.removalTimer = $0 }
        } else {
            entrancePhase = 1
            cancelRemoval()
        }
        needsDisplay = true
    }

    /// The unlock. Marks expand and dissolve outward, left to right, riding the
    /// overlay's own fade rather than delaying it.
    /// `expansion` scales how far the marks swell as they go. The quick unlock
    /// pops them outward; the fancy one lets them drift and fade instead, so
    /// the sweep behind is the thing that moves.
    var successExpansion: CGFloat = 1.9

    func playSuccess(over duration: CFTimeInterval = 0.34, expansion: CGFloat = 1.9) {
        guard count > 0 else { return }
        isError = false
        entrancePhase = 1
        successPhase = 0
        successExpansion = expansion
        animate(\.successPhase, over: duration) { self.successTimer = $0 }
        needsDisplay = true
    }

    /// How long to spend drawing the next mark. The gap since the previous
    /// keystroke sets it, so typing quickly draws quickly and the marks keep up
    /// with you rather than queueing behind a fixed animation. Clamped at both
    /// ends: never so fast it is a pop, never so slow it lags a deliberate
    /// keypress.
    func entranceDuration(now: CFTimeInterval = CACurrentMediaTime()) -> CFTimeInterval {
        defer { lastGrowTime = now }
        guard lastGrowTime > 0 else { return 0.20 }
        let gap = now - lastGrowTime
        return min(max(gap * 0.55, 0.05), 0.20)
    }

    private func animate(_ key: ReferenceWritableKeyPath<PasswordMarksView, CGFloat>,
                         over duration: CFTimeInterval,
                         from: CGFloat = 0, to: CGFloat = 1,
                         store: (Timer) -> Void) {
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let p = CGFloat(min((CACurrentMediaTime() - start) / duration, 1.0))
            self[keyPath: key] = from + (to - from) * p
            self.needsDisplay = true
            if p >= 1 {
                t.invalidate()
                if key == \PasswordMarksView.removalPhase { self.removingIndex = nil }
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        store(timer)
    }

    private var visibleMarks: Int { min(count, maxVisibleMarks) }
    private var overflowMarks: Bool { count > maxVisibleMarks }

    // MARK: Drawing

    /// The six hexagon vertices, starting at the top and going clockwise.
    private func vertices(cx: CGFloat, cy: CGFloat, r: CGFloat) -> [CGPoint] {
        [90.0, 30.0, -30.0, -90.0, -150.0, 150.0].map { deg in
            let a = deg * .pi / 180
            return CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
        }
    }

    /// Draw the perimeter as a line being traced on, `fraction` of the way
    /// round. This is what "trace the entrance" means: instead of the whole
    /// shape popping into existence at a smaller scale, the cube is drawn, one
    /// edge at a time, the way you would draw it by hand.
    private func tracePerimeter(_ ctx: CGContext, verts: [CGPoint], fraction: CGFloat) {
        guard fraction > 0 else { return }
        let total = fraction * 6
        let whole = Int(total)
        let partial = total - CGFloat(whole)
        ctx.move(to: verts[0])
        for i in 0..<min(whole, 6) {
            ctx.addLine(to: verts[(i + 1) % 6])
        }
        if whole < 6 && partial > 0 {
            let a = verts[whole % 6], b = verts[(whole + 1) % 6]
            ctx.addLine(to: CGPoint(x: a.x + (b.x - a.x) * partial,
                                    y: a.y + (b.y - a.y) * partial))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let n = visibleMarks

        let originX: CGFloat
        if slotCount > 0 {
            // Fixed slots: the row is sized for the whole password, so a mark
            // lands in the same place every time and never moves afterwards.
            originX = bounds.midX - CGFloat(min(slotCount, maxVisibleMarks)) * slotWidth / 2
        } else {
            // No length known. Centre on what is showing, taking the width
            // from the animation phase so the row glides rather than jumping.
            var extent = CGFloat(n)
            if removingIndex != nil, removalPhase > 0 {
                extent += removalPhase
            } else if n > 0, entrancePhase < 1 {
                extent = CGFloat(n - 1) + entrancePhase
            }
            originX = bounds.midX - extent * slotWidth / 2
        }
        let y = bounds.midY

        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        // The live marks, plus one retreating out of the slot beyond them.
        var indices = Array(0..<n)
        if let r = removingIndex, removalPhase > 0 { indices.append(r) }

        for i in indices {
            let isRemoving = (i == removingIndex && i >= n)
            let isNewest = !isRemoving && (i == n - 1)

            // Unlock: each mark expands and dissolves, staggered left to right.
            var scale: CGFloat = 1
            var fade: CGFloat = 1
            if successPhase > 0 {
                let local = min(max((successPhase - CGFloat(i) * 0.055) / 0.55, 0), 1)
                scale = 1 + local * successExpansion
                fade = 1 - local
                if fade <= 0 { continue }
            }

            // Entrance draws a mark on; backspace runs the same trace in
            // reverse, so a mark is erased the way it arrived.
            let trace = isRemoving ? removalPhase : (isNewest ? entrancePhase : 1)
            if trace <= 0 { continue }
            let spokeIn = min(max((trace - 0.55) / 0.45, 0), 1)

            // Solid strokes. These were drawn at half alpha, with older marks
            // stepped further back, which made every mark look washed out and
            // let the grid show through the lines themselves. The plate behind
            // each mark is what keeps it legible, so the strokes do not need to
            // be translucent as well. `fade` is the unlock dissolve only.
            let alpha: CGFloat = fade

            let colour = (isError ? errorColour : markColour).withAlphaComponent(alpha)

            let r = markRadius * scale
            let cx = originX + CGFloat(i) * slotWidth + slotWidth / 2
            let verts = vertices(cx: cx, cy: y, r: r)
            let spokeIdx = [0, 2, 4]   // top, lower-right, lower-left

            // Each mark sits on its own dark plate with a soft shadow around
            // it. Carving only a rim was not enough separation: the marks are
            // the same colour as the grid, so wherever a bright edge ran
            // through one it disappeared. The plate blanks the artwork under
            // the mark, and the shadow fades the grid out around it rather
            // than cutting it off, so the mark reads without being brighter.
            let plateAlpha = min(trace * 3, 1) * fade
            if plateAlpha > 0 {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 11,
                              color: NSColor(white: shadowWhite, alpha: 0.95 * plateAlpha).cgColor)
                ctx.setFillColor(NSColor(white: plateWhite, alpha: 0.94 * plateAlpha).cgColor)
                let plate = vertices(cx: cx, cy: y, r: r + 4.5)
                ctx.move(to: plate[0])
                for v in plate.dropFirst() { ctx.addLine(to: v) }
                ctx.closePath()
                ctx.fillPath()
                ctx.restoreGState()
            }

            // Silhouette.
            ctx.setStrokeColor(colour.cgColor)
            ctx.setLineWidth(lineWidth)
            tracePerimeter(ctx, verts: verts, fraction: trace)
            ctx.strokePath()

            // Interior edges sit lighter. Weight carries the lighting, because
            // there is no brightness to spare.
            if spokeIn > 0 {
                // Weight, not opacity, distinguishes the interior edges from
                // the silhouette.
                ctx.setStrokeColor(colour.cgColor)
                ctx.setLineWidth(lineWidth * 0.62)
                for k in spokeIdx {
                    let v = verts[k]
                    ctx.move(to: CGPoint(x: cx, y: y))
                    ctx.addLine(to: CGPoint(x: cx + (v.x - cx) * spokeIn,
                                            y: y + (v.y - y) * spokeIn))
                }
                ctx.strokePath()
            }
        }

        // A truncated row is marked with a half-cube chevron, in the same
        // isometric language as everything else.
        if overflowMarks && successPhase == 0 {
            ctx.setStrokeColor(markColour.withAlphaComponent(0.20).cgColor)
            ctx.setLineWidth(lineWidth * 0.8)
            let hx = originX - slotWidth * 0.5
            let hr = markRadius * 0.6
            let v = vertices(cx: hx, cy: y, r: hr)
            ctx.move(to: v[1]); ctx.addLine(to: v[0])
            ctx.addLine(to: v[5]); ctx.addLine(to: v[4]); ctx.addLine(to: v[3])
            ctx.strokePath()
        }
    }

    deinit {
        entranceTimer?.invalidate()
        successTimer?.invalidate()
    }
}
