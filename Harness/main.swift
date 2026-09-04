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
    var seed: UInt64? = nil
    /// Crop rect in points, applied to the images written out by `compare`.
    var crop: CGRect? = nil
    /// Nearest-neighbour magnification for written images.
    var zoom = 1
    /// In `window` mode, press a key to play the unlock flourish.
    var flourishKey = false
    /// Global alpha multiplier, so the renderers can be diffed with it set.
    var opacity: CGFloat = 1.0

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
            case "--flourish-key": a.flourishKey = true
            case "--opacity":  a.opacity = CGFloat(Double(it.next() ?? "") ?? 1.0)
            case "--seconds":  a.seconds = Double(it.next() ?? "") ?? a.seconds
            case "--seed":     a.seed = UInt64(it.next() ?? "")
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
                               lightMode: light, movementType: movement,
                               showFPS: false, seed: seed)
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
    guard let ra = rasterize(a), let rb = rasterize(b) else {
        print("!! could not rasterise a rendered frame")
        exit(2)
    }
    guard ra.w == rb.w, ra.h == rb.h else {
        print("!! size mismatch: \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
        print("   That is a structural failure, not a tolerance question.")
        exit(2)
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
        var p = IsometricRenderParams(size: args.size, scale: args.scale, config: args.config)
        p.opacity = args.opacity
        params = p
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
                 ("maxD" as NSString).utf8String!, ("meanD" as NSString).utf8String!,
                 (">8" as NSString).utf8String!, (">32" as NSString).utf8String!,
                 (">128" as NSString).utf8String!, ("ink" as NSString).utf8String!))

    var worstMean = -1.0
    var worstFrame = -1
    var worstPair: (CGImage, CGImage)? = nil
    var totalMean = 0.0

    // Per-frame maxima. Averaging a disagreement across the whole run buries a
    // single catastrophic frame under a hundred clean ones.
    var maxOver32Fraction = 0.0
    var maxOver128Fraction = 0.0
    var maxChannelDelta = 0

    // Liveness. Two renderers agreeing on an empty screen is not a pass.
    var framesWithInstances = 0
    var litFractionSum = 0.0
    var peakLitFraction = 0.0
    var emptyInstanceFrames: [Int] = []

    for i in 0..<args.frames {
        dual.advance(to: i)
        guard let a = dual.renderCG(), let b = dual.renderMetal() else {
            print("!! render failed at frame \(i)"); return 2
        }
        let (s, _) = diff(a, b, makeImage: false)
        let px = Double(max(s.totalPixels, 1))

        totalMean += s.meanAbsDelta
        maxOver32Fraction = max(maxOver32Fraction, Double(s.pixelsOver32) / px)
        maxOver128Fraction = max(maxOver128Fraction, Double(s.pixelsOver128) / px)
        maxChannelDelta = max(maxChannelDelta, s.maxChannelDelta)

        if dual.frame.instances.isEmpty { emptyInstanceFrames.append(i) } else { framesWithInstances += 1 }
        let litFraction = Double(s.litPixelsA) / px
        litFractionSum += litFraction
        peakLitFraction = max(peakLitFraction, litFraction)

        if s.meanAbsDelta > worstMean {
            worstMean = s.meanAbsDelta
            worstFrame = i
            // Keep the images from THIS pass. Re-running the simulation to
            // reach the worst frame draws fresh random numbers and produces a
            // different frame, so the saved picture would not be the failure.
            worstPair = (a, b)
        }

        if (i % max(args.frames / 8, 1) == 0) || i == args.frames - 1 {
            print(String(format: "%6d %8d %8d %9.4f %9d %9d %9d %8.4f",
                         i, dual.frame.instances.count, s.maxChannelDelta, s.meanAbsDelta,
                         s.pixelsOver8, s.pixelsOver32, s.pixelsOver128, s.inkRatio))
        }
    }

    if let (a, b) = worstPair {
        let (_, d) = diff(a, b, makeImage: true)
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
    let meanLitFraction = litFractionSum / Double(args.frames)
    let instanceCoverage = Double(framesWithInstances) / Double(args.frames)

    print("")
    print(String(format: "worst frame: %d   mean |D| avg over run: %.4f/255", worstFrame, meanAvg))
    print(String(format: "max channel delta, any frame:        %d/255", maxChannelDelta))
    print(String(format: "worst frame's >32/255 disagreement:  %.5f%% of pixels", maxOver32Fraction * 100))
    print(String(format: "worst frame's >128/255 disagreement: %.5f%% of pixels", maxOver128Fraction * 100))
    print(String(format: "mean lit pixels (CPU reference):     %.4f%% of the frame", meanLitFraction * 100))
    print(String(format: "peak lit pixels (CPU reference):     %.4f%% of the frame", peakLitFraction * 100))
    print(String(format: "frames that drew anything:           %.0f%%", instanceCoverage * 100))
    print("images: \(args.out)/worst-{cpu,metal,diff,sidebyside}.png")
    print("")

    // Explicit checks, each reported. A pass has to mean "the renderers agree
    // AND there was something to agree about".
    struct Check { let name: String; let ok: Bool; let detail: String }
    var checks: [Check] = []

    checks.append(Check(name: "renderers agree structurally",
                        ok: maxOver128Fraction <= 0.002,
                        detail: String(format: "worst frame %.5f%% of pixels differ by >128 (limit 0.2%%)",
                                       maxOver128Fraction * 100)))
    checks.append(Check(name: "renderers agree beyond anti-aliasing",
                        ok: maxOver32Fraction <= 0.01,
                        detail: String(format: "worst frame %.5f%% of pixels differ by >32 (limit 1%%)",
                                       maxOver32Fraction * 100)))
    // Liveness floors. Without these an all-black render passes trivially:
    // two renderers that both draw nothing agree perfectly.
    // Peak, not mean. A wave sweep legitimately starts almost empty and takes
    // seconds to cross the screen, so a short run has a low mean while being
    // perfectly healthy. What distinguishes a dead render is that it never
    // draws anything at all.
    checks.append(Check(name: "something was actually drawn",
                        ok: peakLitFraction >= 0.0005 && meanLitFraction > 0,
                        detail: String(format: "peak lit %.4f%% (floor 0.05%%), mean %.4f%%",
                                       peakLitFraction * 100, meanLitFraction * 100)))
    checks.append(Check(name: "the animation produced segments",
                        ok: instanceCoverage >= 0.75,
                        detail: emptyInstanceFrames.isEmpty
                            ? String(format: "%.0f%% of frames drew segments", instanceCoverage * 100)
                            : String(format: "%.0f%% of frames drew segments; %d empty (first: %d)",
                                     instanceCoverage * 100, emptyInstanceFrames.count,
                                     emptyInstanceFrames.first!)))
    checks.append(Check(name: "the grid is not degenerate",
                        ok: dual.sim.totalEdgeCount > 100,
                        detail: "\(dual.sim.totalEdgeCount) edges generated (floor 100)"))

    for c in checks {
        print("  [\(c.ok ? "PASS" : "FAIL")] \(c.name) — \(c.detail)")
    }
    let failed = checks.filter { !$0.ok }
    print("")
    if failed.isEmpty {
        print("VERDICT: MATCH — differences are anti-aliasing only")
        return 0
    }
    print("VERDICT: FAIL — \(failed.map { $0.name }.joined(separator: "; "))")
    return 1
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

    var keyMonitor: Any?
    if args.flourishKey {
        print("press any key to play the unlock flourish over your desktop")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in
            view.beginUnlockFlourish()
            return nil
        }
    }
    _ = keyMonitor

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

