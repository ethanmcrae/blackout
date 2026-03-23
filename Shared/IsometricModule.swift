import Cocoa

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

// MARK: - Generative Background View

final class IsometricModule: NSView, AnimationModule {

    // MARK: Configuration

    private let gridSpacing: CGFloat = 32.0

    // Colors (RGB for interpolation)
    private let baseR: CGFloat = 0.0
    private let baseG: CGFloat = 0.0
    private let baseB: CGFloat = 0.0

    private let accentR: CGFloat
    private let accentG: CGFloat
    private let accentB: CGFloat
    private let lightMode: Bool
    private let movementType: MovementType
    var showFPS: Bool = false

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

    private let logoBaseR: CGFloat = 0.0
    private let logoBaseG: CGFloat = 0.0
    private let logoBaseB: CGFloat = 0.0

    private let patternLineWidth: CGFloat = 1.2
    private let logoLineWidth: CGFloat = 1.2

    // MARK: Grid State

    private var activeEdges: Set<GridEdge> = []
    private var logoEdges: Set<GridEdge> = []
    private var centerLogoEdges: Set<GridEdge> = []
    /// Only edges with lit > 0 — avoids iterating all 17k+ edges every frame for fading
    private var litEdges: Set<GridEdge> = []
    /// Pre-cached screen positions for each edge endpoints
    private var edgeScreenPos: [GridEdge: (CGPoint, CGPoint)] = [:]
    /// Pre-cached midpoints for wave/ripple (avoids recalc every frame)
    private var edgeMidpoints: [(GridEdge, CGFloat, CGFloat)] = []  // (edge, midX, midY)
    /// Cached array of all edges for random respawn
    private var activeEdgeArray: [GridEdge] = []
    /// Maps each logo edge to its logo index (0=center, 1=left, etc.)
    private var edgeToLogoIndex: [GridEdge: Int] = [:]
    /// Edges per logo
    private var perLogoEdges: [[GridEdge]] = []
    /// Timestamp when each logo was fully lit (for delayed fade in walker mode)
    private var logoCompletedAt: [Int: CFTimeInterval] = [:]
    /// Logos that have been fully completed at least once — walkers won't revisit
    private var logoEverCompleted: Set<Int> = []
    private var edgeLitAmount: [GridEdge: CGFloat] = [:]
    private var cachedPositions: [GridNode: CGPoint] = [:]

    // Adjacency for fast wavefront traversal
    private var adjacency: [GridNode: [GridEdge]] = [:]

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

    private var animationTimer: Timer?
    private var lastTime: CFTimeInterval = 0
    private var tickCount = 0

    // FPS tracking
    private var fpsFrameCount = 0
    private var fpsLastTime: CFTimeInterval = 0
    private var currentFPS: Int = 0

    private var needsGeneration = true

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

    // MARK: Lifecycle

    /// Protocol-required init: creates module from AnimationConfig.
    convenience required init(frame: NSRect, config: AnimationConfig) {
        self.init(frame: frame,
                  accentR: config.accentR, accentG: config.accentG, accentB: config.accentB,
                  lightMode: config.lightMode, movementType: config.movementType)
        self.showFPS = config.showFPS
    }

    init(frame: NSRect, accentR: CGFloat, accentG: CGFloat, accentB: CGFloat,
         lightMode: Bool = false, movementType: MovementType = .walkers) {
        self.accentR = accentR
        self.accentG = accentG
        self.accentB = accentB
        self.lightMode = lightMode
        self.movementType = movementType
        super.init(frame: frame)
        log("init frame: \(frame), lightMode: \(lightMode), movement: \(movementType)")
    }

    override init(frame: NSRect) {
        self.accentR = 0.078; self.accentG = 0.404; self.accentB = 1.0
        self.lightMode = false; self.movementType = .walkers
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        self.accentR = 0.078; self.accentG = 0.404; self.accentB = 1.0
        self.lightMode = false; self.movementType = .walkers
        super.init(coder: coder)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsGeneration = true
    }

