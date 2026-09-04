import Foundation
import CoreGraphics
import QuartzCore

// MARK: - Isometric Grid & Graph

struct GridNode: Hashable {
    let q: Int  // iso-axis (affects both x and y)
    let r: Int  // vertical axis (affects y only in screen space)
}

struct GridEdge: Hashable {
    let a: GridNode
    let b: GridNode

    init(_ n1: GridNode, _ n2: GridNode) {
        if n1.q < n2.q || (n1.q == n2.q && n1.r < n2.r) {
            a = n1; b = n2
        } else {
            a = n2; b = n1
        }
    }
}

// MARK: - Render Frame

/// One lit segment to draw. `edge` indexes into `IsometricSimulation.edgeEndpoints`.
/// `t0`/`t1` are fractions along A→B (a full edge is 0...1; a walker that entered
/// from A with progress p is 0...p, from B it is (1-p)...1).
/// Layout matches the `Instance` struct in the Metal shader — do not reorder.
struct IsometricInstance {
    var edge: UInt32
    var lit: Float
    var t0: Float
    var t1: Float
}

/// Everything a renderer needs for one frame.
struct IsometricFrame {
    var instances: [IsometricInstance] = []
    /// Bumped whenever `edgeEndpoints` is rebuilt, so renderers know to re-upload.
    var generation: Int = 0
}

// MARK: - Canonical ordering

/// Swift seeds its hasher per process, so iterating a Set or Dictionary gives a
/// different order on every run. That order leaks into the output here: it fixes
/// edge indices, the order of adjacency lists (and therefore which edge
/// randomElement picks), and the order segments are drawn in. Everything that
/// feeds the animation is therefore sorted into this canonical order first.
@inline(__always)
func isometricEdgeOrder(_ x: GridEdge, _ y: GridEdge) -> Bool {
    if x.a.q != y.a.q { return x.a.q < y.a.q }
    if x.a.r != y.a.r { return x.a.r < y.a.r }
    if x.b.q != y.b.q { return x.b.q < y.b.q }
    return x.b.r < y.b.r
}

// MARK: - Simulation

/// Pure simulation of the isometric grid animation. No AppKit, no drawing.
/// Feed it a size and a clock; read back `edgeEndpoints` (static per generation)
/// and `fill(frame:)` (per tick).
final class IsometricSimulation {

    // MARK: Configuration

    private let gridSpacing: CGFloat = 32.0

    let accentR: CGFloat
    let accentG: CGFloat
    let accentB: CGFloat
    let lightMode: Bool
    let movementType: MovementType

    /// Requested frame rate for the host timer.
    ///
    /// 30fps is exactly 4 refresh periods at 120Hz. 24fps is exactly 5, and is
    /// also the slowest rate a ProMotion panel can hold: its maximum refresh
    /// interval is 41.7ms, so the old 20fps asked for a 50ms hold the display
    /// physically could not give, and the cadence was uneven no matter how
    /// precise the timer was.
    var preferredFPS: Double {
        switch movementType {
        case .walkers, .random, .waveField: return 30.0
        default:                            return 24.0
        }
    }

    // Wave state
    private var wavePosition: CGFloat = 0.0
    private var waveDirection: CGPoint = .zero
    private var waveMaxDist: CGFloat = 0.0
    private let waveSpeed: CGFloat = 55.0
    private let waveBandWidth: CGFloat = 60.0

    // Ripple state — supports multiple concurrent ripples
    private struct Ripple {
        var center: CGPoint
        var radius: CGFloat
        var maxRadius: CGFloat
        /// Edges bucketed by distance from this ripple's centre, built once at
        /// spawn so each frame only visits the annulus the ring is crossing.
        var buckets = BucketIndex()
    }
    private var ripples: [Ripple] = []
    private var rippleSpawnTimer: CGFloat = 0.0
    private let rippleSpeed: CGFloat = 55.0
    private let rippleBandWidth: CGFloat = 64.0
    private let rippleSpawnInterval: CGFloat = 2.2

    // MARK: Size

    private(set) var size: CGSize = .zero
    private var midX: CGFloat { size.width / 2 }
    private var midY: CGFloat { size.height / 2 }

    func setSize(_ newSize: CGSize) {
        guard newSize != size else { return }
        size = newSize
        needsGeneration = true
    }

    // MARK: Grid State

    private var activeEdges: Set<GridEdge> = []
    private var logoEdges: Set<GridEdge> = []
    /// Sorted, for order-stable random selection.
    private var logoEdgeArray: [GridEdge] = []
    private var centerLogoEdges: [GridEdge] = []
    /// Only edges with lit > 0 — avoids iterating all 17k+ edges every frame for fading
    /// Pre-cached screen positions for each edge endpoints
    private var edgeScreenPos: [GridEdge: (CGPoint, CGPoint)] = [:]
    /// Pre-cached midpoints for wave/ripple (avoids recalc every frame)
    private var edgeMidpoints: [(GridEdge, CGFloat, CGFloat)] = []  // (edge, midX, midY)
    /// Cached array of all edges for random respawn. Index == render edge index.
    private var activeEdgeArray: [GridEdge] = []
    /// Edge → index into `activeEdgeArray` / `edgeEndpoints`
    private var edgeIndex: [GridEdge: Int] = [:]
    /// Maps each logo edge to its logo index (0=center, 1=left, etc.)
    private var edgeToLogoIndex: [GridEdge: Int] = [:]
    /// Edges per logo
    private var perLogoEdges: [[GridEdge]] = []
    /// Timestamp when each logo was fully lit (for delayed fade in walker mode)
    private var logoCompletedAt: [Int: CFTimeInterval] = [:]
    /// Logos that have been fully completed at least once — walkers won't revisit
    private var logoEverCompleted: Set<Int> = []
    private var cachedPositions: [GridNode: CGPoint] = [:]

    // Adjacency for fast wavefront traversal
    private var adjacency: [GridNode: [GridEdge]] = [:]

    /// Static geometry for renderers: (ax, ay, bx, by) in view points, y-up.
    private(set) var edgeEndpoints: [SIMD4<Float>] = []
    /// Per-edge vignette multiplier, 1.0 at the centre falling to ~0.55 at the
    /// corners. The generated grid is inset and ends in a hard rectangular
    /// edge; this softens that and pulls attention off the periphery. It lives
    /// here, not in a shader, so both renderers apply it identically and the
    /// pixel comparison stays meaningful. Constant per edge is enough: an edge
    /// spans at most one grid step, over which the falloff changes by <0.03.
    private(set) var edgeVignette: [Float] = []

    // MARK: Index-parallel state
    //
    // These replace hashing a 32-byte GridEdge several times per lit edge per
    // frame. Every array below is indexed by an edge's position in
    // activeEdgeArray, which is canonically sorted and stable for a generation.

    /// Brightness per edge, 0...1.
    private var edgeLit: [CGFloat] = []
    /// Which logo an edge belongs to, or -1.
    private var edgeLogoIndex: [Int32] = []
    /// True if the edge is part of any logo.
    private var edgeIsLogo: [Bool] = []
    /// Midpoints, split apart so the wave and ripple scans stream two tight
    /// Float arrays instead of an array of 48-byte tuples.
    private var edgeMidX: [CGFloat] = []
    private var edgeMidY: [CGFloat] = []
    /// Dense list of lit edge indices, with a back-pointer for O(1) removal.
    private var litList: [Int32] = []
    private var litSlot: [Int32] = []
    /// Walker occupying an edge, or -1.
    private var edgeWalker: [Int32] = []
    /// Endpoint node indices, for deciding which end a walker entered from.
    private var edgeNodeA: [GridNode] = []
    private var edgeNodeB: [GridNode] = []
    /// Per-logo edge indices.
    private var perLogoEdgeIdx: [[Int32]] = []

    /// Edge indices sorted into fixed-width buckets by some scalar key, so a
    /// narrow band can be found without scanning every edge. Built once when
    /// the key changes (a wave direction change, a ripple spawn) and reused
    /// every frame after.
    private struct BucketIndex {
        var start: [Int32] = []     // bucket i occupies edges[start[i]..<start[i+1]]
        var edges: [Int32] = []
        var minKey: CGFloat = 0
        var width: CGFloat = 1

        var bucketCount: Int { max(start.count - 1, 0) }

        /// Buckets covering [lo, hi], clamped. Returns an empty range if the
        /// span misses the index entirely.
        func range(lo: CGFloat, hi: CGFloat) -> Range<Int> {
            guard bucketCount > 0, hi >= lo else { return 0..<0 }
            let a = Int(((lo - minKey) / width).rounded(.down))
            let b = Int(((hi - minKey) / width).rounded(.down))
            if b < 0 || a >= bucketCount { return 0..<0 }
            return max(a, 0)..<min(b + 1, bucketCount)
        }

        /// Counting-sort `keys` (one per edge) into buckets of `width`.
        static func build(keys: [CGFloat], width: CGFloat) -> BucketIndex {
            var idx = BucketIndex()
            guard !keys.isEmpty, width > 0 else { return idx }
            var lo = keys[0], hi = keys[0]
            for k in keys { if k < lo { lo = k }; if k > hi { hi = k } }
            let count = max(Int(((hi - lo) / width).rounded(.down)) + 1, 1)
            idx.minKey = lo
            idx.width = width

            var counts = [Int32](repeating: 0, count: count + 1)
            var bucketOf = [Int32](repeating: 0, count: keys.count)
            for (i, k) in keys.enumerated() {
                let b = min(max(Int(((k - lo) / width).rounded(.down)), 0), count - 1)
                bucketOf[i] = Int32(b)
                counts[b + 1] += 1
            }
            for b in 1...count { counts[b] += counts[b - 1] }
            idx.start = counts
            idx.edges = [Int32](repeating: 0, count: keys.count)
            var cursor = counts
            for i in 0..<keys.count {
                let b = Int(bucketOf[i])
                idx.edges[Int(cursor[b])] = Int32(i)
                cursor[b] += 1
            }
            return idx
        }
    }