// MARK: - Frame hashing (simulation regression detection)

/// The renderer comparison cannot see a simulation regression: it feeds the
/// SAME frame data to both renderers, so a broken simulation makes both agree
/// on wrong output. This hashes the simulation's own output instead.
func runHash(_ args: Args) -> Int32 {
    guard args.seed != nil else {
        print("!! hash requires --seed N, otherwise the run is not reproducible")
        return 64
    }
    let sim = IsometricSimulation(config: args.config, size: args.size)
    var frame = IsometricFrame()
    sim.start(now: 0)

    // FNV-1a over the instance stream, with the floats quantised so that
    // harmless last-bit differences do not produce spurious mismatches.
    var h: UInt64 = 0xcbf29ce484222325
    @inline(__always) func mix(_ v: UInt64) {
        var x = v
        for _ in 0..<8 {
            h = (h ^ (x & 0xff)) &* 0x100000001b3
            x >>= 8
        }
    }
    @inline(__always) func mixF(_ f: Float) {
        mix(UInt64(UInt32(bitPattern: Int32((f * 65536.0).rounded()))))
    }

    var perFrame: [String] = []
    for i in 0..<args.frames {
        sim.tick(now: Double(i) / sim.preferredFPS)
        sim.fill(frame: &frame)
        mix(UInt64(frame.instances.count))
        for inst in frame.instances {
            mix(UInt64(inst.edge)); mixF(inst.lit); mixF(inst.t0); mixF(inst.t1)
        }
        if i % max(args.frames / 10, 1) == 0 {
            perFrame.append(String(format: "  frame %4d  insts %6d  lit %6d  h=%016llx",
                                   i, frame.instances.count, sim.litEdgeCount, h))
        }
    }
    print("hash: movement=\(args.movement.rawValue) seed=\(args.seed!) " +
          "size=\(Int(args.size.width))x\(Int(args.size.height)) frames=\(args.frames)")
    print("edges: \(sim.totalEdgeCount)")
    for l in perFrame { print(l) }
    print(String(format: "DIGEST %016llx", h))
    return 0
}