    // MARK: - Debug Logging

    private static let logFile: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("blackout-debug.log")
        try? "".write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    private func log(_ msg: String) {
        let line = "\(Date()): [BG] \(msg)\n"
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
        let pt = CGPoint(x: bounds.midX + x, y: bounds.midY + y)
        cachedPositions[node] = pt
        return pt
    }

    // MARK: - Pattern Generation

    func generate() {
        log("generate() bounds: \(bounds)")
        activeEdges.removeAll()
        logoEdges.removeAll()
        centerLogoEdges.removeAll()
        edgeToLogoIndex.removeAll()
        perLogoEdges.removeAll()
        edgeLitAmount.removeAll()
        litEdges.removeAll()
        logoCompletedAt.removeAll()
        logoEverCompleted.removeAll()
        ripples.removeAll()
        edgeScreenPos.removeAll()
        edgeMidpoints.removeAll()
        activeEdgeArray.removeAll()
        cachedPositions.removeAll()
        adjacency.removeAll()
        walkers.removeAll()

        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

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
            let qf = (corner.x - bounds.midX) / (s * 0.866025)
            let rf = (corner.y - bounds.midY) / s - qf * 0.5
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

        // Init all edges as unlit
        for edge in activeEdges {
            edgeLitAmount[edge] = 0.0
        }
        litEdges.removeAll()

        // Pre-cache screen positions for all edges
        edgeScreenPos.removeAll()
        for edge in activeEdges {
            edgeScreenPos[edge] = (position(for: edge.a), position(for: edge.b))
        }

        // Cache edge array and midpoints for random access and wave/ripple
        activeEdgeArray = Array(activeEdges)
        edgeMidpoints.reserveCapacity(activeEdges.count)
        for edge in activeEdges {
            if let (pA, pB) = edgeScreenPos[edge] {
                edgeMidpoints.append((edge, (pA.x + pB.x) * 0.5, (pA.y + pB.y) * 0.5))
            }
        }

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
        let qf = (pixel.x - bounds.midX) / (s * 0.866025)
        let rf = (pixel.y - bounds.midY) / s - qf * 0.5
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
            perLogoEdges.append(Array(newEdges))
            for edge in newEdges {
                edgeToLogoIndex[edge] = idx
            }
        }

        // Center logo (always)
        addLogo(qOffset: 0, rOffset: 0)
        centerLogoEdges = Set(perLogoEdges[0])

        // Scale logo count by screen area. ~5 for a 16" laptop (1728x1117 ≈ 1.93M px²)
        // ~10 for a 34" ultrawide (3440x1440 ≈ 4.95M px²)
        let screenArea = bounds.width * bounds.height
        let baseArea: CGFloat = 1_930_000  // 16" laptop baseline
        let extraLogos = max(3, Int(round(4.0 * screenArea / baseArea)))  // 4 extra at baseline

        // Place extra logos at random screen positions with margin.
        // Each logo spans ~5x6 grid units, so enforce minimum distance between origins.
        let margin: CGFloat = 0.10
        let minDist = gridSpacing * 10  // ~10 grid units apart (logo size + 2 unit gap)
        var placedPixels: [CGPoint] = [CGPoint(x: bounds.midX, y: bounds.midY)]  // center logo