    /// Projection of each edge midpoint onto the current wave axis, and the
    /// bucket index over it. Rebuilt only when the wave direction changes.
    private var waveProj: [CGFloat] = []
    private var waveBuckets = BucketIndex()

    /// Per-frame accumulator for overlapping ripple fronts, plus the list of
    /// edges it touched so it can be cleared without scanning everything.
    private var rippleAccum: [CGFloat] = []
    private var rippleTouched: [Int32] = []

    // MARK: New-mode state

    /// Terrain height each edge was generated at, or -1 for logo edges. The
    /// generator already computes these and used to throw them away.
    private var edgeHeight: [Int8] = []
    private var edgeHeightMap: [GridEdge: Int] = [:]
    private var terrainLevel: CGFloat = 0
    private var terrainMaxHeight: Int = 3
    /// Height combined with position along a fixed diagonal, so the reveal
    /// travels across the landscape instead of flashing every block of one
    /// height at once. Static per generation, so it can be bucketed.
    private var terrainKey: [CGFloat] = []
    private var terrainKeyRange: ClosedRange<CGFloat> = 0...1
    private var terrainBuckets = BucketIndex()

    /// Coarse lattice used by the field modes. Evaluating smooth noise once per
    /// lattice cell and sampling it per edge is far cheaper than evaluating it
    /// per edge, and the field is low-frequency so nothing is lost.
    private var fieldCols = 0
    private var fieldRows = 0
    private var fieldValues: [CGFloat] = []
    private var edgeCellIndex: [Int32] = []
    private var edgeCellWeights: [SIMD4<Float>] = []
    private var fieldTime: CGFloat = 0

    // MARK: Unlock flourish
    //
    // A pulse that spreads through the grid GRAPH rather than as a circle,
    // with its arrival field warped by smooth noise so the front grows lobes
    // and inlets instead of staying round.
    //
    // Inert until `startUnlockSweep()` is called, and it draws no random
    // numbers and reads no clock, so the golden digests are untouched.

    /// Arrival time for each edge, in hop-space, warped by smooth noise so the
    /// front bulges and stalls instead of expanding as a circle.
    private var flourishHop: [Float] = []
    /// Per-edge brightness ceiling, so the peak is not uniformly flat.
    private var flourishCeiling: [Float] = []
    private var flourishMaxHop: Float = 0
    private var flourishTime: CGFloat = -1
    /// Total length of the flourish. OverlayManager derives its own timing from
    /// this; they used to be set independently and disagreed, so the last 200ms
    /// never rendered and 350ms of it played underneath a fade.
    static let flourishSpan: CGFloat = 1.5
    private let flourishBandMin: Float = 3.0
    private let flourishBandMax: Float = 7.0

    var isSweeping: Bool { flourishTime >= 0 }

    func startUnlockSweep() {
        guard nodeCount > 0, !edgeNodeAIdx.isEmpty else { return }

        // Seed from a few nodes spread across the screen.
        var seeds: [Int32] = []
        var seedDelay: [Float] = []
        let targets: [(CGPoint, Float)] = [
            (CGPoint(x: midX, y: midY), 0),
            (CGPoint(x: size.width * 0.24, y: size.height * 0.70), 2.2),
            (CGPoint(x: size.width * 0.78, y: size.height * 0.32), 3.6),
        ]
        for (t, delay) in targets {
            var best = -1; var bestD = CGFloat.greatestFiniteMagnitude
            for i in 0..<edgeMidX.count {
                let dx = edgeMidX[i] - t.x, dy = edgeMidY[i] - t.y
                let d = dx * dx + dy * dy
                if d < bestD { bestD = d; best = i }
            }
            if best >= 0 { seeds.append(edgeNodeAIdx[best]); seedDelay.append(delay) }
        }
        guard !seeds.isEmpty else { return }

        // Breadth-first over the node graph, each seed starting a little later
        // than the last so their fronts are out of step when they meet.
        var dist = [Float](repeating: -1, count: nodeCount)
        var queue: [Int32] = []
        for (k, s) in seeds.enumerated() { dist[Int(s)] = seedDelay[k]; queue.append(s) }
        var head = 0
        while head < queue.count {
            let n = Int(queue[head]); head += 1
            let d = dist[n] + 1
            for k in Int(nodeAdjStart[n])..<Int(nodeAdjStart[n + 1]) {
                let m = Int(nodeAdjList[k])
                if dist[m] < 0 { dist[m] = d; queue.append(Int32(m)) }
            }
        }

        // Warp the arrival field with two octaves of SMOOTH noise. The previous
        // version used uncorrelated per-edge jitter, which the eye reads as
        // dither: neighbouring edges disagreed randomly, so the front was a
        // fuzzy circle rather than a shape. Correlated noise makes neighbours
        // agree, which is what produces lobes, bays and inlets.
        var warp = [Float](repeating: 0, count: edgeNodeAIdx.count)
        updateFieldLattice(scaleX: 0.13, scaleY: 0.13, t: 3.7)
        for i in 0..<warp.count { warp[i] += Float(sampleField(i) - 0.5) * 2 * 9.0 }
        updateFieldLattice(scaleX: 0.44, scaleY: 0.44, t: 11.3)
        for i in 0..<warp.count { warp[i] += Float(sampleField(i) - 0.5) * 2 * 2.6 }

        flourishHop = (0..<edgeNodeAIdx.count).map { i in
            let a = dist[Int(edgeNodeAIdx[i])], b = dist[Int(edgeNodeBIdx[i])]
            let base = (a < 0 || b < 0) ? max(a, b) : min(a, b)
            return max(base, 0) + warp[i]
        }
        // A varied ceiling, plus a tenth of the edges that burn to full, so the
        // peak has grain instead of pinning everything to the same value.
        flourishCeiling = (0..<edgeNodeAIdx.count).map { i in
            var h = UInt32(truncatingIfNeeded: i &* 2654435761)
            h ^= h >> 15
            let r = Float(h & 0xFFFF) / 65535.0
            return r < 0.10 ? 1.0 : 0.66 + 0.30 * r
        }
        // Calibrate the front's reach on the edges that are actually VISIBLE.
        // The generated lattice is a parallelogram roughly three times wider
        // than the screen, so only about a fifth of its edges are on it. Taking
        // the reach from every edge made the front cross the visible area in
        // the first quarter of the animation and spend the rest travelling
        // off-screen, which is why it read as a quick wipe followed by a fade.
        var visibleMax: Float = 0
        for i in 0..<flourishHop.count {
            let mx = edgeMidX[i], my = edgeMidY[i]
            guard mx >= 0, mx <= size.width, my >= 0, my <= size.height else { continue }
            if flourishHop[i] > visibleMax { visibleMax = flourishHop[i] }
        }
        flourishMaxHop = visibleMax > 0 ? visibleMax : (flourishHop.max() ?? 0)
        flourishTime = 0
    }

    private func tickSweep(dt: CGFloat) {
        guard flourishTime >= 0, !flourishHop.isEmpty else { return }
        flourishTime += dt
        if flourishTime > Self.flourishSpan { flourishTime = -1; return }

        let t = Float(flourishTime / Self.flourishSpan)
        let reach = flourishMaxHop + flourishBandMax

        // The front loads briefly, then releases and decelerates. Constant
        // speed is the single strongest "mechanical" cue; easing out gives it
        // mass. The echo uses a gentler exponent so the gap between the two
        // widens as they slow, which stops them reading as one periodic wave.
        let u = max(0, min((t - 0.073) / 0.927, 1))
        let lead = reach * (1 - powf(1 - u, 4))
        let ue = max(0, min((t - 0.167) / 0.833, 1))
        let echo = reach * 1.06 * (1 - powf(1 - ue, 3))

        // The band widens as the front slows: energy dispersing.
        let band = flourishBandMin + (flourishBandMax - flourishBandMin) * u

        // One peak, with a hold. Attack, plateau, then a long release.
        let envelope: Float
        if t < 0.267 {
            let a = t / 0.267
            envelope = 0.55 + 0.45 * (1 - (1 - a) * (1 - a))
        } else if t < 0.373 {
            envelope = 1.0
        } else {
            let r = (t - 0.373) / 0.627
            envelope = 1.0 - 0.86 * Float(0.5 - 0.5 * cos(Double(r) * Double.pi))
        }

        for i in 0..<flourishHop.count {
            let hop = flourishHop[i]
            var v: Float = 0
            // Squared falloff, not linear: a linear ramp over a wide band puts
            // most of the screen near full brightness at once, which is a slab
            // rather than a front.
            let dl = abs(hop - lead)
            if dl < band { let f = 1 - dl / band; v = f * f }
            let de = abs(hop - echo)
            if de < band {
                let f = 1 - de / band
                let e = f * f * 0.45
                if e > v { v = e }
            }
            guard v > 0.02 else { continue }
            let lit = CGFloat(min(v * envelope * flourishCeiling[i], 1))
            if lit > edgeLit[i] { edgeLit[i] = lit; markLit(i) }
        }
    }

    /// Flow direction, slowly rotating.
    private var flowAngle: CGFloat = 0
    /// One sine period. Calling sin() per edge per frame cost more than the
    /// entire rest of the simulation put together.
    private static let sineTable: [CGFloat] = (0..<4096).map {
        sin(CGFloat($0) / 4096.0 * 2 * .pi)
    }

    /// Wave-field (physics) state, one value per grid node.
    private var nodeIndexOf: [GridNode: Int32] = [:]
    private var nodeCount = 0
    private var nodeAdjStart: [Int32] = []
    private var nodeAdjList: [Int32] = []
    private var nodeU: [CGFloat] = []
    private var nodeUPrev: [CGFloat] = []
    private var edgeNodeAIdx: [Int32] = []
    private var edgeNodeBIdx: [Int32] = []
    private var waveFieldImpulseTimer: CGFloat = 0

