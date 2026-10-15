import Foundation

struct BundlingSettings: Sendable {
    var iterations = 30
    var segments = 10
    var k: Float = 0.1
    var compatibilityThreshold: Float = 0.6
    var bundlingDistance: Float = 500.0
    /// Clearance kept between bundled control points and other nodes.
    var nodePadding: Float = 8.0
    /// Lateral gap between edges joining the same two nodes.
    var edgeSpacing: Float = 8.0
    /// Control points closer than this to the line through their neighbours are dropped.
    var simplifyTolerance: Float = 2.0
}

/// Force-directed edge bundling (Holten and van Wijk) that starts from the routes edges already have. Edges attract
/// each other when their angle, length, position and visibility are compatible; control points are subdivided over a
/// coarse-to-fine schedule, pushed out of node rectangles, and edges joining the same nodes are fanned apart afterwards.
/// The result is smoothed and simplified, so edges nothing bundles with come out as plain lines.
///
/// The iteration kernel (spring plus unit attraction towards compatible edges) is the one the Metal path runs, in
/// coordinates scaled so a typical edge is about 100 units long; everything else is shared CPU work.
public final class EdgeBundlingRouter: EdgeRouter {
    public var iterations = 30
    public var segments = 10
    public var k: Float = 0.1
    public var compatibilityThreshold: Float = 0.6
    public var bundlingDistance: Float = 500
    public var nodePadding: Float = 8
    public var edgeSpacing: Float = 8
    public var simplifyTolerance: Float = 2
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    var settings: BundlingSettings {
        BundlingSettings(iterations: iterations, segments: segments, k: k, compatibilityThreshold: compatibilityThreshold, bundlingDistance: bundlingDistance,
                         nodePadding: nodePadding, edgeSpacing: edgeSpacing, simplifyTolerance: simplifyTolerance)
    }
    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = ObstaclePolyline.repair(graph, spacing: 0)
        let edges = graph.edges.filter { $0.source !== $0.target }
        let index = Dictionary(graph.nodes.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var bundler = EdgeBundler(settings, nodes: graph.nodes.map(\.bounds), solid: graph.nodes.map { !$0.isGroup },
            edges: edges.map { .init(source: index[$0.source] ?? -1, target: index[$0.target] ?? -1, from: $0.source.center, to: $0.target.center, path: $0.path) })
        guard bundler.runCPU() else { return }
        for (edge, path) in zip(edges, bundler.paths()) { edge.path = path }
        unroutableEdges = ObstaclePolyline.repair(graph, spacing: 0)
    }
}

struct BundlingEdge: Sendable {
    var source: Int
    var target: Int
    var from: Point
    var to: Point
    var path: [Point]
}

struct EdgeBundler {
    let settings: BundlingSettings
    let nodes: [Rect]
    let solid: [Bool]
    let edges: [BundlingEdge]
    /// Each edge's starting route, endpoints exact: its own path when it still joins its nodes, else a straight line.
    let base: [[Point]]
    let unit: Float
    let origin: Point
    let offsets: [UInt32]
    let compatible: [SIMD2<UInt32>]
    let springs: [Float]
    let schedule: [(segments: Int, iterations: Int)]
    private(set) var points: [[Point]]
    private let tree: QuadTree<Int>
    var maximumDegree: Int { (0..<edges.count).map { Int(offsets[$0 + 1] - offsets[$0]) }.max() ?? 0 }