        for _ in 0..<(extraLogos * 3) {  // extra attempts since some will be rejected
            if logoOffsets.count >= extraLogos + 1 { break }  // +1 for center
            let px = CGPoint(
                x: bounds.width * CGFloat.random(in: margin...(1.0 - margin)),
                y: bounds.height * CGFloat.random(in: margin...(1.0 - margin))
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

    /// Render right wall as ONLY vertical drop lines.
    private func renderRightWall(q: Int, z: Int, fromY: Int, toY: Int, excluded: Set<GridNode>) -> Int {
        var n = 0
        for y in fromY..<toY {
            if addTerrainEdge(GridNode(q: q + 1, r: y + z),
                              GridNode(q: q + 1, r: y + z + 1), excluded: excluded) { n += 1 }
        }
        for y in fromY..<toY {
            if addTerrainEdge(GridNode(q: q, r: y + z + 1),
                              GridNode(q: q, r: y + z + 2), excluded: excluded) { n += 1 }
        }
        return n
    }

    /// Render left wall as ONLY vertical drop lines.
    private func renderLeftWall(q: Int, z: Int, fromY: Int, toY: Int, excluded: Set<GridNode>) -> Int {
        var n = 0
        for y in fromY..<toY {
            if addTerrainEdge(GridNode(q: q - 1, r: y + z + 1),
                              GridNode(q: q - 1, r: y + z + 2), excluded: excluded) { n += 1 }
        }
        for y in fromY..<toY {
            if addTerrainEdge(GridNode(q: q, r: y + z + 1),
                              GridNode(q: q, r: y + z + 2), excluded: excluded) { n += 1 }
        }
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
        unassigned.shuffle()

        for (seedX, seedZ) in unassigned {
            if assigned[seedX][seedZ] { continue }

            let targetSize = Int.random(in: 2...3)
            var cluster: [(Int, Int)] = [(seedX, seedZ)]
            assigned[seedX][seedZ] = true

            var frontier = [(seedX, seedZ)]
            while cluster.count < targetSize && !frontier.isEmpty {
                let fi = Int.random(in: 0..<frontier.count)
                let (fx, fz) = frontier[fi]

                var grew = false
                for dir in growDirs.shuffled() {
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
            let h = candidates.randomElement() ?? Int.random(in: 1...3)
            for (cx, cz) in cluster {
                heights[cx][cz] = h
            }
        }
    }

    // MARK: - Adjacency

    private func buildAdjacency() {
        adjacency.removeAll()
        for edge in activeEdges {
            adjacency[edge.a, default: []].append(edge)
            adjacency[edge.b, default: []].append(edge)
        }
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
            speed: walkerSpeed + Double.random(in: -1.5...1.5)
        ))
        walkerActiveEdges[edge] = (0, fromNode)
    }

    private func spawnWalkers() {
        walkers.removeAll()
        walkerActiveEdges.removeAll()
        guard !activeEdges.isEmpty else { return }

        // Walker 1: start on the center logo specifically
        if let logoStart = centerLogoEdges.randomElement() ?? logoEdges.randomElement() {
            spawnWalker(on: logoStart)
        }

        // Walkers 2-7: spread across 6 screen regions
        let thirdX = bounds.width / 3
        let halfY = bounds.height / 2
        let regions: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0, thirdX, halfY, bounds.height),              // top-left
            (thirdX, thirdX * 2, halfY, bounds.height),     // top-center
            (thirdX * 2, bounds.width, halfY, bounds.height), // top-right
            (0, thirdX, 0, halfY),                          // bottom-left
            (thirdX, thirdX * 2, 0, halfY),                 // bottom-center
            (thirdX * 2, bounds.width, 0, halfY),           // bottom-right
        ]

        for (xMin, xMax, yMin, yMax) in regions {
            let candidates = activeEdges.filter { edge in
                if logoEdges.contains(edge) { return false }
                let p = position(for: edge.a)
                return p.x >= xMin && p.x < xMax && p.y >= yMin && p.y < yMax
            }
            if let pick = candidates.randomElement() {
                spawnWalker(on: pick)
            }
        }

        log("spawned \(walkers.count) walkers (1 logo + \(walkers.count - 1) quadrants)")
    }