// MARK: - Core Graphics fallback

/// Drive the real IsometricModule with Metal disabled, so the fallback path
/// that Macs without a GPU actually use gets exercised. Nothing else reaches
/// it: `compare` calls IsometricCGRenderer directly, not through the view.
func runFallback(_ args: Args) -> Int32 {
    setenv("BLACKOUT_DISABLE_METAL", "1", 1)
    let rect = NSRect(origin: .zero, size: args.size)
    let view = IsometricModule(frame: rect, config: args.config)
    guard !view.isUsingMetal else {
        print("FAIL: BLACKOUT_DISABLE_METAL did not disable the GPU path")
        return 1
    }
    // externalTick reads the wall clock, so ticking flat out advances the
    // simulation by almost nothing. Pace it so there is a real frame to draw.
    for _ in 0..<args.frames {
        view.externalTick()
        Thread.sleep(forTimeInterval: 1.0 / 120.0)
    }

    guard let ctx = makeContext(size: args.size, scale: args.scale) else { return 2 }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    view.draw(rect)
    NSGraphicsContext.restoreGraphicsState()

    guard let img = ctx.makeImage(), let r = rasterize(img) else {
        print("FAIL: fallback produced no image"); return 1
    }
    var lit = 0
    for i in stride(from: 0, to: r.px.count, by: 4) {
        let lum = 0.299 * Double(r.px[i+2]) + 0.587 * Double(r.px[i+1]) + 0.114 * Double(r.px[i])
        if lum > 8 { lit += 1 }
    }
    let frac = Double(lit) / Double(r.w * r.h)
    print(String(format: "fallback renderer: %@  lit %.4f%% of the frame after %d frames",
                 view.isUsingMetal ? "Metal" : "CoreGraphics", frac * 100, args.frames))
    if frac < 0.0002 {
        print("FAIL: the Core Graphics fallback drew essentially nothing")
        return 1
    }
    print("PASS: the Core Graphics fallback renders")
    return 0
}

// MARK: - Single frame

/// Render exactly one frame at full resolution, with the usual crop/zoom, for
/// looking closely at something specific.
func runFrame(_ args: Args) -> Int32 {
    let dual = DualRenderer(args: args)
    for i in 0...max(args.frames, 0) { dual.advance(to: i) }
    guard let img = dual.renderMetal() ?? dual.renderCG() else { return 2 }
    let z = cropZoom(img, crop: args.crop, scale: args.scale, zoom: args.zoom) ?? img
    let name = "\(args.out)/frame-\(args.movement.rawValue)-\(args.frames).png"
    writePNG(z, to: name)
    print("wrote \(name)  (\(dual.frame.instances.count) segments)")
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
case "hash":    status = runHash(args)
case "fallback": status = runFallback(args)
case "frame":   status = runFrame(args)
default:
    print("unknown command '\(args.command)'. use: compare | sheet | bench | profile | window | hash | fallback")
    status = 64
}
exit(status)