    init(_ settings: BundlingSettings, nodes: [Rect], solid: [Bool], edges input: [BundlingEdge]) {
        self.settings = settings; self.nodes = nodes; self.solid = solid; edges = input
        base = input.map { e in
            var path = e.path
            let ok = path.count >= 2 && path.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                && e.source >= 0 && e.target >= 0 && nodes[e.source].inflated(by: 1e-5).contains(path[0]) && nodes[e.target].inflated(by: 1e-5).contains(path[path.count - 1])
            if !ok { path = [e.from, e.to] }
            return path
        }
        let chords = base.map { ($0[0], $0[$0.count - 1]) }, lengths = chords.map { ($0.1 - $0.0).length }
        let usable = lengths.filter { $0 > 0.1 }
        unit = usable.isEmpty ? 1 : max(1e-6, usable.reduce(0, +) / Float(usable.count) / 100)
        let all = chords.flatMap { [$0.0, $0.1] }
        origin = all.isEmpty ? .zero : Point(x: (all.map(\.x).min()! + all.map(\.x).max()!) / 2, y: (all.map(\.y).min()! + all.map(\.y).max()!) / 2)
        // Compatibility is decided on the end-to-end chords, so it matches whatever route each edge starts with.
        var lists = Array(repeating: [(Int, Bool)](), count: input.count)
        let mids = chords.map { ($0.0 + $0.1) / 2 }
        for i in input.indices where lengths[i] > 0.1 {
            if i % 16 == 0 && RoutingCompute.isCancelled { break }
            for j in (i + 1)..<max(i + 1, input.count) where lengths[j] > 0.1 && (mids[i] - mids[j]).length <= settings.bundlingDistance {
                let p = chords[i].1 - chords[i].0, q = chords[j].1 - chords[j].0
                let dot = (p.x * q.x + p.y * q.y) / (lengths[i] * lengths[j])
                let average = (lengths[i] + lengths[j]) / 2
                let angle = abs(dot)
                let scale = 2 / (average / min(lengths[i], lengths[j]) + max(lengths[i], lengths[j]) / average)
                let position = average / (average + (mids[i] - mids[j]).length)
                let visibility = min(Self.visibility(chords[i], chords[j]), Self.visibility(chords[j], chords[i]))
                if angle * scale * position * visibility >= settings.compatibilityThreshold {
                    lists[i].append((j, dot < 0)); lists[j].append((i, dot < 0))
                }
            }
        }
        var offsets: [UInt32] = [0], compatible: [SIMD2<UInt32>] = []
        for list in lists { for (j, reversed) in list { compatible.append(SIMD2(UInt32(j), reversed ? 1 : 0)) }; offsets.append(UInt32(compatible.count)) }
        self.offsets = offsets; self.compatible = compatible
        springs = lengths.map { $0 > 0.1 ? min(0.45, settings.k * 3) : 0 }
        let longest = base.map { $0.count - 1 }.max() ?? 1
        var counts: [Int] = []
        if settings.segments > 1 && settings.iterations > 0 && !input.isEmpty {
            counts = [min(settings.segments, max(2, longest))]
            while counts.last! < settings.segments { counts.append(min(settings.segments, counts.last! * 2)) }
        }
        schedule = counts.enumerated().map { c, n in (n, max(1, Int((Double(settings.iterations) * pow(0.7, Double(c))).rounded()))) }
        points = base
        let padded = settings.nodePadding
        let solidBounds = nodes.indices.filter { solid[$0] && nodes[$0].width > 0 && nodes[$0].height > 0 }
        tree = QuadTree<Int>(bounds: (solidBounds.isEmpty ? Rect() : solidBounds.map { nodes[$0] }.dropFirst().reduce(nodes[solidBounds[0]]) { $0.union($1) }).inflated(by: padded + 1))
        for i in solidBounds { tree.insert(bounds: nodes[i].inflated(by: padded), item: i) }
    }
    /// How much of `q`, projected onto `p`'s line, lies around `p`'s midpoint (Holten and van Wijk's visibility).
    private static func visibility(_ p: (Point, Point), _ q: (Point, Point)) -> Float {
        let d = p.1 - p.0, length = d.length, n = d / length
        func along(_ x: Point) -> Float { (x - p.0).x * n.x + (x - p.0).y * n.y }
        let i0 = along(q.0), i1 = along(q.1), span = abs(i1 - i0)
        guard span > 1e-6 else { return 0 }
        return max(0, 1 - 2 * abs(length / 2 - (i0 + i1) / 2) / span)
    }
    var cycleCount: Int { schedule.count }
    func normalised(_ p: Point) -> Point { (p - origin) / unit }
    /// Resamples a route to `n` segments by arc length, keeping its own vertices where they land near a sample.
    private static func resample(_ path: [Point], to n: Int) -> [Point] {
        var along: [Float] = [0]
        for (a, b) in zip(path, path.dropFirst()) { along.append(along.last! + (b - a).length) }
        let total = along.last!
        guard total > 0 else { return Array(repeating: path[0], count: n + 1) }
        // Anchors: vertex -> nearest free sample, in order, so the arc position of every sample stays monotone.
        var anchored: [Int: Float] = [0: 0, n: total], lastIndex = 0
        for v in 1..<max(1, path.count - 1) {
            let k = Int((along[v] / total * Float(n)).rounded())
            if k > lastIndex && k < n { anchored[k] = along[v]; lastIndex = k }
        }
        let keys = anchored.keys.sorted()
        var targets = Array(repeating: Float(0), count: n + 1)
        for (lo, hi) in zip(keys, keys.dropFirst()) {
            for k in lo...hi { targets[k] = anchored[lo]! + (anchored[hi]! - anchored[lo]!) * Float(k - lo) / Float(hi - lo) }
        }
        var segment = 0
        return targets.map { s in
            while segment < path.count - 2 && along[segment + 1] < s { segment += 1 }
            let length = along[segment + 1] - along[segment]
            return length > 0 ? path[segment] + (path[segment + 1] - path[segment]) * min(1, max(0, (s - along[segment]) / length)) : path[segment]
        }
    }
    private static func subdivide(_ path: [Point], to n: Int) -> [Point] {
        let m = path.count - 1
        guard m != n else { return path }
        return (0...n).map { k in
            let t = Float(k) / Float(n) * Float(m), i = min(m - 1, Int(t))
            return path[i] + (path[i + 1] - path[i]) * (t - Float(i))
        }
    }
    /// Control points at the cycle's resolution, normalised for the iteration kernel.
    mutating func state(cycle c: Int) -> BundlingState {
        let n = schedule[c].segments
        points = c == 0 ? base.map { Self.resample($0, to: n) } : points.map { Self.subdivide($0, to: n) }
        return BundlingState(positions: points.flatMap { $0.map { let q = normalised($0); return SIMD2(q.x, q.y) } },
                             offsets: offsets, compatible: compatible, springs: springs, segments: n)
    }
    var normalisedExtent: Float {
        let q = base.flatMap { $0 }.map(normalised)
        return (q.map { max(abs($0.x), abs($0.y)) }.max() ?? 0) + Float(settings.iterations * 2) * Float(maximumDegree + 1) * 0.1
    }
    /// Takes a cycle's result (normalised), restores exact endpoints and moves interior points out of nodes.
    mutating func finish(cycle c: Int, positions: [Point]) {
        let stride = schedule[c].segments + 1
        for i in points.indices {
            var path = (0..<stride).map { positions[i * stride + $0] * unit + origin }
            path[0] = base[i][0]; path[stride - 1] = base[i][base[i].count - 1]
            for p in 1..<(stride - 1) { path[p] = pushOut(path[p], edge: i) }
            points[i] = path
        }
    }
    /// The kernel on the CPU, in the same Float arithmetic as the Metal shader.
    mutating func runCPU() -> Bool {
        for c in schedule.indices {
            _ = state(cycle: c)
            let n = schedule[c].segments, stride = n + 1, count = schedule[c].iterations
            var current = points.flatMap { $0.map(normalised) }
            for iteration in 0..<count {
                if RoutingCompute.isCancelled { return false }
                let step: Float = 0.1 * (1 - Float(iteration) / Float(count))
                var next = current
                for e in points.indices {
                    for p in 1..<n {
                        let id = e * stride + p
                        var force = (current[id - 1] + current[id + 1] - current[id] * 2) * springs[e]
                        for k in Int(offsets[e])..<Int(offsets[e + 1]) {
                            let other = Int(compatible[k].x) * stride + (compatible[k].y != 0 ? n - p : p)
                            let delta = current[other] - current[id]
                            force = force + delta / sqrt(delta.lengthSquared + 0.0001)
                        }
                        next[id] = current[id] + force * step
                    }
                }
                current = next
            }
            finish(cycle: c, positions: current)
        }
        return true
    }
    private func own(_ node: Int, edge: Int) -> Bool { node == edges[edge].source || node == edges[edge].target }
    private func pushOut(_ point: Point, edge: Int) -> Point {
        var p = point
        for _ in 0..<4 {
            var moved = false
            for i in tree.query(Rect(x: p.x, y: p.y)) where !own(i, edge: edge) {
                let r = nodes[i].inflated(by: settings.nodePadding)
                guard p.x > r.left && p.x < r.right && p.y > r.top && p.y < r.bottom else { continue }
                let gaps = [(p.x - r.left, Point(x: r.left - 0.01, y: p.y)), (r.right - p.x, Point(x: r.right + 0.01, y: p.y)),
                            (p.y - r.top, Point(x: p.x, y: r.top - 0.01)), (r.bottom - p.y, Point(x: p.x, y: r.bottom + 0.01))]
                p = gaps.min { $0.0 < $1.0 }!.1; moved = true
            }
            if !moved { break }
        }
        return p
    }
    private func blockers(_ a: Point, _ b: Point, edge: Int, clearance: Float) -> [Int] {
        tree.query(RoutingCompute.bounds(a, b).inflated(by: 0.5)).filter { !own($0, edge: edge) && nodes[$0].inflated(by: clearance).intersectsLine(a, b) }.sorted()
    }
    private func hits(_ path: [Point], edge: Int) -> Int {
        Set(zip(path, path.dropFirst()).flatMap { blockers($0, $1, edge: edge, clearance: 0) }).count
    }
    /// Splits any segment that cuts through a node's padded rectangle at its deepest point and pushes that point out.
    private func clearSegments(_ path: [Point], edge: Int) -> [Point] {
        var result = path
        for _ in 0..<6 {
            var changed = false, k = 0
            while k + 1 < result.count {
                let a = result[k], b = result[k + 1]
                if let i = blockers(a, b, edge: edge, clearance: settings.nodePadding / 2).first {
                    let r = nodes[i].inflated(by: settings.nodePadding), d = b - a
                    var t0: Float = 0, t1: Float = 1
                    for (origin, delta, low, high) in [(a.x, d.x, r.left, r.right), (a.y, d.y, r.top, r.bottom)] where abs(delta) > 1e-6 {
                        let u = (low - origin) / delta, v = (high - origin) / delta
                        t0 = max(t0, min(u, v)); t1 = min(t1, max(u, v))
                    }
                    let mid = pushOut(a + d * ((t0 + t1) / 2), edge: edge)
                    if (mid - a).length > 1e-5 && (mid - b).length > 1e-5 { result.insert(mid, at: k + 1); changed = true; k += 1 }
                }
                k += 1
            }
            if !changed { break }
        }
        return result
    }
    /// Relaxes interior control points towards their neighbours' mean, which rounds off kinks the unit-force kernel leaves.
    private func smoothed(_ path: [Point], passes: Int) -> [Point] {
        var result = path
        for _ in 0..<passes where result.count > 2 {
            let old = result
            for p in 1..<(old.count - 1) { result[p] = old[p] * 0.5 + (old[p - 1] + old[p + 1]) * 0.25 }
        }
        return result
    }
    private func simplify(_ path: [Point], edge: Int) -> [Point] {
        guard path.count > 2 else { return path }
        var keep = [Bool](repeating: false, count: path.count)
        keep[0] = true; keep[path.count - 1] = true
        var stack = [(0, path.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi - lo > 1 else { continue }
            let a = path[lo], b = path[hi], d = b - a, length = d.length
            var worst = lo + 1, deviation: Float = -1
            for i in (lo + 1)..<hi {
                let w = path[i] - a
                let distance = length > 1e-6 ? abs(d.x * w.y - d.y * w.x) / length : w.length
                if distance > deviation { deviation = distance; worst = i }
            }
            if deviation <= settings.simplifyTolerance && blockers(a, b, edge: edge, clearance: settings.nodePadding / 2).isEmpty { continue }
            keep[worst] = true; stack.append((lo, worst)); stack.append((worst, hi))
        }
        return compactPath(path.indices.filter { keep[$0] }.map { path[$0] })
    }
    /// Positions nearest `values` (in lane order) that are at least `gap` apart and within each lane's bounds; where the
    /// bounds leave no room the bounds win and the lanes crowd.
    private static func lanes(_ values: [Float], gap: Float, low: [Float], high: [Float]) -> [Float] {
        var blocks: [(sum: Float, count: Int)] = []
        for (rank, v) in values.enumerated() {
            blocks.append((v - Float(rank) * gap, 1))
            while blocks.count > 1, blocks[blocks.count - 2].sum / Float(blocks[blocks.count - 2].count) > blocks[blocks.count - 1].sum / Float(blocks[blocks.count - 1].count) {
                let last = blocks.removeLast(); blocks[blocks.count - 1].sum += last.sum; blocks[blocks.count - 1].count += last.count
            }
        }
        var x = blocks.flatMap { b in Array(repeating: b.sum / Float(b.count), count: b.count) }.enumerated().map { $1 + Float($0) * gap }
        for _ in 0..<3 {
            for r in x.indices.dropFirst() { x[r] = max(x[r], x[r - 1] + gap) }
            for r in x.indices.dropLast().reversed() { x[r] = min(x[r], x[r + 1] - gap) }
            for r in x.indices { x[r] = min(max(x[r], low[r]), max(low[r], high[r])) }
        }
        return x
    }
    /// Resamples routes at one shared set of arc fractions: every vertex of every route, plus an even grid, so lanes can be
    /// compared point for point while each keeps the corners it was given.
    private func aligned(_ routes: [[Point]]) -> [[Point]] {
        func arcs(_ r: [Point]) -> [Float] {
            var along: [Float] = [0]
            for (a, b) in zip(r, r.dropFirst()) { along.append(along.last! + (b - a).length) }
            let total = along.last!
            return total > 0 ? along.map { $0 / total } : r.indices.map { Float($0) / Float(max(1, r.count - 1)) }
        }
        let fractions = routes.map(arcs), grid = max(2, schedule.last?.segments ?? 2)
        var all = (0...grid).map { Float($0) / Float(grid) } + fractions.flatMap { $0 }
        all.sort()
        var shared: [Float] = []
        for f in all where shared.isEmpty || f - shared[shared.count - 1] > 1e-3 { shared.append(f) }
        shared[shared.count - 1] = 1
        return routes.indices.map { m in
            var k = 0
            return shared.map { f in
                while k < fractions[m].count - 2 && fractions[m][k + 1] < f { k += 1 }
                let lo = fractions[m][k], hi = fractions[m][k + 1]
                return hi > lo ? routes[m][k] + (routes[m][k + 1] - routes[m][k]) * min(1, max(0, (f - lo) / (hi - lo))) : routes[m][k]
            }
        }
    }
    /// Edges joining the same pair of nodes (duplicates and reciprocals) are fanned out; ends stay on the nodes.
    /// Lanes keep the order their routes already have across the group (by mean lateral offset, then index), and at each
    /// control point are pushed apart as little as needed to be `edgeSpacing` apart without meeting another node.
    private func fanned(_ all: [[Point]]) -> [[Point]] {
        var result = all
        for members in multiEdges {
            // Orientation follows the lower node index, so reciprocal edges share one side convention.
            let routes = aligned(members.map { edges[$0].source > edges[$0].target ? Array(all[$0].reversed()) : all[$0] }), n = routes[0].count - 1
            guard n >= 2 else { continue }
            var arc: [Float] = [0]
            for p in 1...n { arc.append(arc[p - 1] + routes.reduce(Float(0)) { $0 + ($1[p] - $1[p - 1]).length }) }
            let mean = (0...n).map { p in routes.reduce(Point.zero) { $0 + $1[p] } / Float(routes.count) }
            // One normal per control point, from the members' average heading, so every lane is measured across the same line.
            let normals = (0...n).map { p -> Point in
                let heading = routes.reduce(Point.zero) { sum, r in
                    let d = r[min(n, p + 1)] - r[max(0, p - 1)]; return sum + d / max(1e-6, d.length)
                }
                let l = heading.length
                return l > 1e-6 ? Point(x: -heading.y / l, y: heading.x / l) : .zero
            }
            func lateral(_ m: Int, _ p: Int) -> Float { let d = routes[m][p] - mean[p]; return d.x * normals[p].x + d.y * normals[p].y }
            let drift = routes.indices.map { m in (1..<n).reduce(Float(0)) { $0 + lateral(m, $1) } }
            let order = routes.indices.sorted { (drift[$0], members[$0]) < (drift[$1], members[$1]) }
            var fanned = routes
            for p in 1..<n where normals[p] != .zero {
                let t = arc[p] / max(1e-6, arc[n]), gap = settings.edgeSpacing * min(1, t / 0.4, (1 - t) / 0.4)
                let v = order.map { lateral($0, p) }
                // How far each lane may move along the normal before it meets another node's padding.
                let room = order.map { m -> (low: Float, high: Float) in
                    let o = routes[m][p], reach = Float(members.count) * settings.edgeSpacing
                    var low = -reach, high = reach
                    for k in tree.query(RoutingCompute.bounds(o - normals[p] * reach, o + normals[p] * reach)) where !own(k, edge: members[0]) {
                        let r = nodes[k].inflated(by: settings.nodePadding)
                        var s0 = -Float.infinity, s1 = Float.infinity
                        for (origin, direction, a, b) in [(o.x, normals[p].x, r.left, r.right), (o.y, normals[p].y, r.top, r.bottom)] {
                            if abs(direction) < 1e-6 { if origin <= a || origin >= b { s1 = -.infinity } }
                            else { let u = (a - origin) / direction, w = (b - origin) / direction; s0 = max(s0, min(u, w)); s1 = min(s1, max(u, w)) }
                        }
                        guard s0 < s1 else { continue }
                        if s0 >= 0 { high = min(high, s0 - 0.01) } else if s1 <= 0 { low = max(low, s1 + 0.01) }
                    }
                    return (low, high)
                }
                let x = Self.lanes(v, gap: gap, low: zip(v, room).map { $0 + $1.low }, high: zip(v, room).map { $0 + $1.high })
                for (rank, m) in order.enumerated() { fanned[m][p] = routes[m][p] + normals[p] * (x[rank] - v[rank]) }
            }
            for (m, i) in members.enumerated() { result[i] = edges[i].source > edges[i].target ? fanned[m].reversed() : fanned[m] }
        }
        return result
    }
    /// Members of each set of edges joining one pair of nodes, for groups of two or more.
    private var multiEdges: [[Int]] {
        var groups: [[Int]: [Int]] = [:]
        for (i, e) in edges.enumerated() where e.source >= 0 && e.target >= 0 { groups[[min(e.source, e.target), max(e.source, e.target)], default: []].append(i) }
        return groups.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { groups[$0]! }.filter { $0.count > 1 }
    }
    private static func cross(_ a: [Point], _ b: [Point]) -> Bool {
        func x(_ p: Point, _ q: Point) -> Float { p.x * q.y - p.y * q.x }
        for (p, q) in zip(a, a.dropFirst()) {
            for (r, t) in zip(b, b.dropFirst()) {
                let u = q - p, v = t - r, den = x(u, v)
                guard abs(den) > 1e-6 else { continue }
                let f = x(r - p, v) / den, g = x(r - p, u) / den
                if f > 1e-5 && f < 1 - 1e-5 && g > 1e-5 && g < 1 - 1e-5 { return true }
            }
        }
        return false
    }
    func paths() -> [[Point]] {
        guard !schedule.isEmpty else { return base }
        // Smoothing can pull points back into nodes; each route is cleared on its own before lanes are fanned, so the
        // fan sees the corners the routes take round nodes and the nodes' lateral room.
        func cleared(_ i: Int, _ route: [Point]) -> [Point] {
            var path = route
            for p in 1..<max(1, path.count - 1) { path[p] = pushOut(path[p], edge: i) }
            return clearSegments(path, edge: i)
        }
        func finish(_ i: Int, _ path: [Point]) -> [Point] {
            let routed = simplify(clearSegments(path, edge: i), edge: i)
            // A bundle that ends up crossing more nodes than the route it started from is not worth keeping.
            return hits(routed, edge: i) > hits(base[i], edge: i) ? base[i] : routed
        }
        let spread = fanned(points.indices.map { cleared($0, smoothed(points[$0], passes: 2)) })
        var result = points.indices.map { finish($0, spread[$0]) }
        // Lanes that still cross after clearing and simplifying are fanned from the routes they started with instead,
        // and if even those cross they stay as they were: bundling never adds a crossing between edges of one pair.
        func crossing(_ members: [Int]) -> Bool { members.indices.contains { a in members[(a + 1)...].contains { Self.cross(result[members[a]], result[$0]) } } }
        var fallback: [[Point]]?
        for members in multiEdges where crossing(members) {
            if fallback == nil { fallback = fanned(base.indices.map { cleared($0, base[$0]) }) }
            for i in members { result[i] = finish(i, fallback![i]) }
            if crossing(members) { for i in members { result[i] = base[i] } }
        }
        return result
    }
}
