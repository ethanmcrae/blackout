import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import QuartzCore
import AppKit

// MARK: - Harness
//
// Verification tool for the Metal port of the isometric animation.
//
// The simulation is pure and deterministic given a frame sequence, and BOTH
// renderers consume the exact same `IsometricFrame`. So a pixel diff between
// them isolates the rendering change with no simulation noise at all -- which
// is the thing that is otherwise impossible to eyeball.
//
//   compare   render N frames through both renderers, diff them, report stats
//   sheet     write a contact sheet of frames so the animation can be looked at
//   bench     time the CPU cost of each renderer over N frames
//
// Usage: isoharness <command> [--frames N] [--size WxH] [--scale S]
//                             [--movement walkers|wave|ripple] [--color blue|pink|green|white]
//                             [--light] [--out DIR] [--seed N]

// MARK: - Arguments

struct Args {
    var command = "compare"
    var frames = 120
    var size = CGSize(width: 1728, height: 1117)
    var scale: CGFloat = 2.0
    var movement: MovementType = .walkers
    var color: AccentColor = .blue
    var light = false
    var out = "./harness-out"
    var sheetColumns = 4
    var sheetEvery = 20
    /// Crop rect in points, applied to the images written out by `compare`.
    var seconds = 6.0
    /// Crop rect in points, applied to the images written out by `compare`.
    var crop: CGRect? = nil
    /// Nearest-neighbour magnification for written images.
    var zoom = 1

    static func parse() -> Args {
        var a = Args()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        var positional: [String] = []
        while let arg = it.next() {
            switch arg {
            case "--frames":   a.frames = Int(it.next() ?? "") ?? a.frames
            case "--scale":    a.scale = CGFloat(Double(it.next() ?? "") ?? Double(a.scale))
            case "--out":      a.out = it.next() ?? a.out
            case "--light":    a.light = true
            case "--every":    a.sheetEvery = Int(it.next() ?? "") ?? a.sheetEvery
            case "--columns":  a.sheetColumns = Int(it.next() ?? "") ?? a.sheetColumns
            case "--zoom":     a.zoom = Int(it.next() ?? "") ?? a.zoom
            case "--seconds":  a.seconds = Double(it.next() ?? "") ?? a.seconds
            case "--crop":
                if let v = it.next() {
                    let p = v.split(separator: ",").compactMap { Double($0) }
                    if p.count == 4 { a.crop = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
                }
            case "--movement":
                if let v = it.next(), let m = MovementType(rawValue: v) { a.movement = m }
            case "--color":
                if let v = it.next(), let c = AccentColor(rawValue: v) { a.color = c }
            case "--size":
                if let v = it.next() {
                    let parts = v.lowercased().split(separator: "x")
                    if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                        a.size = CGSize(width: w, height: h)
                    }
                }
            default:
                if !arg.hasPrefix("--") { positional.append(arg) }
            }
        }
        if let first = positional.first { a.command = first }
        return a
    }

    var config: AnimationConfig {
        var rgb = color.rgb
        if light && rgb.0 > 0.9 && rgb.1 > 0.9 && rgb.2 > 0.9 { rgb = (0, 0, 0) }
        return AnimationConfig(accentR: rgb.0, accentG: rgb.1, accentB: rgb.2,
                               lightMode: light, movementType: movement)
    }
}

// MARK: - Bitmap helpers

