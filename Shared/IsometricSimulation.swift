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
        (movementType == .walkers || movementType == .random) ? 30.0 : 24.0
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
    }
    private var ripples: [Ripple] = []
    private var rippleSpawnTimer: CGFloat = 0.0
    private let rippleSpeed: CGFloat = 55.0
    private let rippleBandWidth: CGFloat = 40.0
    private let rippleSpawnInterval: CGFloat = 6.0

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
        litSlot = Array(repeating: -1, count: n)
        edgeWalker = Array(repeating: -1, count: n)
        edgeIsLogo = Array(repeating: false, count: n)
        edgeLogoIndex = Array(repeating: -1, count: n)
        for (i, edge) in activeEdgeArray.enumerated() where logoEdges.contains(edge) {
            edgeIsLogo[i] = true
            edgeLogoIndex[i] = Int32(edgeToLogoIndex[edge] ?? -1)
        }
        perLogoEdgeIdx = perLogoEdges.map { $0.compactMap { edgeIndex[$0].map(Int32.init) } }

        needsGeneration = false
        log("generate() done")
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
    private func addTerrainEdge(_ a: GridNode, _ b: GridNode, excluded: Set<GridNode>) -> Bool {
        if excluded.contains(a) || excluded.contains(b) { return false }
        return activeEdges.insert(GridEdge(a, b)).inserted
    }

    /// Render the top face (diamond) of a block, skipping edges shared with
    /// same-height neighbors so clusters merge into clean outlines.
    private func renderTopFace(q: Int, hPlusZ: Int, h: Int,
                               hXm1: Int, hXp1: Int, hZm1: Int, hZp1: Int,
                               excluded: Set<GridNode>) -> Int {
        let r = hPlusZ
        let a = GridNode(q: q, r: r)
        let b = GridNode(q: q + 1, r: r)
        let c = GridNode(q: q, r: r + 1)
        let d = GridNode(q: q - 1, r: r + 1)
        var n = 0
        if hZm1 != h { if addTerrainEdge(a, b, excluded: excluded) { n += 1 } }
        if hXp1 != h { if addTerrainEdge(b, c, excluded: excluded) { n += 1 } }
        if hZp1 != h { if addTerrainEdge(c, d, excluded: excluded) { n += 1 } }
        if hXm1 != h { if addTerrainEdge(d, a, excluded: excluded) { n += 1 } }
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
                                          GridNode(q: cq, r: y + z + 1), excluded: excluded) { edgeCount += 1 }
                    }
                }
                if hZp1 != -1 && hZp1 != h {
                    let lo = min(h, hZp1), hi = max(h, hZp1)
                    let cq = q - 1  // corner D between this and z+1 neighbor
                    for y in lo..<hi {
                        if addTerrainEdge(GridNode(q: cq, r: y + z + 1),
                                          GridNode(q: cq, r: y + z + 2), excluded: excluded) { edgeCount += 1 }
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
        case .ripple:
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
        case .ripple:
            tickRipple(dt: CGFloat(dt))
            fadeEdges(dt: CGFloat(dt), now: currentTime, decayPerSecond: 0.30, removeThreshold: 0.03)
        }
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
        }

        // Light up edges whose midpoint projects near the wave front
        let cx = midX, cy = midY
        let halfBand = waveBandWidth / 2.0
        let dx = waveDirection.x, dy = waveDirection.y

        // Index order here is the same canonical order edgeMidpoints was built
        // in, so this is the identical sequence of comparisons -- just without
        // hashing a 32-byte key per edge per frame.
        let pos = wavePosition
        for i in 0..<edgeMidX.count {
            let proj = (edgeMidX[i] - cx) * dx + (edgeMidY[i] - cy) * dy
            let dist = abs(proj - pos)

            if dist < halfBand {
                let intensity = 1.0 - dist / halfBand
                if intensity > edgeLit[i] {
                    edgeLit[i] = intensity
                    markLit(i)
                }
            }
        }
    }

    private func spawnRipple() {
        // Random point in the middle 60% of the screen
        let cx = size.width * CGFloat.random(in: 0.20...0.80, using: &rng)
        let cy = size.height * CGFloat.random(in: 0.20...0.80, using: &rng)
        let center = CGPoint(x: cx, y: cy)

        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                       CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
        let maxR = corners.map { hypot($0.x - cx, $0.y - cy) }.max()! + rippleBandWidth

        ripples.append(Ripple(center: center, radius: 0, maxRadius: maxR))
    }

    private func tickRipple(dt: CGFloat) {
        // Spawn new ripples periodically (max 3 concurrent)
        // Always reset timer at the interval boundary — prevents burst when ripples free up
        rippleSpawnTimer += dt
        if rippleSpawnTimer >= rippleSpawnInterval {
            rippleSpawnTimer = 0
            spawnRipple()
        }

        // Advance all ripples and remove completed ones
        for i in 0..<ripples.count {
            ripples[i].radius += rippleSpeed * dt
        }
        ripples.removeAll { $0.radius > $0.maxRadius }

        guard !ripples.isEmpty else { return }

        // Light up edges for all active ripples using pre-cached midpoints
        let halfBand = rippleBandWidth / 2.0

        // Pre-compute per-ripple constants so they aren't recalculated inside the edge loop
        struct RippleRing {
            let cx: CGFloat, cy: CGFloat, radius: CGFloat, rMinSq: CGFloat, rMaxSq: CGFloat
        }
        let rings: [RippleRing] = ripples.map { rip in
            let rMin = max(0, rip.radius - halfBand)
            let rMax = rip.radius + halfBand
            return RippleRing(cx: rip.center.x, cy: rip.center.y, radius: rip.radius,
                              rMinSq: rMin * rMin, rMaxSq: rMax * rMax)
        }

        for i in 0..<edgeMidX.count {
            let mx = edgeMidX[i], my = edgeMidY[i]
            var maxIntensity: CGFloat = 0
            for ring in rings {
                let dx = mx - ring.cx
                let dy = my - ring.cy
                // Use squared distance for quick reject before expensive sqrt
                let distSq = dx * dx + dy * dy
                if distSq < ring.rMinSq || distSq > ring.rMaxSq { continue }
                let dist = sqrt(distSq)
                let ringDist = abs(dist - ring.radius)
                let intensity = 1.0 - ringDist / halfBand
                if intensity > maxIntensity { maxIntensity = intensity }
            }

            if maxIntensity > 0, maxIntensity > edgeLit[i] {
                edgeLit[i] = maxIntensity
                markLit(i)
            }
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