    /// Check if a grid node's screen position is within visible bounds.
    private func isOnScreen(_ node: GridNode) -> Bool {
        let p = position(for: node)
        return p.x >= -gridSpacing && p.x <= bounds.width + gridSpacing &&
               p.y >= -gridSpacing && p.y <= bounds.height + gridSpacing
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
                if (edgeLitAmount[edge] ?? 0) < 0.3 {
                    unlitLogo.append(edge)
                } else {
                    litLogo.append(edge)
                }
            }
        }

        // If there are unlit logo edges adjacent, take one
        if let pick = unlitLogo.randomElement() { return pick }

        // If on a logo node, stay to finish filling it if it has unlit edges
        if !litLogo.isEmpty {
            if let sampleLogoEdge = (unlitLogo + litLogo).first,
               let logoIdx = edgeToLogoIndex[sampleLogoEdge] {
                let thisLogoHasUnlit = perLogoEdges[logoIdx].contains {
                    (edgeLitAmount[$0] ?? 0) < 0.3
                }
                if thisLogoHasUnlit {
                    if let pick = litLogo.randomElement() { return pick }
                }
            }
        }

        // For the center logo walker on first pass, jump to unlit center logo edges
        if isLogoWalker {
            let unlitCenter = centerLogoEdges.filter { (edgeLitAmount[$0] ?? 0) < 0.3 }
            if let pick = unlitCenter.randomElement() { return pick }
        }

        // Normal exploration: prefer unlit > dim > bright
        var unlit: [GridEdge] = []
        var dim: [GridEdge] = []
        var bright: [GridEdge] = []

        for edge in validEdges {
            let lit = edgeLitAmount[edge] ?? 0.0
            if lit < 0.05 {
                unlit.append(edge)
            } else if lit < 0.4 {
                dim.append(edge)
            } else {
                bright.append(edge)
            }
        }

        if let pick = unlit.randomElement() { return pick }
        if let pick = dim.randomElement() { return pick }
        if let pick = bright.randomElement() { return pick }
        return previous  // dead end, reverse
    }

    /// Check if center logo has ever been fully lit (permanent — no re-visiting).
    private var logoFullyLit: Bool {
        logoEverCompleted.contains(0)  // logo index 0 = center
    }

    // MARK: - Animation

    private var hasSetup = false

    private func setupIfNeeded() {
        guard !hasSetup else { return }
        hasSetup = true

        log("setup, bounds: \(bounds)")
        if needsGeneration {
            generate()
        }

        // Scale walker count by screen area: ~7 for 16" laptop, ~14 for 34" ultrawide
        let screenArea = bounds.width * bounds.height
        let baseArea: CGFloat = 1_930_000
        walkerCount = max(5, Int(round(7.0 * screenArea / baseArea)))

        lastTime = CACurrentMediaTime()

        switch movementType {
        case .walkers, .random:
            spawnWalkers()
        case .ripple:
            ripples.removeAll()
            rippleSpawnTimer = 0
            spawnRipple()
        case .wave:
            let angle = CGFloat.random(in: 0...(2 * .pi))
            waveDirection = CGPoint(x: cos(angle), y: sin(angle))
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0),
                           CGPoint(x: bounds.width, y: bounds.height), CGPoint(x: 0, y: bounds.height)]
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
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

    func startAnimation() {
        setupIfNeeded()
        guard animationTimer == nil else { return }
        let fps: Double = (movementType == .walkers || movementType == .random) ? 30.0 : 20.0
        let timer = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            self?.tick(CACurrentMediaTime())
        }
        // Add to .common mode so it fires in screen savers and modal panels too
        RunLoop.current.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        hasSetup = false
    }

    /// For screen saver: host calls this each frame instead of using internal timer.
    func externalTick() {
        setupIfNeeded()
        tick(CACurrentMediaTime())
    }

    private func tick(_ currentTime: CFTimeInterval) {
        if lastTime == 0 { lastTime = currentTime }
        let dt = min(currentTime - lastTime, 0.05)
        lastTime = currentTime

        switch movementType {
        case .walkers, .random:
            tickWalkers(dt: CGFloat(dt))
            fadeEdges(dt: CGFloat(dt), decayPerSecond: 0.68)
        case .wave:
            tickWave(dt: CGFloat(dt))
            fadeEdges(dt: CGFloat(dt), decayPerSecond: 0.30, removeThreshold: 0.03)
        case .ripple:
            tickRipple(dt: CGFloat(dt))
            fadeEdges(dt: CGFloat(dt), decayPerSecond: 0.30, removeThreshold: 0.03)
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
        needsDisplay = true
    }

    private func tickWalkers(dt: CGFloat) {
        for i in 0..<walkers.count {
            walkers[i].progress += CGFloat(walkers[i].speed) * dt

            if let edge = walkers[i].currentEdge {
                walkerActiveEdges[edge] = (min(walkers[i].progress, 1.0), walkers[i].fromNode)
            }

            while walkers[i].progress >= 1.0 {
                walkers[i].progress -= 1.0

                if let edge = walkers[i].currentEdge {
                    walkerActiveEdges.removeValue(forKey: edge)
                    edgeLitAmount[edge] = 1.0
                    litEdges.insert(edge)
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
                    walkerActiveEdges[nextEdge] = (walkers[i].progress, arrivalNode)
                } else {
                    let startEdge = activeEdgeArray[Int.random(in: 0..<activeEdgeArray.count)]
                    let from = Bool.random() ? startEdge.a : startEdge.b
                    let to = (startEdge.a == from) ? startEdge.b : startEdge.a
                    walkers[i].fromNode = from
                    walkers[i].toNode = to
                    walkers[i].currentEdge = startEdge
                    walkers[i].previousEdge = nil
                    walkers[i].progress = 0
                    walkerActiveEdges[startEdge] = (0, from)
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
            let angle = CGFloat.random(in: 0...(2 * .pi))
            waveDirection = CGPoint(x: cos(angle), y: sin(angle))
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0),
                           CGPoint(x: bounds.width, y: bounds.height), CGPoint(x: 0, y: bounds.height)]
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            var maxProj: CGFloat = 0
            for c in corners {
                let dx = c.x - center.x, dy = c.y - center.y
                maxProj = max(maxProj, abs(dx * waveDirection.x + dy * waveDirection.y))
            }
            waveMaxDist = maxProj + waveBandWidth
            wavePosition = -waveMaxDist
        }

        // Light up edges whose midpoint projects near the wave front
        let cx = bounds.midX, cy = bounds.midY
        let halfBand = waveBandWidth / 2.0
        let dx = waveDirection.x, dy = waveDirection.y

        for (edge, midX, midY) in edgeMidpoints {
            let proj = (midX - cx) * dx + (midY - cy) * dy
            let dist = abs(proj - wavePosition)

            if dist < halfBand {
                let intensity = 1.0 - dist / halfBand
                let current = edgeLitAmount[edge] ?? 0.0
                if intensity > current {
                    edgeLitAmount[edge] = intensity
                    litEdges.insert(edge)
                }
            }
        }
    }

    private func spawnRipple() {
        // Random point in the middle 60% of the screen
        let cx = bounds.width * CGFloat.random(in: 0.20...0.80)
        let cy = bounds.height * CGFloat.random(in: 0.20...0.80)
        let center = CGPoint(x: cx, y: cy)

        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0),
                       CGPoint(x: bounds.width, y: bounds.height), CGPoint(x: 0, y: bounds.height)]
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

        for (edge, midX, midY) in edgeMidpoints {
            var maxIntensity: CGFloat = 0
            for ring in rings {
                let dx = midX - ring.cx
                let dy = midY - ring.cy
                // Use squared distance for quick reject before expensive sqrt
                let distSq = dx * dx + dy * dy
                if distSq < ring.rMinSq || distSq > ring.rMaxSq { continue }
                let dist = sqrt(distSq)
                let ringDist = abs(dist - ring.radius)
                let intensity = 1.0 - ringDist / halfBand
                if intensity > maxIntensity { maxIntensity = intensity }
            }

            if maxIntensity > 0 {
                let current = edgeLitAmount[edge] ?? 0.0
                if maxIntensity > current {
                    edgeLitAmount[edge] = maxIntensity
                    litEdges.insert(edge)
                }
            }
        }
    }

    private func fadeEdges(dt: CGFloat, decayPerSecond: CGFloat = 0.68, removeThreshold: CGFloat = 0.005) {
        let decayFactor = pow(decayPerSecond, dt)
        let logoDecayFactor = pow(0.82, dt)
        let now = CACurrentMediaTime()

        // Track per-logo completion and reset
        for i in 0..<perLogoEdges.count {
            if logoCompletedAt[i] == nil {
                // Check if logo just got fully lit
                let allLit = perLogoEdges[i].allSatisfy { (edgeLitAmount[$0] ?? 0) > 0.3 }
                if allLit {
                    logoCompletedAt[i] = now
                    logoEverCompleted.insert(i)
                }
            } else {
                // Check if logo has fully faded out — reset so it can be re-filled
                let allDark = perLogoEdges[i].allSatisfy { (edgeLitAmount[$0] ?? 0) < 0.01 }
                if allDark {
                    logoCompletedAt[i] = nil
                }
            }
        }

        var toRemove: [GridEdge] = []
        for edge in litEdges {
            if walkerActiveEdges[edge] != nil { continue }
            let current = edgeLitAmount[edge] ?? 0

            if logoEdges.contains(edge) {
                if current > 0.005 {
                    if let logoIdx = edgeToLogoIndex[edge],
                       let completedAt = logoCompletedAt[logoIdx] {
                        let elapsed = now - completedAt
                        if movementType == .walkers || movementType == .random {
                            // Walker mode: hold at 0.5 for 5 seconds, then fade to zero
                            if elapsed < 5.0 {
                                if current > 0.5 {
                                    edgeLitAmount[edge] = max(0.5, current * decayFactor)
                                }
                            } else {
                                edgeLitAmount[edge] = current * logoDecayFactor
                            }
                        } else {
                            // Wave/ripple: fade immediately
                            edgeLitAmount[edge] = current * logoDecayFactor
                        }
                    } else {
                        // Logo not yet complete — hold at 0.5
                        if current > 0.5 {
                            edgeLitAmount[edge] = max(0.5, current * decayFactor)
                        }
                    }
                } else if current > 0 {
                    edgeLitAmount[edge] = 0
                    toRemove.append(edge)
                    // Reset logo completion so it can be re-lit
                    if let logoIdx = edgeToLogoIndex[edge] {
                        logoCompletedAt[logoIdx] = nil
                    }
                }
            } else {
                if current > removeThreshold {
                    edgeLitAmount[edge] = current * decayFactor
                } else {
                    edgeLitAmount[edge] = 0
                    toRemove.append(edge)
                }
            }
        }
        for edge in toRemove {
            litEdges.remove(edge)
        }
    }

    // MARK: - Drawing

    /// Number of brightness buckets for batching — more = smoother gradient, fewer = faster
    private let colorBuckets = 20

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(lightMode ? NSColor.white.cgColor : NSColor.black.cgColor)
        ctx.fill(bounds)

        if needsGeneration {
            generate()
        }

        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)

        // For wave/ripple: 3 alpha buckets (bright/medium/dim) = 3 draw calls
        // For walkers: per-edge drawing (fewer lit edges, needs smooth color)
        let useSimpleDraw = (movementType == .wave || movementType == .ripple)

        if useSimpleDraw {
            let numBuckets = 5
            let paths = (0..<numBuckets).map { _ in CGMutablePath() }

            for edge in litEdges {
                guard let (pA, pB) = edgeScreenPos[edge] else { continue }
                let lit = edgeLitAmount[edge] ?? 0.0
                if lit < 0.01 { continue }
                let bucket = min(Int(lit * CGFloat(numBuckets)), numBuckets - 1)
                paths[bucket].move(to: pA)
                paths[bucket].addLine(to: pB)
            }

            // Disable anti-aliasing: 1.2px lines at 2x Retina look identical either way,
            // but aliased rasterization is substantially faster in software compositing contexts.
            ctx.setShouldAntialias(false)
            ctx.setLineWidth(patternLineWidth)
            for bucket in 0..<numBuckets {
                if paths[bucket].isEmpty { continue }
                let alpha = (CGFloat(bucket) + 0.5) / CGFloat(numBuckets)
                ctx.setStrokeColor(CGColor(red: accentR, green: accentG, blue: accentB, alpha: alpha))
                ctx.addPath(paths[bucket])
                ctx.strokePath()
            }
            ctx.setShouldAntialias(true)
        } else {
            // Walker mode: per-edge with color fading
            ctx.setLineWidth(patternLineWidth)
            for edge in litEdges {
                guard let (pA, pB) = edgeScreenPos[edge] else { continue }

                if let (progress, fromNode) = walkerActiveEdges[edge] {
                    let pFrom = (fromNode == edge.a) ? pA : pB
                    let pTo = (fromNode == edge.a) ? pB : pA
                    let walkerPos = CGPoint(
                        x: pFrom.x + (pTo.x - pFrom.x) * progress,
                        y: pFrom.y + (pTo.y - pFrom.y) * progress
                    )
                    ctx.setStrokeColor(CGColor(red: accentR, green: accentG, blue: accentB, alpha: 1.0))
                    ctx.move(to: pFrom)
                    ctx.addLine(to: walkerPos)
                    ctx.strokePath()
                } else {
                    let lit = edgeLitAmount[edge] ?? 0.0
                    if lit < 0.01 { continue }
                    let r, g, b: CGFloat
                    if lightMode {
                        r = 1.0 + (accentR - 1.0) * lit
                        g = 1.0 + (accentG - 1.0) * lit
                        b = 1.0 + (accentB - 1.0) * lit
                    } else {
                        r = accentR * lit
                        g = accentG * lit
                        b = accentB * lit
                    }
                    ctx.setStrokeColor(CGColor(red: r, green: g, blue: b, alpha: 1.0))
                    ctx.move(to: pA)
                    ctx.addLine(to: pB)
                    ctx.strokePath()
                }
            }

            // Walker active edges not yet in litEdges
            ctx.setStrokeColor(CGColor(red: accentR, green: accentG, blue: accentB, alpha: 1.0))
            for (edge, (progress, fromNode)) in walkerActiveEdges {
                if litEdges.contains(edge) { continue }
                guard let (pA, pB) = edgeScreenPos[edge] else { continue }
                let pFrom = (fromNode == edge.a) ? pA : pB
                let pTo = (fromNode == edge.a) ? pB : pA
                let walkerPos = CGPoint(
                    x: pFrom.x + (pTo.x - pFrom.x) * progress,
                    y: pFrom.y + (pTo.y - pFrom.y) * progress
                )
                ctx.move(to: pFrom)
                ctx.addLine(to: walkerPos)
                ctx.strokePath()
            }
        }

        // FPS overlay
        if showFPS { drawFPS(ctx) }
    }

    // MARK: - FPS Display

    private func drawFPS(_ ctx: CGContext) {
        let text = "\(currentFPS) FPS | \(litEdges.count) lit | \(activeEdges.count) total"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: lightMode ? NSColor.black.withAlphaComponent(0.5) : NSColor.white.withAlphaComponent(0.5)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: 10, y: 10)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Cleanup

    deinit {
        stopAnimation()
    }
}