func makeContext(size: CGSize, scale: CGFloat) -> CGContext? {
    let w = Int((size.width * scale).rounded())
    let h = Int((size.height * scale).rounded())
    guard let ctx = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                          CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    // Draw in points; the context is in pixels.
    ctx.scaleBy(x: scale, y: scale)
    return ctx
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { print("!! could not write \(path)"); return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// Raw BGRA bytes of a CGImage, in a known layout.
func rasterize(_ image: CGImage) -> (w: Int, h: Int, px: [UInt8])? {
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                          CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return nil }
    let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    return (w, h, Array(UnsafeBufferPointer(start: buf, count: w * h * 4)))
}

// MARK: - Diff

struct DiffStats {
    var width = 0, height = 0
    var maxChannelDelta = 0
    var meanAbsDelta = 0.0
    var pixelsOver8 = 0
    var pixelsOver32 = 0
    var pixelsOver128 = 0
    var litPixelsA = 0
    var litPixelsB = 0
    var inkA = 0.0
    var inkB = 0.0

    var totalPixels: Int { width * height }

    /// Fraction of pixels where the two renderers disagree by more than a
    /// just-noticeable amount.
    var fractionOver32: Double { totalPixels == 0 ? 0 : Double(pixelsOver32) / Double(totalPixels) }
    var inkRatio: Double { inkA == 0 ? 0 : inkB / inkA }
}

/// Compare two images and optionally build an amplified difference image.
func diff(_ a: CGImage, _ b: CGImage, makeImage: Bool) -> (DiffStats, CGImage?) {
    guard let ra = rasterize(a), let rb = rasterize(b),
          ra.w == rb.w, ra.h == rb.h else {
        print("!! size mismatch: \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
        return (DiffStats(), nil)
    }

    var s = DiffStats()
    s.width = ra.w; s.height = ra.h
    var sum = 0.0
    var diffPx = makeImage ? [UInt8](repeating: 0, count: ra.px.count) : []

    for i in stride(from: 0, to: ra.px.count, by: 4) {
        var worst = 0
        var sub = 0
        for c in 0..<3 {
            let d = abs(Int(ra.px[i + c]) - Int(rb.px[i + c]))
            if d > worst { worst = d }
            sub += d
        }
        sum += Double(sub) / 3.0
        if worst > s.maxChannelDelta { s.maxChannelDelta = worst }
        if worst > 8 { s.pixelsOver8 += 1 }
        if worst > 32 { s.pixelsOver32 += 1 }
        if worst > 128 { s.pixelsOver128 += 1 }

        let lumA = 0.299 * Double(ra.px[i+2]) + 0.587 * Double(ra.px[i+1]) + 0.114 * Double(ra.px[i])
        let lumB = 0.299 * Double(rb.px[i+2]) + 0.587 * Double(rb.px[i+1]) + 0.114 * Double(rb.px[i])
        s.inkA += lumA
        s.inkB += lumB
        if lumA > 8 { s.litPixelsA += 1 }
        if lumB > 8 { s.litPixelsB += 1 }

        if makeImage {
            // Amplify 4x so small disagreements are actually visible.
            let v = UInt8(min(255, worst * 4))
            diffPx[i] = v; diffPx[i+1] = v; diffPx[i+2] = v; diffPx[i+3] = 255
        }
    }
    s.meanAbsDelta = sum / Double(ra.w * ra.h)

    var image: CGImage? = nil
    if makeImage, let provider = CGDataProvider(data: Data(diffPx) as CFData) {
        image = CGImage(width: ra.w, height: ra.h, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: ra.w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue:
                            CGImageAlphaInfo.premultipliedFirst.rawValue |
                            CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false,
                        intent: .defaultIntent)
    }
    return (s, image)
}

// MARK: - Rendering both paths

final class DualRenderer {
    let sim: IsometricSimulation
    let params: IsometricRenderParams
    let cg = IsometricCGRenderer()
    let metal: IsometricMetalRenderer?
    var frame = IsometricFrame()

    init(args: Args) {
        sim = IsometricSimulation(config: args.config, size: args.size)
        params = IsometricRenderParams(size: args.size, scale: args.scale, config: args.config)
        metal = IsometricMetalRenderer()
        sim.start(now: 0)
    }

    /// Advance the simulation by one frame at its native rate.
    func advance(to index: Int) {
        sim.tick(now: Double(index) / sim.preferredFPS)
        sim.fill(frame: &frame)
    }

    func renderCG() -> CGImage? {
        guard let ctx = makeContext(size: params.size, scale: params.scale) else { return nil }
        cg.setGeometry(sim.edgeEndpoints, generation: frame.generation)
        cg.draw(frame: frame, params: params, in: ctx)
        return ctx.makeImage()
    }

    /// Draw into one long-lived context, which is what the view actually does:
    /// it draws into the window's backing store, not a fresh buffer each frame.
    /// Allocating a new context per frame charges the background fill for
    /// faulting in ~30MB of cold pages and roughly triples the measurement.
    private lazy var benchContext: CGContext? = makeContext(size: params.size, scale: params.scale)

    func drawCGForBench() {
        guard let ctx = benchContext else { return }
        cg.setGeometry(sim.edgeEndpoints, generation: frame.generation)
        cg.draw(frame: frame, params: params, in: ctx)
    }

    func encodeMetal() {
        guard let metal else { return }
        metal.setGeometry(sim.edgeEndpoints, generation: frame.generation)
        metal.encodeOnlyForBenchmark(frame: frame, params: params)
    }

    func renderMetal() -> CGImage? {
        guard let metal else { return nil }
        metal.setGeometry(sim.edgeEndpoints, generation: frame.generation)
        return metal.renderOffscreen(frame: frame, params: params)
    }
}

// MARK: - Commands

func runCompare(_ args: Args) -> Int32 {
    let dual = DualRenderer(args: args)
    guard dual.metal != nil else { print("!! no Metal device"); return 2 }

    print("compare: \(Int(args.size.width))x\(Int(args.size.height)) @\(args.scale)x  " +
          "movement=\(args.movement.rawValue) color=\(args.color.rawValue) " +
          "light=\(args.light) frames=\(args.frames)")
    print("edges: \(dual.sim.totalEdgeCount)")
    print("")
    print(String(format: "%6s %8s %8s %9s %9s %9s %9s %8s",
                 ("frame" as NSString).utf8String!, ("insts" as NSString).utf8String!,
                 ("maxΔ" as NSString).utf8String!, ("meanΔ" as NSString).utf8String!,
                 (">8" as NSString).utf8String!, (">32" as NSString).utf8String!,
                 (">128" as NSString).utf8String!, ("ink" as NSString).utf8String!))

    var worst = DiffStats()
    var worstFrame = -1
    var totalMean = 0.0
    var totalOver32 = 0
    var totalPixels = 0
    var maxOver128Fraction = 0.0

    for i in 0..<args.frames {
        dual.advance(to: i)
        guard let a = dual.renderCG(), let b = dual.renderMetal() else {
            print("!! render failed at frame \(i)"); return 2
        }
        let keep = (i % max(args.frames / 8, 1) == 0) || i == args.frames - 1
        let (s, _) = diff(a, b, makeImage: false)
        totalMean += s.meanAbsDelta
        totalOver32 += s.pixelsOver32
        totalPixels += s.totalPixels
        maxOver128Fraction = max(maxOver128Fraction,
                                 Double(s.pixelsOver128) / Double(max(s.totalPixels, 1)))

        if s.meanAbsDelta > worst.meanAbsDelta { worst = s; worstFrame = i }

        if keep {
            print(String(format: "%6d %8d %8d %9.4f %9d %9d %9d %8.4f",
                         i, dual.frame.instances.count, s.maxChannelDelta, s.meanAbsDelta,
                         s.pixelsOver8, s.pixelsOver32, s.pixelsOver128, s.inkRatio))
        }
    }

    // Re-render the worst frame and dump images for eyeballing.
    let dual2 = DualRenderer(args: args)
    for i in 0...max(worstFrame, 0) { dual2.advance(to: i) }
    if let a = dual2.renderCG(), let b = dual2.renderMetal() {
        let (ws, d) = diff(a, b, makeImage: true)
        print(String(format: "worst frame lit pixels: cpu=%d gpu=%d   ink: cpu=%.0f gpu=%.0f",
                     ws.litPixelsA, ws.litPixelsB, ws.inkA, ws.inkB))
        let za = cropZoom(a, crop: args.crop, scale: args.scale, zoom: args.zoom) ?? a
        let zb = cropZoom(b, crop: args.crop, scale: args.scale, zoom: args.zoom) ?? b
        let zd = d.flatMap { cropZoom($0, crop: args.crop, scale: args.scale, zoom: args.zoom) }
        writePNG(za, to: "\(args.out)/worst-cpu.png")
        writePNG(zb, to: "\(args.out)/worst-metal.png")
        if let zd { writePNG(zd, to: "\(args.out)/worst-diff.png") }
        if let sbs = sideBySide([za, zb], labels: ["CPU (CoreGraphics)", "GPU (Metal)"]) {
            writePNG(sbs, to: "\(args.out)/worst-sidebyside.png")
        }
    }

    let meanAvg = totalMean / Double(args.frames)
    let over32Frac = Double(totalOver32) / Double(max(totalPixels, 1))
    print("")
    print(String(format: "worst frame: %d   mean |Δ| avg over run: %.4f/255", worstFrame, meanAvg))
    print(String(format: "pixels disagreeing by >32/255: %.5f%% of all pixels", over32Frac * 100))
    print(String(format: "worst frame's >128/255 disagreement: %.5f%% of pixels", maxOver128Fraction * 100))
    print("images: \(args.out)/worst-{cpu,metal,diff,sidebyside}.png")

    // A structural mismatch (wrong geometry, flipped axis, missing segments)
    // shows up as a large fraction of hard disagreements. Anti-aliasing
    // differences show up as a tiny mean with almost nothing over 128.
    let structural = maxOver128Fraction > 0.002 || over32Frac > 0.01
    print("")
    print(structural ? "VERDICT: STRUCTURAL MISMATCH — renderers disagree beyond anti-aliasing"
                     : "VERDICT: MATCH — differences are anti-aliasing only")
    return structural ? 1 : 0
}

/// Lay images out left-to-right with captions.
func sideBySide(_ images: [CGImage], labels: [String]) -> CGImage? {
    guard !images.isEmpty else { return nil }
    let pad = 8, labelH = 28
    let w = images.reduce(0) { $0 + $1.width } + pad * (images.count + 1)
    let h = (images.map { $0.height }.max() ?? 0) + labelH + pad * 2
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                          CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    var x = pad
    for (i, img) in images.enumerated() {
        ctx.draw(img, in: CGRect(x: x, y: pad + labelH, width: img.width, height: img.height))
        if i < labels.count {
            drawLabel(labels[i], at: CGPoint(x: CGFloat(x) + 4, y: CGFloat(pad + 6)), in: ctx)
        }
        x += img.width + pad
    }
    return ctx.makeImage()
}

func drawLabel(_ text: String, at point: CGPoint, in ctx: CGContext) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    ctx.saveGState()
    ctx.textPosition = point
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func runSheet(_ args: Args) -> Int32 {
    let dual = DualRenderer(args: args)
    let useMetal = dual.metal != nil
    print("sheet: sampling every \(args.sheetEvery) frames up to \(args.frames), " +
          "renderer=\(useMetal ? "Metal" : "CoreGraphics")")

    var tiles: [CGImage] = []
    var labels: [String] = []
    for i in 0..<args.frames {
        dual.advance(to: i)
        guard i % args.sheetEvery == 0 else { continue }
        let img = useMetal ? dual.renderMetal() : dual.renderCG()
        guard let img else { continue }
        tiles.append(downscale(img, factor: 3) ?? img)
        labels.append(String(format: "t=%.1fs  %d lit", Double(i) / dual.sim.preferredFPS,
                             dual.sim.litEdgeCount))
    }
    guard let sheet = grid(tiles, labels: labels, columns: args.sheetColumns) else {
        print("!! could not build sheet"); return 2
    }
    let path = "\(args.out)/sheet-\(args.movement.rawValue).png"
    writePNG(sheet, to: path)
    print("wrote \(path)  (\(tiles.count) frames)")
    return 0
}

/// Crop (in points) then magnify with nearest-neighbour so individual pixels
/// are visible when the image is looked at.
func cropZoom(_ image: CGImage, crop: CGRect?, scale: CGFloat, zoom: Int) -> CGImage? {
    var img = image
    if let crop {
        // Crop is given in points with a bottom-left origin; CGImage.cropping
        // wants pixels with a top-left origin.
        let px = CGRect(x: crop.minX * scale,
                        y: CGFloat(image.height) - (crop.minY + crop.height) * scale,
                        width: crop.width * scale, height: crop.height * scale)
        guard let c = image.cropping(to: px.integral) else { return nil }
        img = c
    }
    guard zoom > 1 else { return img }
    let w = img.width * zoom, h = img.height * zoom
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                          CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

func downscale(_ image: CGImage, factor: Int) -> CGImage? {
    let w = image.width / factor, h = image.height / factor
    guard w > 0, h > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                          CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

func grid(_ images: [CGImage], labels: [String], columns: Int) -> CGImage? {
    guard !images.isEmpty else { return nil }
    let cols = max(1, columns)
    let rows = (images.count + cols - 1) / cols
    let tw = images[0].width, th = images[0].height
    let pad = 6, labelH = 20
    let w = cols * tw + pad * (cols + 1)
    let h = rows * (th + labelH) + pad * (rows + 1)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                          CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    for (i, img) in images.enumerated() {
        let col = i % cols
        let row = i / cols
        let x = pad + col * (tw + pad)
        // Rows top-to-bottom in a y-up context.
        let y = h - pad - (row + 1) * (th + labelH) - row * pad
        ctx.draw(img, in: CGRect(x: x, y: y + labelH, width: tw, height: th))
        if i < labels.count {
            drawLabel(labels[i], at: CGPoint(x: CGFloat(x) + 2, y: CGFloat(y) + 4), in: ctx)
        }
    }
    return ctx.makeImage()
}

func runBench(_ args: Args) -> Int32 {
    let dual = DualRenderer(args: args)
    guard dual.metal != nil else { print("!! no Metal device"); return 2 }
    print("bench: \(Int(args.size.width))x\(Int(args.size.height)) @\(args.scale)x  " +
          "movement=\(args.movement.rawValue) frames=\(args.frames)")
    print("edges: \(dual.sim.totalEdgeCount)")

    // Warm both paths.
    for i in 0..<20 { dual.advance(to: i); dual.drawCGForBench(); dual.encodeMetal() }

    var simTime = 0.0, cgTime = 0.0, mtlTime = 0.0, encTime = 0.0
    var instTotal = 0
    for i in 20..<(20 + args.frames) {
        var t = CACurrentMediaTime()
        dual.advance(to: i)
        simTime += CACurrentMediaTime() - t
        instTotal += dual.frame.instances.count

        t = CACurrentMediaTime()
        dual.drawCGForBench()
        cgTime += CACurrentMediaTime() - t

        t = CACurrentMediaTime()
        _ = dual.renderMetal()
        mtlTime += CACurrentMediaTime() - t

        t = CACurrentMediaTime()
        dual.encodeMetal()
        encTime += CACurrentMediaTime() - t
    }
    let n = Double(args.frames)
    print("")
    print(String(format: "simulation      %7.3f ms/frame", simTime / n * 1000))
    print(String(format: "CoreGraphics    %7.3f ms/frame  (draw only)", cgTime / n * 1000))
    print(String(format: "Metal encode    %7.3f ms/frame  (what the live path costs the CPU)",
                 encTime / n * 1000))
    print(String(format: "Metal + readback%7.3f ms/frame  (verification path only: stall + copy)",
                 mtlTime / n * 1000))
    print(String(format: "avg segments    %7.0f per frame", Double(instTotal) / n))
    print("")
    print(String(format: "CPU time per frame: %.3f ms before  ->  %.3f ms after  (%.1fx less)",
                 (simTime + cgTime) / n * 1000,
                 (simTime + encTime) / n * 1000,
                 (simTime + cgTime) / max(simTime + encTime, 1e-9)))
    return 0
}

// MARK: - Profile diagnostic

/// Render a handful of isolated segments at known angles through both
/// renderers and print the pixel cross-section of each. This is how a
/// systematic width/brightness difference gets located instead of guessed at.
func runProfile(_ args: Args) -> Int32 {
    guard let metal = IsometricMetalRenderer() else { print("!! no Metal device"); return 2 }
    let size = CGSize(width: 60, height: 40)
    let scale = args.scale
    var params = IsometricRenderParams(size: size, scale: scale, config: args.config)
    params.lineWidth = 1.2

    // One horizontal edge across the middle, drawn full length.
    let endpoints: [SIMD4<Float>] = [
        SIMD4<Float>(6, 20, 54, 20),          // horizontal
        SIMD4<Float>(6, 6, 54, 34),           // shallow diagonal
    ]
    let cg = IsometricCGRenderer()
    cg.setGeometry(endpoints, generation: 1)
    metal.setGeometry(endpoints, generation: 1)

    for (name, inst) in [
        ("horizontal lit=1.0", IsometricInstance(edge: 0, lit: 1.0, t0: 0, t1: 1)),
        ("horizontal lit=0.5", IsometricInstance(edge: 0, lit: 0.5, t0: 0, t1: 1)),
        ("diagonal   lit=1.0", IsometricInstance(edge: 1, lit: 1.0, t0: 0, t1: 1)),
    ] {
        var f = IsometricFrame()
        f.generation = 1
        f.instances = [inst]

        guard let ctx = makeContext(size: size, scale: scale) else { return 2 }
        cg.draw(frame: f, params: params, in: ctx)
        guard let aImg = ctx.makeImage(), let bImg = metal.renderOffscreen(frame: f, params: params),
              let a = rasterize(aImg), let b = rasterize(bImg) else { return 2 }

        // Cross-section down the middle column.
        let col = a.w / 2
        print("--- \(name)  (blue channel down column \(col), \(a.w)x\(a.h)px) ---")
        var rowsA: [String] = [], rowsB: [String] = []
        var sumA = 0, sumB = 0
        for row in 0..<a.h {
            let i = (row * a.w + col) * 4
            let va = Int(a.px[i]), vb = Int(b.px[i])   // BGRA -> blue is byte 0
            sumA += va; sumB += vb
            if va > 0 || vb > 0 {
                rowsA.append("row \(row): cpu=\(va) gpu=\(vb)")
            }
        }
        for r in rowsA { print("  " + r) }
        _ = rowsB
        print("  column total: cpu=\(sumA) gpu=\(sumB)  ratio=\(String(format: "%.4f", Double(sumB)/Double(max(sumA,1))))")

        // Whole-image ink.
        var inkA = 0, inkB = 0
        for i in stride(from: 0, to: a.px.count, by: 4) { inkA += Int(a.px[i]); inkB += Int(b.px[i]) }
        print("  image total:  cpu=\(inkA) gpu=\(inkB)  ratio=\(String(format: "%.4f", Double(inkB)/Double(max(inkA,1))))")
        print("")
    }
    return 0
}

// MARK: - Live window

/// Open a real window backed by the real `IsometricModule` and screenshot it.
///
/// The offscreen compare path exercises the shader but NOT the on-screen path:
/// the CAMetalLayer backing layer, drawableSize, contentsScale and drawable
/// presentation. Those only fail in a window, so they get checked in a window.
func runWindow(_ args: Args) -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let rect = NSRect(origin: .zero, size: args.size)
    let window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
    window.title = "isoharness live — \(args.movement.rawValue)"

    var cfg = args.config
    cfg.showFPS = true
    let view = IsometricModule(frame: rect, config: cfg)
    view.autoresizingMask = [.width, .height]
    window.contentView = view
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    view.startAnimation()

    print("live window: \(Int(args.size.width))x\(Int(args.size.height)) " +
          "movement=\(args.movement.rawValue) color=\(args.color.rawValue)")
    print("backing layer: \(type(of: window.contentView!.layer!))")
    print("renderer: \(view.isUsingMetal ? "Metal (GPU)" : "CoreGraphics (CPU)")")

    let outPath = "\(args.out)/live-\(args.movement.rawValue).png"
    try? FileManager.default.createDirectory(atPath: args.out, withIntermediateDirectories: true)

    Timer.scheduledTimer(withTimeInterval: args.seconds, repeats: false) { _ in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-o", "-l\(window.windowNumber)", outPath]
        try? proc.run()
        proc.waitUntilExit()
        print("captured after \(args.seconds)s -> \(outPath)")
        view.stopAnimation()
        app.terminate(nil)
    }
    app.run()
    return 0
}

// MARK: - Entry

let args = Args.parse()
let status: Int32
switch args.command {
case "compare": status = runCompare(args)
case "sheet":   status = runSheet(args)
case "bench":   status = runBench(args)
case "profile": status = runProfile(args)
case "window":  status = runWindow(args)
default:
    print("unknown command '\(args.command)'. use: compare | sheet | bench | profile | window")
    status = 64
}
exit(status)