    /// walkerActiveEdges stays the source of truth for walker logic; edgeWalker
    /// mirrors it so the per-frame loops can test occupancy with an array read
    /// instead of hashing a GridEdge. All mutation goes through these two.
    @inline(__always)
    private func setWalkerEdge(_ edge: GridEdge, progress: CGFloat, from: GridNode) {
        walkerActiveEdges[edge] = (progress, from)
        if let i = edgeIndex[edge], i < edgeWalker.count { edgeWalker[i] = 1 }
    }

    @inline(__always)
    private func clearWalkerEdge(_ edge: GridEdge) {
        walkerActiveEdges.removeValue(forKey: edge)
        if let i = edgeIndex[edge], i < edgeWalker.count { edgeWalker[i] = -1 }
    }

    /// Brightness for an edge held as a value rather than an index. Only the
    /// cold paths use this (walker arrival, a few times a second).
    @inline(__always)
    private func lit(of edge: GridEdge) -> CGFloat {
        guard let i = edgeIndex[edge] else { return 0 }
        return edgeLit[i]
    }

    @inline(__always)
    private func markLit(_ i: Int) {
        if litSlot[i] < 0 { litSlot[i] = Int32(litList.count); litList.append(Int32(i)) }
    }

    @inline(__always)
    private func clearLit(_ i: Int) {
        let slot = litSlot[i]
        guard slot >= 0 else { return }
        let last = litList[litList.count - 1]
        litList[Int(slot)] = last
        litSlot[Int(last)] = slot
        litList.removeLast()
        litSlot[i] = -1
    }
    /// Bumped on every `generate()`.
    private(set) var generation: Int = 0

    // MARK: Walker Actors

    private struct Walker {
        var fromNode: GridNode       // node the walker entered the edge from
        var toNode: GridNode         // node the walker is heading toward
        var currentEdge: GridEdge?   // edge currently being traversed
        var previousEdge: GridEdge?  // last completed edge (avoid reversal)
        var progress: CGFloat        // 0.0 = at fromNode, 1.0 = at toNode
        var speed: Double            // edges per second
    }

    /// Active edge traversals: edge → (progress 0-1, fromNode)
    private var walkerActiveEdges: [GridEdge: (CGFloat, GridNode)] = [:]

    private var walkers: [Walker] = []
    private var walkerCount: Int = 7  // recalculated based on screen size
    private let walkerSpeed: Double = 6.0

    private var lastTime: CFTimeInterval = 0
    private(set) var tickCount = 0

    // FPS tracking
    private var fpsFrameCount = 0
    private var fpsLastTime: CFTimeInterval = 0
    private(set) var currentFPS: Int = 0

    private var needsGeneration = true

    /// All randomness goes through here so a run can be reproduced exactly.
    /// Unseeded, it is still random per launch -- the app's behaviour is
    /// unchanged; only the harness pins it.
    private var rng: SeededGenerator

    /// 6 neighbor directions on the isometric grid.
    /// Edges are at 30° (iso-right), 90° (vertical), 150° (iso-left) and reverses.
    private let directions: [(Int, Int)] = [
        (1, 0),   // iso-right-up (30°)
        (0, 1),   // vertical up (90°)
        (-1, 1),  // iso-left-up (150°)
        (-1, 0),  // iso-left-down (210°)
        (0, -1),  // vertical down (270°)
        (1, -1),  // iso-right-down (330°)
    ]

    // MARK: Stats

    var litEdgeCount: Int { litList.count }
    var totalEdgeCount: Int { activeEdges.count }

    // MARK: Lifecycle

    init(config: AnimationConfig, size: CGSize = .zero) {
        self.accentR = config.accentR
        self.accentG = config.accentG
        self.accentB = config.accentB
        self.lightMode = config.lightMode
        self.movementType = config.movementType
        self.size = size
        self.rng = SeededGenerator(seed: config.seed ?? UInt64.random(in: 0...UInt64.max))
        log("init size: \(size), lightMode: \(lightMode), movement: \(movementType)")
    }

    // MARK: - Debug Logging

    private static let logFile: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("blackout-debug.log")
        try? "".write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    private func log(_ msg: String) {
        let line = "\(Date()): [SIM] \(msg)\n"
        if let handle = try? FileHandle(forWritingTo: Self.logFile) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        }
    }

    // MARK: - Coordinate Conversion

    /// Isometric grid position:
    ///   x = spacing * q * cos(30°)
    ///   y = spacing * (q * sin(30°) + r)
    /// This gives edges at 30°, 90°, and 150° from horizontal.
    private func position(for node: GridNode) -> CGPoint {
        if let cached = cachedPositions[node] { return cached }
        let s = gridSpacing
        let x = s * CGFloat(node.q) * 0.866025
        let y = s * (CGFloat(node.q) * 0.5 + CGFloat(node.r))
        let pt = CGPoint(x: midX + x, y: midY + y)
        cachedPositions[node] = pt
        return pt
    }

    // MARK: - Pattern Generation

    func generate() {
        log("generate() size: \(size)")
        activeEdges.removeAll()
        logoEdges.removeAll()
        logoEdgeArray.removeAll()
        edgeHeightMap.removeAll()
        centerLogoEdges.removeAll()
        edgeToLogoIndex.removeAll()
        perLogoEdges.removeAll()
        litList.removeAll()
        logoCompletedAt.removeAll()
        logoEverCompleted.removeAll()
        ripples.removeAll()
        edgeScreenPos.removeAll()
        edgeMidpoints.removeAll()
        activeEdgeArray.removeAll()
        edgeIndex.removeAll()
        edgeEndpoints.removeAll()
        edgeVignette.removeAll()
        edgeLit.removeAll(); edgeLogoIndex.removeAll(); edgeIsLogo.removeAll()
        edgeMidX.removeAll(); edgeMidY.removeAll()
        litList.removeAll(); litSlot.removeAll(); edgeWalker.removeAll()
        edgeNodeA.removeAll(); edgeNodeB.removeAll(); perLogoEdgeIdx.removeAll()
        cachedPositions.removeAll()
        adjacency.removeAll()
        walkers.removeAll()
        walkerActiveEdges.removeAll()
        generation += 1

        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { needsGeneration = false; return }

        // Compute grid range from screen corners (isometric projection
        // maps a grid rectangle to a parallelogram, so we need the actual
        // corner positions to avoid missing the top-left/bottom-right).
        let s = gridSpacing
        // Use a buffer INSIDE the screen so no edges bleed off
        let buf = gridSpacing * 1.5
        let screenInset = [
            CGPoint(x: buf, y: buf),
            CGPoint(x: w - buf, y: buf),
            CGPoint(x: w - buf, y: h - buf),
            CGPoint(x: buf, y: h - buf),
        ]
        var qMin = Int.max, qMax = Int.min, rMin = Int.max, rMax = Int.min
        for corner in screenInset {
            let qf = (corner.x - midX) / (s * 0.866025)
            let rf = (corner.y - midY) / s - qf * 0.5
            qMin = min(qMin, Int(floor(qf)))
            qMax = max(qMax, Int(ceil(qf)))
            rMin = min(rMin, Int(floor(rf)))
            rMax = max(rMax, Int(ceil(rf)))
        }
        log("grid q:\(qMin)...\(qMax) r:\(rMin)...\(rMax)")

        // Store range for logo placement
        qRangeMin = qMin; qRangeMax = qMax
        rRangeMin = rMin; rRangeMax = rMax

        // Build logo edges first
        buildLogoEdges()
        log("logo edges: \(logoEdges.count)")

        // Grow pattern from logo outward, filling the screen
        growPattern(qMin: qMin, qMax: qMax, rMin: rMin, rMax: rMax)
        log("total edges: \(activeEdges.count)")

        // Build adjacency for fast wavefront
        buildAdjacency()

        // Edge brightness lives in edgeLit, allocated below and zeroed.

        // Pre-cache screen positions for all edges
        edgeScreenPos.removeAll()
        for edge in activeEdges {
            edgeScreenPos[edge] = (position(for: edge.a), position(for: edge.b))
        }

        // Cache edge array, stable indices, endpoints and midpoints.
        // Sorted, not Set order: this array fixes every edge's index, which
        // determines draw order and which edge a random pick returns.
        activeEdgeArray = activeEdges.sorted(by: isometricEdgeOrder)
        logoEdgeArray = logoEdges.sorted(by: isometricEdgeOrder)
        edgeIndex.reserveCapacity(activeEdgeArray.count)
        edgeEndpoints.reserveCapacity(activeEdgeArray.count)
        edgeMidpoints.reserveCapacity(activeEdgeArray.count)
        let n = activeEdgeArray.count
        edgeVignette.reserveCapacity(n)
        edgeEndpoints.reserveCapacity(n)
        edgeMidX.reserveCapacity(n); edgeMidY.reserveCapacity(n)
        edgeNodeA.reserveCapacity(n); edgeNodeB.reserveCapacity(n)
        let vigR = max(hypot(size.width, size.height) * 0.5, 1)
        for (i, edge) in activeEdgeArray.enumerated() {
            edgeIndex[edge] = i
            let (pA, pB) = edgeScreenPos[edge]!
            edgeEndpoints.append(SIMD4<Float>(Float(pA.x), Float(pA.y), Float(pB.x), Float(pB.y)))
            let mx = (pA.x + pB.x) * 0.5, my = (pA.y + pB.y) * 0.5
            edgeMidpoints.append((edge, mx, my))
            edgeMidX.append(mx); edgeMidY.append(my)
            edgeNodeA.append(edge.a); edgeNodeB.append(edge.b)
            let d = min(hypot(mx - midX, my - midY) / vigR, 1.0)
            edgeVignette.append(Float(1.0 - 0.45 * d * d))
        }
        edgeLit = Array(repeating: 0, count: n)
        rippleAccum = Array(repeating: 0, count: n)
        rippleTouched.removeAll(keepingCapacity: true)
        litSlot = Array(repeating: -1, count: n)
        edgeWalker = Array(repeating: -1, count: n)
        edgeIsLogo = Array(repeating: false, count: n)
        edgeLogoIndex = Array(repeating: -1, count: n)
        for (i, edge) in activeEdgeArray.enumerated() where logoEdges.contains(edge) {
            edgeIsLogo[i] = true
            edgeLogoIndex[i] = Int32(edgeToLogoIndex[edge] ?? -1)
        }
        perLogoEdgeIdx = perLogoEdges.map { $0.compactMap { edgeIndex[$0].map(Int32.init) } }

        buildModeIndices()

        needsGeneration = false
        log("generate() done")
    }

    /// Per-edge data the field and physics modes need. Built once per
    /// generation, alongside the geometry.
    private func buildModeIndices() {
        let n = activeEdgeArray.count
        guard n > 0 else { return }

        // Terrain height per edge; logo edges carry -1.
        edgeHeight = activeEdgeArray.map { edge in
            guard !logoEdges.contains(edge), let h = edgeHeightMap[edge] else { return Int8(-1) }
            return Int8(clamping: h)
        }
        terrainMaxHeight = max(Int(edgeHeight.max() ?? 3), 1)

        let dq = 0.7071067811865476 as CGFloat
        terrainKey = (0..<n).map { i in
            let h = edgeHeight[i]
            let spatial = (edgeMidX[i] * dq + edgeMidY[i] * dq) / 260.0
            // Logo edges sit slightly ahead of the ground so they lead the sweep.
            return spatial + (h < 0 ? 0.4 : CGFloat(h) * 0.5)
        }
        if let lo = terrainKey.min(), let hi = terrainKey.max() {
            terrainKeyRange = lo...hi
            terrainBuckets = BucketIndex.build(keys: terrainKey, width: 0.35)
        }

        // Coarse lattice for the field modes, about one cell per 48 points.
        fieldCols = max(Int(size.width / 48) + 2, 4)
        fieldRows = max(Int(size.height / 48) + 2, 4)
        fieldValues = Array(repeating: 0, count: fieldCols * fieldRows)
        edgeCellIndex = Array(repeating: 0, count: n)
        edgeCellWeights = Array(repeating: .zero, count: n)
        let cw = size.width / CGFloat(fieldCols - 1)
        let ch = size.height / CGFloat(fieldRows - 1)
        for i in 0..<n {
            let gx = min(max(edgeMidX[i] / cw, 0), CGFloat(fieldCols - 1) - 0.0001)
            let gy = min(max(edgeMidY[i] / ch, 0), CGFloat(fieldRows - 1) - 0.0001)
            let x0 = Int(gx), y0 = Int(gy)
            let fx = Float(gx - CGFloat(x0)), fy = Float(gy - CGFloat(y0))
            edgeCellIndex[i] = Int32(y0 * fieldCols + x0)
            edgeCellWeights[i] = SIMD4<Float>((1 - fx) * (1 - fy), fx * (1 - fy),
                                              (1 - fx) * fy, fx * fy)
        }

        // Node graph for the wave-field mode.
        nodeIndexOf.removeAll()
        var neighbours: [[Int32]] = []
        func nodeIdx(_ node: GridNode) -> Int32 {
            if let i = nodeIndexOf[node] { return i }
            let i = Int32(neighbours.count)
            nodeIndexOf[node] = i
            neighbours.append([])
            return i
        }
        edgeNodeAIdx = Array(repeating: 0, count: n)
        edgeNodeBIdx = Array(repeating: 0, count: n)
        for (i, edge) in activeEdgeArray.enumerated() {
            let a = nodeIdx(edge.a), b = nodeIdx(edge.b)
            edgeNodeAIdx[i] = a; edgeNodeBIdx[i] = b
            neighbours[Int(a)].append(b)
            neighbours[Int(b)].append(a)
        }
        nodeCount = neighbours.count
        nodeAdjStart = [Int32](repeating: 0, count: nodeCount + 1)
        for i in 0..<nodeCount { nodeAdjStart[i + 1] = nodeAdjStart[i] + Int32(neighbours[i].count) }
        nodeAdjList = [Int32](repeating: 0, count: Int(nodeAdjStart[nodeCount]))
        for i in 0..<nodeCount {
            let base = Int(nodeAdjStart[i])
            for (k, nb) in neighbours[i].enumerated() { nodeAdjList[base + k] = nb }
        }
        nodeU = Array(repeating: 0, count: nodeCount)
        nodeUPrev = Array(repeating: 0, count: nodeCount)
    }

    // MARK: - Logo Definition

    /// Place a logo shape at the given grid offset. All edges are added to
    /// activeEdges and logoEdges.
    private func buildLogoAt(qOffset: Int, rOffset: Int) {
        func addPath(from start: GridNode, direction: (Int, Int), steps: Int) {
            var current = start
            for _ in 0..<steps {
                let next = GridNode(q: current.q + direction.0, r: current.r + direction.1)
                let edge = GridEdge(current, next)
                activeEdges.insert(edge)
                logoEdges.insert(edge)
                current = next
            }
        }

        let up         = (0, 1)
        let upRight    = (1, 0)
        let upLeft     = (-1, 1)
        let down       = (0, -1)
        let downRight  = (1, -1)
        let downLeft   = (-1, 0)

        // Outer contour
        var cursor = GridNode(q: qOffset, r: rOffset)

        let segments: [((Int, Int), Int)] = [
            (up, 2), (upRight, 2), (upLeft, 2), (up, 1), (upRight, 1),
            (downRight, 3), (down, 2), (downLeft, 2), (down, 1),
            (downLeft, 1), (upLeft, 1),
        ]

        for (dir, steps) in segments {
            addPath(from: cursor, direction: dir, steps: steps)
            cursor = GridNode(q: cursor.q + dir.0 * steps, r: cursor.r + dir.1 * steps)
        }

        // Inner shape (3D depth lines)
        cursor = GridNode(q: qOffset, r: rOffset)

        let innerSegments: [((Int, Int), Int)] = [
            (downRight, 1), (up, 2), (upLeft, 1), (downRight, 1),
            (upRight, 2), (upLeft, 1), (downRight, 1), (up, 1),
            (upRight, 1), (downLeft, 1), (upLeft, 3),
        ]

        for (dir, steps) in innerSegments {
            addPath(from: cursor, direction: dir, steps: steps)
            cursor = GridNode(q: cursor.q + dir.0 * steps, r: cursor.r + dir.1 * steps)
        }
    }

    /// Convert a screen pixel position to the nearest grid (q, r).
    private func gridCoord(at pixel: CGPoint) -> (Int, Int) {
        let s = gridSpacing
        let qf = (pixel.x - midX) / (s * 0.866025)
        let rf = (pixel.y - midY) / s - qf * 0.5
        return (Int(round(qf)), Int(round(rf)))
    }

    private func buildLogoEdges() {
        logoOffsets.removeAll()
        edgeToLogoIndex.removeAll()
        perLogoEdges.removeAll()

        // Helper: build a logo and record which edges belong to which index
        func addLogo(qOffset: Int, rOffset: Int) {
            let idx = logoOffsets.count
            logoOffsets.append((qOffset, rOffset))
            let before = logoEdges
            buildLogoAt(qOffset: qOffset, rOffset: rOffset)
            let newEdges = logoEdges.subtracting(before)
            perLogoEdges.append(newEdges.sorted(by: isometricEdgeOrder))
            for edge in newEdges {
                edgeToLogoIndex[edge] = idx
            }
        }

        // Center logo (always)
        addLogo(qOffset: 0, rOffset: 0)
        centerLogoEdges = perLogoEdges[0]

        // Scale logo count by screen area. ~5 for a 16" laptop (1728x1117 ≈ 1.93M px²)
        // ~10 for a 34" ultrawide (3440x1440 ≈ 4.95M px²)
        let screenArea = size.width * size.height
        let baseArea: CGFloat = 1_930_000  // 16" laptop baseline
        let extraLogos = max(3, Int(round(4.0 * screenArea / baseArea)))  // 4 extra at baseline

        // Place extra logos at random screen positions with margin.
        // Each logo spans ~5x6 grid units, so enforce minimum distance between origins.
        let margin: CGFloat = 0.10
        let minDist = gridSpacing * 10  // ~10 grid units apart (logo size + 2 unit gap)
        var placedPixels: [CGPoint] = [CGPoint(x: midX, y: midY)]  // center logo

        for _ in 0..<(extraLogos * 3) {  // extra attempts since some will be rejected
            if logoOffsets.count >= extraLogos + 1 { break }  // +1 for center
            let px = CGPoint(
                x: size.width * CGFloat.random(in: margin...(1.0 - margin), using: &rng),
                y: size.height * CGFloat.random(in: margin...(1.0 - margin), using: &rng)
            )
            // Check distance to all already-placed logos
            let tooClose = placedPixels.contains { hypot($0.x - px.x, $0.y - px.y) < minDist }
            if tooClose { continue }

            let (q, r) = gridCoord(at: px)
            addLogo(qOffset: q, rOffset: r)
            placedPixels.append(px)
        }

        log("\(logoOffsets.count) logos placed, total logo edges: \(logoEdges.count)")
    }

    // Store grid range and logo positions
    private var qRangeMin = 0
    private var qRangeMax = 0
    private var rRangeMin = 0
    private var rRangeMax = 0
    private var logoOffsets: [(Int, Int)] = []  // (q, r) offsets for each logo

    // MARK: - Pattern Growth (3D Terrain)

    /// Test if a point is inside a polygon using ray casting.
    private func isInsidePolygon(qf: Double, rf: Double, polygon: [(Double, Double)]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let (xi, yi) = polygon[i]
            let (xj, yj) = polygon[j]
            if ((yi > rf) != (yj > rf)) &&
               (qf < (xj - xi) * (rf - yi) / (yj - yi) + xi) {
                inside = !inside
            }
            j = i
        }
        return inside
    }

    /// Build set of grid nodes that fall inside any logo outline.
    private func buildLogoInterior() -> Set<GridNode> {
        // Base polygon shape (relative to offset 0,0)
        let basePoly: [(Double, Double)] = [
            (0, 0), (0, 2), (2, 2), (0, 4), (0, 5), (1, 5),
            (4, 2), (4, 0), (2, 0), (2, -1), (1, -1),
        ]
        var interior: Set<GridNode> = []

        for (oq, or2) in logoOffsets {
            let polygon = basePoly.map { ($0.0 + Double(oq), $0.1 + Double(or2)) }
            for q in (oq - 1)...(oq + 5) {
                for r in (or2 - 2)...(or2 + 6) {
                    if isInsidePolygon(qf: Double(q) + 0.01, rf: Double(r) + 0.01, polygon: polygon) {
                        interior.insert(GridNode(q: q, r: r))
                    }
                }
            }
        }
        return interior
    }

    /// Add edge if neither endpoint is inside the logo interior.
    private func addTerrainEdge(_ a: GridNode, _ b: GridNode, excluded: Set<GridNode>,
                                height: Int = 0) -> Bool {
        if excluded.contains(a) || excluded.contains(b) { return false }
        let edge = GridEdge(a, b)
        let inserted = activeEdges.insert(edge).inserted
        // Keep the height the generator already knows. Terrain mode reveals the
        // relief with it; before, it was computed and discarded.
        if inserted { edgeHeightMap[edge] = height }
        return inserted
    }

    /// Render the top face (diamond) of a block, skipping edges shared with
    /// same-height neighbors so clusters merge into clean outlines.
    private func renderTopFace(q: Int, hPlusZ: Int, h: Int,
                               hXm1: Int, hXp1: Int, hZm1: Int, hZp1: Int,
                               excluded: Set<GridNode>) -> Int {
        let height = h
        let r = hPlusZ
        let a = GridNode(q: q, r: r)
        let b = GridNode(q: q + 1, r: r)
        let c = GridNode(q: q, r: r + 1)
        let d = GridNode(q: q - 1, r: r + 1)
        var n = 0
        if hZm1 != h { if addTerrainEdge(a, b, excluded: excluded, height: height) { n += 1 } }
        if hXp1 != h { if addTerrainEdge(b, c, excluded: excluded, height: height) { n += 1 } }
        if hZp1 != h { if addTerrainEdge(c, d, excluded: excluded, height: height) { n += 1 } }
        if hXm1 != h { if addTerrainEdge(d, a, excluded: excluded, height: height) { n += 1 } }
        return n
    }

    private func growPattern(qMin: Int, qMax: Int, rMin: Int, rMax: Int) {
        let excluded = buildLogoInterior()
        log("logo interior: \(excluded.count) nodes excluded")

        let maxH = 2
        let zMin = rMin - maxH - 3
        let zMax = rMax + 3
        let xMin = qMin + zMin - 3
        let xMax = qMax + zMax + 3
        let xSize = xMax - xMin + 1
        let zSize = zMax - zMin + 1
        log("terrain 3D: \(xSize)x\(zSize)")

        var heights = Array(repeating: Array(repeating: -1, count: zSize), count: xSize)
        generateClusteredTerrain(heights: &heights, xSize: xSize, zSize: zSize)

        var edgeCount = 0
        for xi in 0..<xSize {
            for zi in 0..<zSize {
                let h = heights[xi][zi]
                if h <= 0 { continue }
                let x = xMin + xi
                let z = zMin + zi
                let q = x - z

                let hXm1 = (xi > 0) ? heights[xi - 1][zi] : -1
                let hXp1 = (xi + 1 < xSize) ? heights[xi + 1][zi] : -1
                let hZm1 = (zi > 0) ? heights[xi][zi - 1] : -1
                let hZp1 = (zi + 1 < zSize) ? heights[xi][zi + 1] : -1

                // Top face outlines only (no walls)
                edgeCount += renderTopFace(q: q, hPlusZ: h + z, h: h,
                                           hXm1: hXm1, hXp1: hXp1,
                                           hZm1: hZm1, hZp1: hZp1,
                                           excluded: excluded)

                // Sparse vertical connectors at height boundaries for wavefront flow.
                // Only add ONE vertical at the first corner of each boundary edge.
                if hXp1 != -1 && hXp1 != h {
                    let lo = min(h, hXp1), hi = max(h, hXp1)
                    let cq = q + 1  // corner B between this and x+1 neighbor
                    for y in lo..<hi {
                        if addTerrainEdge(GridNode(q: cq, r: y + z),
                                          GridNode(q: cq, r: y + z + 1),
                                          excluded: excluded, height: y + 1) { edgeCount += 1 }
                    }
                }
                if hZp1 != -1 && hZp1 != h {
                    let lo = min(h, hZp1), hi = max(h, hZp1)
                    let cq = q - 1  // corner D between this and z+1 neighbor
                    for y in lo..<hi {
                        if addTerrainEdge(GridNode(q: cq, r: y + z + 1),
                                          GridNode(q: cq, r: y + z + 2),
                                          excluded: excluded, height: y + 1) { edgeCount += 1 }
                    }
                }
            }
        }

        log("terrain: \(edgeCount) new edges, total: \(activeEdges.count)")
    }

    private func generateClusteredTerrain(heights: inout [[Int]], xSize: Int, zSize: Int) {
        var assigned = Array(repeating: Array(repeating: false, count: zSize), count: xSize)
        let growDirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]

        var unassigned: [(Int, Int)] = []
        for xi in 0..<xSize {
            for zi in 0..<zSize {
                unassigned.append((xi, zi))
            }
        }
        unassigned.shuffle(using: &rng)

        for (seedX, seedZ) in unassigned {
            if assigned[seedX][seedZ] { continue }

            let targetSize = Int.random(in: 2...3, using: &rng)
            var cluster: [(Int, Int)] = [(seedX, seedZ)]
            assigned[seedX][seedZ] = true

            var frontier = [(seedX, seedZ)]
            while cluster.count < targetSize && !frontier.isEmpty {
                let fi = Int.random(in: 0..<frontier.count, using: &rng)
                let (fx, fz) = frontier[fi]

                var grew = false
                for dir in growDirs.shuffled(using: &rng) {
                    if cluster.count >= targetSize { break }
                    let nx = fx + dir.0
                    let nz = fz + dir.1
                    guard nx >= 0 && nx < xSize && nz >= 0 && nz < zSize else { continue }
                    guard !assigned[nx][nz] else { continue }
                    assigned[nx][nz] = true
                    cluster.append((nx, nz))
                    frontier.append((nx, nz))
                    grew = true
                    break
                }
                if !grew {
                    frontier.remove(at: fi)
                }
            }

            // Pick height that differs from already-assigned neighbors
            var neighborHeights: Set<Int> = []
            for (cx, cz) in cluster {
                for (dx, dz) in growDirs {
                    let nx = cx + dx, nz = cz + dz
                    guard nx >= 0 && nx < xSize && nz >= 0 && nz < zSize else { continue }
                    if heights[nx][nz] > 0 { neighborHeights.insert(heights[nx][nz]) }
                }
            }
            let candidates = [1, 2, 3].filter { !neighborHeights.contains($0) }
            let h = candidates.randomElement(using: &rng) ?? Int.random(in: 1...3, using: &rng)
            for (cx, cz) in cluster {
                heights[cx][cz] = h
            }
        }
    }

    // MARK: - Adjacency

    private func buildAdjacency() {
        adjacency.removeAll()
        // Iterate the canonical order so each node's candidate list is stable;
        // pickNextEdge draws from these lists.
        for edge in adjacencySource {
            adjacency[edge.a, default: []].append(edge)
            adjacency[edge.b, default: []].append(edge)
        }
    }

    /// buildAdjacency runs during generate(), before activeEdgeArray is built,
    /// so it sorts its own view of the edges.
    private var adjacencySource: [GridEdge] {
        activeEdgeArray.isEmpty ? activeEdges.sorted(by: isometricEdgeOrder) : activeEdgeArray
    }

    // MARK: - Walker Animation

    private func spawnWalker(on edge: GridEdge) {
        let fromNode = edge.a
        let toNode = edge.b
        walkers.append(Walker(
            fromNode: fromNode,
            toNode: toNode,
            currentEdge: edge,
            previousEdge: nil,
            progress: 0,
            speed: walkerSpeed + Double.random(in: -1.5...1.5, using: &rng)
        ))
        setWalkerEdge(edge, progress: 0, from: fromNode)
    }

    private func spawnWalkers() {
        walkers.removeAll()
        walkerActiveEdges.removeAll()
        for i in 0..<edgeWalker.count { edgeWalker[i] = -1 }
        guard !activeEdges.isEmpty else { return }

        // Walker 1: start on the center logo specifically
        if let logoStart = centerLogoEdges.randomElement(using: &rng) ?? logoEdgeArray.randomElement(using: &rng) {
            spawnWalker(on: logoStart)
        }

        // Walkers 2-7: spread across 6 screen regions
        let thirdX = size.width / 3
        let halfY = size.height / 2
        let regions: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0, thirdX, halfY, size.height),              // top-left
            (thirdX, thirdX * 2, halfY, size.height),     // top-center
            (thirdX * 2, size.width, halfY, size.height), // top-right
            (0, thirdX, 0, halfY),                        // bottom-left
            (thirdX, thirdX * 2, 0, halfY),               // bottom-center
            (thirdX * 2, size.width, 0, halfY),           // bottom-right
        ]

        for (xMin, xMax, yMin, yMax) in regions {
            let candidates = activeEdgeArray.filter { edge in
                if logoEdges.contains(edge) { return false }
                let p = position(for: edge.a)
                return p.x >= xMin && p.x < xMax && p.y >= yMin && p.y < yMax
            }
            if let pick = candidates.randomElement(using: &rng) {
                spawnWalker(on: pick)
            }
        }

        log("spawned \(walkers.count) walkers (1 logo + \(walkers.count - 1) quadrants)")
    }

    /// Check if a grid node's screen position is within visible bounds.
    private func isOnScreen(_ node: GridNode) -> Bool {
        let p = position(for: node)
        return p.x >= -gridSpacing && p.x <= size.width + gridSpacing &&
               p.y >= -gridSpacing && p.y <= size.height + gridSpacing
    }

    /// Pick the next edge for a walker arriving at `node`.
    /// All walkers will finish filling any logo they encounter before moving on.
    private func pickNextEdge(at node: GridNode, previous: GridEdge?, isLogoWalker: Bool = false) -> GridEdge? {
        guard let edges = adjacency[node], !edges.isEmpty else { return nil }

        // Filter to edges that stay on screen
        let validEdges = edges.filter { edge in
            if edge == previous { return false }
            if walkerActiveEdges[edge] != nil { return false }
            let dest = (edge.a == node) ? edge.b : edge.a
            return isOnScreen(dest)
        }

        // Check if this node has unlit logo edges — any walker can fill them
        var unlitLogo: [GridEdge] = []
        var litLogo: [GridEdge] = []
        for edge in validEdges {
            if logoEdges.contains(edge) {
                if lit(of: edge) < 0.3 {
                    unlitLogo.append(edge)
                } else {
                    litLogo.append(edge)
                }
            }
        }

        // If there are unlit logo edges adjacent, take one
        if let pick = unlitLogo.randomElement(using: &rng) { return pick }

        // If on a logo node, stay to finish filling it if it has unlit edges
        if !litLogo.isEmpty {
            if let sampleLogoEdge = (unlitLogo + litLogo).first,
               let logoIdx = edgeToLogoIndex[sampleLogoEdge] {
                let thisLogoHasUnlit = perLogoEdges[logoIdx].contains {
                    self.lit(of: $0) < 0.3
                }
                if thisLogoHasUnlit {
                    if let pick = litLogo.randomElement(using: &rng) { return pick }
                }
            }
        }

        // For the center logo walker on first pass, jump to unlit center logo edges
        if isLogoWalker {
            let unlitCenter = centerLogoEdges.filter { self.lit(of: $0) < 0.3 }
            if let pick = unlitCenter.randomElement(using: &rng) { return pick }
        }

        // Normal exploration: prefer unlit > dim > bright
        var unlit: [GridEdge] = []
        var dim: [GridEdge] = []
        var bright: [GridEdge] = []

        for edge in validEdges {
            let lit = self.lit(of: edge)
            if lit < 0.05 {
                unlit.append(edge)
            } else if lit < 0.4 {
                dim.append(edge)
            } else {
                bright.append(edge)
            }
        }

        if let pick = unlit.randomElement(using: &rng) { return pick }
        if let pick = dim.randomElement(using: &rng) { return pick }
        if let pick = bright.randomElement(using: &rng) { return pick }
        return previous  // dead end, reverse
    }

    /// Check if center logo has ever been fully lit (permanent — no re-visiting).
    private var logoFullyLit: Bool {
        logoEverCompleted.contains(0)  // logo index 0 = center
    }

    // MARK: - Animation

    private var hasSetup = false

    /// Prepare for animation: generate if needed, spawn actors. Idempotent until `stop()`.
    func start(now: CFTimeInterval) {
        guard !hasSetup else { return }
        hasSetup = true

        log("setup, size: \(size)")
        if needsGeneration {
            generate()
        }

        // Scale walker count by screen area: ~7 for 16" laptop, ~14 for 34" ultrawide
        let screenArea = size.width * size.height
        let baseArea: CGFloat = 1_930_000
        walkerCount = max(5, Int(round(7.0 * screenArea / baseArea)))

        lastTime = now

        switch movementType {
        case .walkers, .random:
            spawnWalkers()
        case .terrain:
            terrainLevel = 0
        case .noise, .flow:
            fieldTime = CGFloat.random(in: 0...50, using: &rng)
            flowAngle = CGFloat.random(in: 0...(2 * .pi), using: &rng)
        case .waveField:
            for i in 0..<nodeU.count { nodeU[i] = 0; nodeUPrev[i] = 0 }
            waveFieldImpulseTimer = 0
        case .ripple, .rain:
            ripples.removeAll()
            rippleSpawnTimer = 0
            spawnRipple()
        case .wave:
            let angle = CGFloat.random(in: 0...(2 * .pi), using: &rng)
            waveDirection = CGPoint(x: cos(angle), y: sin(angle))
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                           CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
            let center = CGPoint(x: midX, y: midY)
            var maxProj: CGFloat = 0
            for c in corners {
                let dx = c.x - center.x, dy = c.y - center.y
                let proj = abs(dx * waveDirection.x + dy * waveDirection.y)
                maxProj = max(maxProj, proj)
            }
            waveMaxDist = maxProj + waveBandWidth
            wavePosition = -waveMaxDist
            rebuildWaveBuckets()
        }

        log("setup done, edges: \(activeEdges.count), walkers: \(walkers.count)")
    }

    func stop() {
        hasSetup = false
    }

    /// Re-anchor the clock after the animation was paused, so the first tick
    /// back does not integrate the whole pause as one enormous dt.
    func resyncClock(to now: CFTimeInterval) {
        lastTime = now
    }

    /// Advance the simulation to `now`. Call `start(now:)` first.
    func tick(now currentTime: CFTimeInterval) {
        if needsGeneration {
            // Size changed since start — rebuild geometry and actors.
            hasSetup = false
            start(now: currentTime)
        }
        if lastTime == 0 { lastTime = currentTime }
        let dt = min(currentTime - lastTime, 0.05)
        lastTime = currentTime

        switch movementType {
        case .walkers, .random:
            tickWalkers(dt: CGFloat(dt))
            fadeEdges(dt: CGFloat(dt), now: currentTime, decayPerSecond: 0.68)
        case .wave:
            tickWave(dt: CGFloat(dt))
            fadeEdges(dt: CGFloat(dt), now: currentTime, decayPerSecond: 0.30, removeThreshold: 0.03)
        case .ripple, .rain:
            tickRipple(dt: CGFloat(dt))
            fadeEdges(dt: CGFloat(dt), now: currentTime, decayPerSecond: 0.30, removeThreshold: 0.03)
        case .terrain:
            tickTerrain(dt: CGFloat(dt))
            fadeEdges(dt: CGFloat(dt), now: currentTime, decayPerSecond: 0.12, removeThreshold: 0.03)
        case .noise:
            tickNoise(dt: CGFloat(dt))
            fadeEdges(dt: CGFloat(dt), now: currentTime, decayPerSecond: 0.02, removeThreshold: 0.05)
        case .flow:
            tickFlow(dt: CGFloat(dt))
            fadeEdges(dt: CGFloat(dt), now: currentTime, decayPerSecond: 0.004, removeThreshold: 0.06)
        case .waveField:
            tickWaveField(dt: CGFloat(dt))
            fadeEdges(dt: CGFloat(dt), now: currentTime, decayPerSecond: 0.05, removeThreshold: 0.02)
        }
        // The flourish rides on top of whatever mode is running, but it needs
        // the grid to go dark behind its front. Without this extra decay the
        // front lights the whole lattice within half a second and the pulse
        // stops reading as travelling at all.
        if isSweeping {
            fadeEdges(dt: CGFloat(dt), now: currentTime,
                      decayPerSecond: 0.02, removeThreshold: 0.04)
        }
        tickSweep(dt: CGFloat(dt))

        // FPS counter
        fpsFrameCount += 1
        if fpsLastTime == 0 { fpsLastTime = currentTime }
        let fpsElapsed = currentTime - fpsLastTime
        if fpsElapsed >= 1.0 {
            currentFPS = Int(Double(fpsFrameCount) / fpsElapsed)
            fpsFrameCount = 0
            fpsLastTime = currentTime
        }

        tickCount += 1
    }

    private func tickWalkers(dt: CGFloat) {
        for i in 0..<walkers.count {
            walkers[i].progress += CGFloat(walkers[i].speed) * dt

            if let edge = walkers[i].currentEdge {
                setWalkerEdge(edge, progress: min(walkers[i].progress, 1.0), from: walkers[i].fromNode)
            }

            while walkers[i].progress >= 1.0 {
                walkers[i].progress -= 1.0

                if let edge = walkers[i].currentEdge {
                    clearWalkerEdge(edge)
                    if let li = edgeIndex[edge] { edgeLit[li] = 1.0; markLit(li) }
                }

                let arrivalNode = walkers[i].toNode
                let prevEdge = walkers[i].currentEdge

                let isLogoWalker = i == 0 && !logoFullyLit
                if let nextEdge = pickNextEdge(at: arrivalNode, previous: prevEdge, isLogoWalker: isLogoWalker) {
                    let nextTo = (nextEdge.a == arrivalNode) ? nextEdge.b : nextEdge.a
                    walkers[i].fromNode = arrivalNode
                    walkers[i].toNode = nextTo
                    walkers[i].previousEdge = prevEdge
                    walkers[i].currentEdge = nextEdge
                    setWalkerEdge(nextEdge, progress: walkers[i].progress, from: arrivalNode)
                } else {
                    let startEdge = activeEdgeArray[Int.random(in: 0..<activeEdgeArray.count, using: &rng)]
                    let from = Bool.random(using: &rng) ? startEdge.a : startEdge.b
                    let to = (startEdge.a == from) ? startEdge.b : startEdge.a
                    walkers[i].fromNode = from
                    walkers[i].toNode = to
                    walkers[i].currentEdge = startEdge
                    walkers[i].previousEdge = nil
                    walkers[i].progress = 0
                    setWalkerEdge(startEdge, progress: 0, from: from)
                }
            }
        }
    }

    private func tickWave(dt: CGFloat) {
        // Advance wave along its direction
        wavePosition += waveSpeed * dt

        // Wrap when past the screen
        if wavePosition > waveMaxDist {
            // Pick a new random direction for next sweep
            let angle = CGFloat.random(in: 0...(2 * .pi), using: &rng)
            waveDirection = CGPoint(x: cos(angle), y: sin(angle))
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                           CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
            let center = CGPoint(x: midX, y: midY)
            var maxProj: CGFloat = 0
            for c in corners {
                let dx = c.x - center.x, dy = c.y - center.y
                maxProj = max(maxProj, abs(dx * waveDirection.x + dy * waveDirection.y))
            }
            waveMaxDist = maxProj + waveBandWidth
            wavePosition = -waveMaxDist
            rebuildWaveBuckets()
        }

        // Light up edges whose midpoint projects near the wave front. Only the
        // buckets the band actually covers are visited; the test inside is
        // unchanged, so the result is identical to scanning everything.
        let halfBand = waveBandWidth / 2.0
        let pos = wavePosition
        guard !waveProj.isEmpty else { return }
        let slice = waveBuckets.range(lo: pos - halfBand, hi: pos + halfBand)
        for b in slice {
            let lo = Int(waveBuckets.start[b]), hi = Int(waveBuckets.start[b + 1])
            for k in lo..<hi {
                let i = Int(waveBuckets.edges[k])
                let dist = abs(waveProj[i] - pos)
                if dist < halfBand {
                    let intensity = 1.0 - dist / halfBand
                    if intensity > edgeLit[i] {
                        edgeLit[i] = intensity
                        markLit(i)
                    }
                }
            }
        }
    }

    /// The wave sweeps along one axis, so projecting every edge onto that axis
    /// once lets each frame touch only the slice near the front instead of all
    /// 24k-67k edges. The direction changes about every 40 seconds, so this is
    /// amortised to nothing.
    private func rebuildWaveBuckets() {
        let cx = midX, cy = midY
        let dx = waveDirection.x, dy = waveDirection.y
        waveProj = (0..<edgeMidX.count).map { i in
            (edgeMidX[i] - cx) * dx + (edgeMidY[i] - cy) * dy
        }
        waveBuckets = BucketIndex.build(keys: waveProj, width: waveBandWidth / 2)
    }

    private var isRain: Bool { movementType == .rain }

    private func spawnRipple() {
        // Ripple picks the middle of the screen; rain falls anywhere.
        let lo: CGFloat = isRain ? 0.05 : 0.20
        let hi: CGFloat = isRain ? 0.95 : 0.80
        let cx = size.width * CGFloat.random(in: lo...hi, using: &rng)
        let cy = size.height * CGFloat.random(in: lo...hi, using: &rng)
        let center = CGPoint(x: cx, y: cy)

        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                       CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
        // A raindrop is a small ring that dies quickly; a ripple crosses the screen.
        let maxR = isRain
            ? CGFloat.random(in: 90...220, using: &rng)
            : corners.map { hypot($0.x - cx, $0.y - cy) }.max()! + rippleBandWidth

        // Key on exactly the distance the per-frame test derives, so the
        // buckets only narrow the candidate set and never change a result.
        let keys = (0..<edgeMidX.count).map { i -> CGFloat in
            let dx = edgeMidX[i] - cx, dy = edgeMidY[i] - cy
            return (dx * dx + dy * dy).squareRoot()
        }
        var ripple = Ripple(center: center, radius: 0, maxRadius: maxR)
        ripple.buckets = BucketIndex.build(keys: keys, width: rippleBandWidth / 2)
        ripples.append(ripple)
    }

    private func tickRipple(dt: CGFloat) {
        // Rain drops far more often, and each one is smaller and faster.
        let interval = isRain ? 0.28 : rippleSpawnInterval
        let speed = isRain ? rippleSpeed * 2.2 : rippleSpeed
        rippleSpawnTimer += dt
        if rippleSpawnTimer >= interval {
            rippleSpawnTimer = 0
            spawnRipple()
        }

        // Advance all ripples and remove completed ones
        for i in 0..<ripples.count {
            ripples[i].radius += speed * dt
        }
        ripples.removeAll { $0.radius > $0.maxRadius }

        guard !ripples.isEmpty else { return }

        // Light up edges near each ring. Applying rings one at a time gives the
        // same value as taking their maximum first, because brightness here
        // only ever increases.
        let halfBand = rippleBandWidth / 2.0

        // Rings SUPERPOSE. Real waves pass through one another and their
        // amplitudes add, so where two fronts cross the crossing is brighter
        // than either. Contributions are summed into a scratch buffer for this
        // frame only, then folded into the persistent brightness -- summing
        // straight into edgeLit would let a single slow ring saturate itself.
        for i in rippleTouched { rippleAccum[Int(i)] = 0 }
        rippleTouched.removeAll(keepingCapacity: true)

        for rip in ripples {
            let cx = rip.center.x, cy = rip.center.y
            let rMin = max(0, rip.radius - halfBand)
            let rMax = rip.radius + halfBand
            let rMinSq = rMin * rMin, rMaxSq = rMax * rMax
            let slice = rip.buckets.range(lo: rMin, hi: rMax)
            for b in slice {
                let lo = Int(rip.buckets.start[b]), hi = Int(rip.buckets.start[b + 1])
                for k in lo..<hi {
                    let i = Int(rip.buckets.edges[k])
                    let dx = edgeMidX[i] - cx
                    let dy = edgeMidY[i] - cy
                    let distSq = dx * dx + dy * dy
                    if distSq < rMinSq || distSq > rMaxSq { continue }
                    let dist = sqrt(distSq)
                    let ringDist = (dist - rip.radius) / halfBand      // -1...1 across the band
                    // A real ripple is a crest with troughs either side, not a
                    // blob of brightness. Carrying the sign is what lets two
                    // fronts cancel as well as reinforce.
                    let envelope = 1.0 - abs(ringDist)
                    let signed = cos(ringDist * .pi) * envelope
                    if rippleAccum[i] == 0 { rippleTouched.append(Int32(i)) }
                    rippleAccum[i] += signed
                }
            }
        }

        // A single crest is deliberately kept well below full brightness, so
        // that two crests meeting have somewhere to go. Without that headroom
        // the sum just clipped and interference was invisible.
        let singleCrestPeak: CGFloat = 0.58
        for idx in rippleTouched {
            let i = Int(idx)
            let combined = min(abs(rippleAccum[i]) * singleCrestPeak, 1.0)
            if combined > edgeLit[i] {
                edgeLit[i] = combined
                markLit(i)
            }
        }
    }

    // MARK: - Terrain

    /// Reveal the isometric relief the generator already built, by sweeping a
    /// band of heights through it. Each edge knows which block height it came
    /// from; edges near the current level glow.
    private func tickTerrain(dt: CGFloat) {
        guard !terrainKey.isEmpty else { return }
        let lo = terrainKeyRange.lowerBound, hi = terrainKeyRange.upperBound
        let band: CGFloat = 0.7
        terrainLevel += dt * 1.1
        if terrainLevel > hi + band { terrainLevel = lo - band }

        // Only the buckets the band crosses, so this costs the width of the
        // sweep rather than the whole grid.
        for b in terrainBuckets.range(lo: terrainLevel - band, hi: terrainLevel + band) {
            let s0 = Int(terrainBuckets.start[b]), s1 = Int(terrainBuckets.start[b + 1])
            for k in s0..<s1 {
                let i = Int(terrainBuckets.edges[k])
                let d = abs(terrainKey[i] - terrainLevel)
                if d < band {
                    let intensity = 1.0 - d / band
                    if intensity > edgeLit[i] { edgeLit[i] = intensity; markLit(i) }
                }
            }
        }
    }

    // MARK: - Field modes

    /// Smooth value noise on the coarse lattice. One hash per cell per frame,
    /// then a bilinear read per edge, instead of noise per edge.
    private func updateFieldLattice(scaleX: CGFloat, scaleY: CGFloat, t: CGFloat) {
        @inline(__always) func hash(_ x: Int, _ y: Int, _ z: Int) -> CGFloat {
            var h = UInt64(bitPattern: Int64(x &* 374761393 &+ y &* 668265263 &+ z &* 2147483647))
            h = (h ^ (h >> 13)) &* 1274126177
            h = h ^ (h >> 16)
            return CGFloat(h & 0xFFFF) / 65535.0
        }
        @inline(__always) func smooth(_ a: CGFloat) -> CGFloat { a * a * (3 - 2 * a) }
        @inline(__always) func noise(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGFloat {
            let xi = Int(floor(x)), yi = Int(floor(y)), zi = Int(floor(z))
            let fx = smooth(x - floor(x)), fy = smooth(y - floor(y)), fz = smooth(z - floor(z))
            func lerp(_ a: CGFloat, _ b: CGFloat, _ f: CGFloat) -> CGFloat { a + (b - a) * f }
            let c00 = lerp(hash(xi, yi, zi),         hash(xi + 1, yi, zi),         fx)
            let c10 = lerp(hash(xi, yi + 1, zi),     hash(xi + 1, yi + 1, zi),     fx)
            let c01 = lerp(hash(xi, yi, zi + 1),     hash(xi + 1, yi, zi + 1),     fx)
            let c11 = lerp(hash(xi, yi + 1, zi + 1), hash(xi + 1, yi + 1, zi + 1), fx)
            return lerp(lerp(c00, c10, fy), lerp(c01, c11, fy), fz)
        }
        for gy in 0..<fieldRows {
            for gx in 0..<fieldCols {
                fieldValues[gy * fieldCols + gx] =
                    noise(CGFloat(gx) * scaleX, CGFloat(gy) * scaleY, t)
            }
        }
    }

    @inline(__always)
    private func sampleField(_ i: Int) -> CGFloat {
        let base = Int(edgeCellIndex[i])
        let w = edgeCellWeights[i]
        return fieldValues[base] * CGFloat(w.x)
             + fieldValues[base + 1] * CGFloat(w.y)
             + fieldValues[base + fieldCols] * CGFloat(w.z)
             + fieldValues[base + fieldCols + 1] * CGFloat(w.w)
    }

    /// Slow organic drift: a low-frequency noise field wandering over the grid.
    private func tickNoise(dt: CGFloat) {
        fieldTime += dt * 0.20
        updateFieldLattice(scaleX: 0.16, scaleY: 0.16, t: fieldTime)
        for i in 0..<edgeLit.count {
            let v = sampleField(i)
            // Only the crests light, so the grid stays mostly dark.
            if v > 0.78 {
                let intensity = min((v - 0.78) / 0.16, 1.0)
                if intensity > edgeLit[i] { edgeLit[i] = intensity; markLit(i) }
            }
        }
    }

    /// A slowly rotating travelling grating, with the noise field breaking up
    /// the regularity so it does not read as a scanline.
    private func tickFlow(dt: CGFloat) {
        flowAngle += dt * 0.06
        fieldTime += dt * 0.10
        updateFieldLattice(scaleX: 0.10, scaleY: 0.10, t: fieldTime)
        let dx = cos(flowAngle), dy = sin(flowAngle)
        let wavelength: CGFloat = 260
        let phase = fieldTime * 6.0
        let table = Self.sineTable
        let invWavelength = 1.0 / wavelength
        for i in 0..<edgeLit.count {
            let proj = (edgeMidX[i] * dx + edgeMidY[i] * dy) * invWavelength + phase
            let idx = Int((proj - proj.rounded(.down)) * 4096) & 4095
            let band = table[idx]
            // Only the crest, not the whole positive half. Keeps the grid
            // mostly dark and keeps the lit set small enough to be cheap.
            // A field mode covers the whole screen, so the crest has to be
            // narrow or most of the grid ends up lit at once -- which is both
            // expensive and much busier than this animation should look.
            guard band > 0.86 else { continue }
            let crest = (band - 0.86) / 0.14
            let intensity = crest * (0.35 + 0.65 * sampleField(i))
            if intensity > edgeLit[i] { edgeLit[i] = intensity; markLit(i) }
        }
    }

    // MARK: - Wave field (physics)

    /// A real wave equation solved on the grid graph. Each node carries an
    /// amplitude and its previous amplitude; every frame it is pulled toward
    /// the average of its neighbours. Interference, reflection off the edge of
    /// the grid and standing waves all fall out of this rather than being
    /// special-cased.
    private func tickWaveField(dt: CGFloat) {
        guard nodeCount > 0 else { return }

        waveFieldImpulseTimer -= dt
        if waveFieldImpulseTimer <= 0 {
            waveFieldImpulseTimer = CGFloat.random(in: 2.2...4.5, using: &rng)
            let n = Int.random(in: 0..<nodeCount, using: &rng)
            // A strong, local strike so the front stays legible as it expands.
            nodeU[n] += 22.0
        }

        let c2: CGFloat = 0.34          // below the stability limit for this stencil
        // Enough loss that a strike dies away before the next, so the grid
        // shows expanding fronts rather than a permanent shimmer.
        let damping: CGFloat = 0.985
        var next = nodeUPrev             // reuse the buffer we are about to overwrite
        for i in 0..<nodeCount {
            let lo = Int(nodeAdjStart[i]), hi = Int(nodeAdjStart[i + 1])
            guard hi > lo else { next[i] = 0; continue }
            var sum: CGFloat = 0
            for k in lo..<hi { sum += nodeU[Int(nodeAdjList[k])] }
            let laplacian = sum / CGFloat(hi - lo) - nodeU[i]
            next[i] = (2 * nodeU[i] - nodeUPrev[i] + c2 * laplacian) * damping
        }
        nodeUPrev = nodeU
        nodeU = next

        // Brightness is the displacement magnitude across each edge.
        for i in 0..<edgeLit.count {
            let a = nodeU[Int(edgeNodeAIdx[i])]
            let b = nodeU[Int(edgeNodeBIdx[i])]
            let raw = abs(a + b) * 0.5
            guard raw > 0.06 else { continue }
            let amp = min((raw - 0.06) * 2.2, 1.0)
            if amp > edgeLit[i] { edgeLit[i] = amp; markLit(i) }
        }
    }

    private func fadeEdges(dt: CGFloat, now: CFTimeInterval,
                           decayPerSecond: CGFloat = 0.68, removeThreshold: CGFloat = 0.005) {
        let decayFactor = pow(decayPerSecond, dt)
        let logoDecayFactor = pow(0.82, dt)

        // Track per-logo completion and reset
        for i in 0..<perLogoEdges.count {
            if logoCompletedAt[i] == nil {
                // Check if logo just got fully lit
                let allLit = perLogoEdgeIdx[i].allSatisfy { edgeLit[Int($0)] > 0.3 }
                if allLit {
                    logoCompletedAt[i] = now
                    logoEverCompleted.insert(i)
                }
            } else {
                // Check if logo has fully faded out — reset so it can be re-filled
                let allDark = perLogoEdgeIdx[i].allSatisfy { edgeLit[Int($0)] < 0.01 }
                if allDark {
                    logoCompletedAt[i] = nil
                }
            }
        }

        // Iterate the dense lit list backwards so an edge can be removed by
        // swapping in the last element without disturbing the walk.
        var k = litList.count - 1
        while k >= 0 {
            let i = Int(litList[k])
            k -= 1
            if edgeWalker[i] >= 0 { continue }
            let current = edgeLit[i]

            if edgeIsLogo[i] {
                if current > 0.005 {
                    let logoIdx = Int(edgeLogoIndex[i])
                    if logoIdx >= 0, let completedAt = logoCompletedAt[logoIdx] {
                        let elapsed = now - completedAt
                        if movementType == .walkers || movementType == .random {
                            // Walker mode: hold at 0.5 for 5 seconds, then fade to zero
                            if elapsed < 5.0 {
                                if current > 0.5 {
                                    edgeLit[i] = max(0.5, current * decayFactor)
                                }
                            } else {
                                edgeLit[i] = current * logoDecayFactor
                            }
                        } else {
                            // Wave/ripple: fade immediately
                            edgeLit[i] = current * logoDecayFactor
                        }
                    } else {
                        // Logo not yet complete — hold at 0.5
                        if current > 0.5 {
                            edgeLit[i] = max(0.5, current * decayFactor)
                        }
                    }
                } else if current > 0 {
                    edgeLit[i] = 0
                    clearLit(i)
                    // Reset logo completion so it can be re-lit
                    let logoIdx = Int(edgeLogoIndex[i])
                    if logoIdx >= 0 { logoCompletedAt[logoIdx] = nil }
                }
            } else {
                if current > removeThreshold {
                    edgeLit[i] = current * decayFactor
                } else {
                    edgeLit[i] = 0
                    clearLit(i)
                }
            }
        }
    }

    // MARK: - Frame Output

    /// Emit the segments a renderer should draw this frame.
    /// Mirrors the original `draw(_:)` rules exactly:
    ///  - a lit edge draws A→B at brightness `lit` (skipped below 0.01)
    ///  - an edge a walker is currently on draws from the walker's entry node
    ///    to its current position at full brightness, regardless of `lit`
    func fill(frame: inout IsometricFrame) {
        frame.generation = generation
        frame.instances.removeAll(keepingCapacity: true)

        for slot in 0..<litList.count {
            let idx = Int(litList[slot])
            if edgeWalker[idx] >= 0 {
                let edge = activeEdgeArray[idx]
                if let (progress, fromNode) = walkerActiveEdges[edge] {
                    appendWalkerInstances(into: &frame, edgeIdx: idx, edge: edge,
                                          progress: progress, fromNode: fromNode)
                }
            } else {
                let l = edgeLit[idx]
                if l < 0.01 { continue }
                frame.instances.append(IsometricInstance(edge: UInt32(idx),
                                                         lit: Float(l) * edgeVignette[idx],
                                                         t0: 0, t1: 1))
            }
        }

        // Walker edges that are not in the lit list yet.
        for (edge, (progress, fromNode)) in walkerActiveEdges {
            guard let idx = edgeIndex[edge], litSlot[idx] < 0 else { continue }
            appendWalkerInstances(into: &frame, edgeIdx: idx, edge: edge,
                                  progress: progress, fromNode: fromNode)
        }

        // Emit in a fixed order. Both renderers blend source-over, so draw
        // order is visible where segments cross, and the lit list's order
        // depends on insertion and removal history.
        frame.instances.sort {
            $0.edge != $1.edge ? $0.edge < $1.edge : $0.t0 < $1.t0
        }
    }

    /// Sub-segments per walker trail, and how the brightness ramps behind the
    /// head. A walker used to emit its whole traversed range at one flat
    /// brightness, which made the per-edge decay behind it read as a staircase.
    private let walkerTrailSteps = 6
    private let walkerTrailTail: Float = 0.55
    private var walkerTrailLength: Float { Float(gridSpacing) }

    /// Emit a walker's traversed range as `walkerTrailSteps` collinear pieces,
    /// each at a constant brightness sampled at its own midpoint. The gradient
    /// lives in the data rather than in a shader so the Core Graphics
    /// reference draws exactly the same thing and the pixel comparison keeps
    /// working -- Core Graphics cannot stroke a gradient without clipping,
    /// which does not anti-alias the same way.
    private func appendWalkerInstances(into frame: inout IsometricFrame,
                                       edgeIdx: Int, edge: GridEdge,
                                       progress: CGFloat, fromNode: GridNode) {
        let p = Float(min(max(progress, 0), 1))
        guard p > 0 else { return }
        let v = edgeVignette[edgeIdx]
        let e = edgeEndpoints[edgeIdx]
        let len = hypot(e.z - e.x, e.w - e.y)
        let fromA = (fromNode == edge.a)
        let steps = walkerTrailSteps

        for k in 0..<steps {
            let f0 = Float(k) / Float(steps)
            let f1 = Float(k + 1) / Float(steps)
            // f == 1 is the head, f == 0 the oldest end of this traversal.
            let midF = (f0 + f1) * 0.5
            let behind = (1 - midF) * p * len              // points behind the head
            let ramp = walkerTrailTail + (1 - walkerTrailTail)
                     * max(0, min(1, 1 - behind / walkerTrailLength))
            let t0: Float, t1: Float
            if fromA { t0 = f0 * p;        t1 = f1 * p }
            else     { t0 = 1 - f1 * p;    t1 = 1 - f0 * p }
            frame.instances.append(IsometricInstance(edge: UInt32(edgeIdx),
                                                     lit: ramp * v, t0: t0, t1: t1))
        }
    }
}
