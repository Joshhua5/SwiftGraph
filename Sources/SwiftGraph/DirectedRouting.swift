import Foundation

enum DirectedGeometry {
    static let epsilon: Float = 0.0001
    struct Segment {
        var a: Point, b: Point
        var horizontal: Bool { abs(a.y - b.y) < epsilon }
        var length: Float { abs(a.x - b.x) + abs(a.y - b.y) }
    }
    struct Score {
        var missing = 0, overlaps = 0, crossings = 0, shared = 0, proximity = 0, bends = 0
        var length: Float = 0.0, area: Float = 0.0
        /// Proximity ranks after sharing and, with crossings, ahead of bends. A proximate pair is
        /// weighed as `proximityWeight` crossings: a strict order would give up hundreds of
        /// crossings to remove one residual near-parallel pair in a dense component.
        static let proximityWeight = 4
        func precedes(_ b: Score) -> Bool {
            let aValues = [Float(missing + overlaps), Float(shared), Float(crossings + Self.proximityWeight * proximity), Float(proximity), Float(bends), length, area]
            let bValues = [Float(b.missing + b.overlaps), Float(b.shared), Float(b.crossings + Self.proximityWeight * b.proximity), Float(b.proximity), Float(b.bends), b.length, b.area]
            for (a, b) in zip(aValues, bValues) where a != b { return a < b }
            return false
        }
    }
    static func segments(_ path: [Point]) -> [Segment] { zip(path, path.dropFirst()).map { Segment(a: $0, b: $1) } }
    static func shared(_ a: Segment, _ b: Segment) -> Bool {
        if a.horizontal != b.horizontal { return false }
        if a.horizontal {
            return abs(a.a.y - b.a.y) < epsilon && min(max(a.a.x, a.b.x), max(b.a.x, b.b.x)) - max(min(a.a.x, a.b.x), min(b.a.x, b.b.x)) > epsilon
        }
        return abs(a.a.x - b.a.x) < epsilon && min(max(a.a.y, a.b.y), max(b.a.y, b.b.y)) - max(min(a.a.y, a.b.y), min(b.a.y, b.b.y)) > epsilon
    }
    static func nearShared(_ a: Segment, _ b: Segment, spacing: Float, minimumLength: Float = 12) -> Bool {
        guard a.horizontal == b.horizontal else { return false }
        if a.horizontal {
            return abs(a.a.y - b.a.y) < spacing - epsilon && min(max(a.a.x, a.b.x), max(b.a.x, b.b.x)) - max(min(a.a.x, a.b.x), min(b.a.x, b.b.x)) > minimumLength
        }
        return abs(a.a.x - b.a.x) < spacing - epsilon && min(max(a.a.y, a.b.y), max(b.a.y, b.b.y)) - max(min(a.a.y, a.b.y), min(b.a.y, b.b.y)) > minimumLength
    }
    static func crossing(_ a: Segment, _ b: Segment) -> Point? {
        guard a.horizontal != b.horizontal else { return nil }
        let h = a.horizontal ? a : b, v = a.horizontal ? b : a
        let p = Point(x: v.a.x, y: h.a.y)
        return p.x > min(h.a.x, h.b.x) + epsilon && p.x < max(h.a.x, h.b.x) - epsilon
            && p.y > min(v.a.y, v.b.y) + epsilon && p.y < max(v.a.y, v.b.y) - epsilon ? p : nil
    }
    /// Crossing points, exactly shared pairs and near-parallel pairs (closer than `spacing`
    /// with overlap beyond the minimum run) between different routes. A pair that shares
    /// exactly is not also counted as proximate. The grid visits only neighbouring segments.
    static func pairStatistics(_ lines: [[Segment]], spacing: Float) throws -> (crossings: Int, shared: Int, proximity: Int) {
        let grid = DirectedSegmentGrid()
        for (i, line) in lines.enumerated() { for s in line { grid.insert(s, owner: i) } }
        var crossings = 0, sharedPairs = 0, proximity = 0
        for i in lines.indices {
            try Task.checkCancellation()
            var hits: [Int: Set<Point>] = [:], sharing: Set<Int> = [], near: Set<Int> = []
            for a in lines[i] {
                grid.forEach(near: a, margin: spacing) { j, b in
                    guard j > i else { return }
                    if let p = crossing(a, b) { hits[j, default: []].insert(p) }
                    if shared(a, b) { sharing.insert(j) } else if nearShared(a, b, spacing: spacing) { near.insert(j) }
                }
            }
            crossings += hits.values.reduce(0) { $0 + $1.count }
            sharedPairs += sharing.count; proximity += near.subtracting(sharing).count
        }
        return (crossings, sharedPairs, proximity)
    }
    static func proximity(edges: [LayoutEdge], spacing: Float) throws -> Int {
        try pairStatistics(edges.map { segments($0.path) }, spacing: spacing).proximity
    }
    static func measure(nodes: [LayoutNode], edges: [LayoutEdge], spacing: Float = 10) throws -> Score {
        var score = Score()
        let lines = edges.map { segments($0.path) }
        for i in nodes.indices { for j in nodes.indices where j > i && nodes[i].bounds.intersects(nodes[j].bounds) { score.overlaps += 1 } }
        for i in edges.indices {
            if edges[i].path.count < 2 { score.missing += 1 }
            score.bends += max(0, edges[i].path.count - 2)
            score.length += lines[i].reduce(0) { $0 + $1.length }
        }
        let pairs = try pairStatistics(lines, spacing: spacing)
        score.crossings = pairs.crossings; score.shared = pairs.shared; score.proximity = pairs.proximity
        let rect = bounds(nodes: nodes, edges: edges); score.area = rect.width * rect.height
        return score
    }
    static func bounds(nodes: [LayoutNode], edges: [LayoutEdge]) -> Rect {
        let points = nodes.flatMap { [Point(x: $0.bounds.left, y: $0.bounds.top), Point(x: $0.bounds.right, y: $0.bounds.bottom)] } + edges.flatMap(\.path)
        guard let first = points.first else { return Rect() }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    static func compact(_ path: [Point]) -> [Point] {
        var result: [Point] = []
        for p in path {
            if result.last == p { continue }
            if result.count >= 2 {
                let a = result[result.count - 2], b = result.last!, u = b - a, v = p - b
                if abs(u.x * v.y - u.y * v.x) < epsilon && u.x * v.x + u.y * v.y >= 0 { result.removeLast() }
            }
            result.append(p)
        }
        return result
    }
    static func clear(_ a: Point, _ b: Point, bodies: [Rect]) -> Bool {
        if abs(a.x - b.x) > epsilon && abs(a.y - b.y) > epsilon { return false }
        return !bodies.contains { r in
            if abs(a.x - b.x) < epsilon {
                return a.x > r.left + epsilon && a.x < r.right - epsilon
                    && max(a.y, b.y) > r.top + epsilon && min(a.y, b.y) < r.bottom - epsilon
            }
            return a.y > r.top + epsilon && a.y < r.bottom - epsilon
                && max(a.x, b.x) > r.left + epsilon && min(a.x, b.x) < r.right - epsilon
        }
    }
}

/// Uniform bucket index over axis-aligned segments. Queries return only segments whose
/// bucket overlaps the (margin-inflated) query box, so pair scans stay near-linear.
final class DirectedSegmentGrid {
    private struct Cell: Hashable { var x: Int, y: Int }
    private let size: Float
    private(set) var segments: [DirectedGeometry.Segment] = []
    private var owners: [Int] = []
    private var cells: [Cell: [Int]] = [:]
    private var stamps: [Int] = []
    private var current = 0
    init(cellSize: Float = 64) { size = cellSize }

    func removeAll() { segments.removeAll(keepingCapacity: true); owners.removeAll(keepingCapacity: true); cells.removeAll(keepingCapacity: true); stamps.removeAll(keepingCapacity: true) }
    func insert(_ segment: DirectedGeometry.Segment, owner: Int) {
        let index = segments.count
        segments.append(segment); owners.append(owner); stamps.append(0)
        let (xs, ys) = span(segment, margin: 0)
        for x in xs { for y in ys { cells[Cell(x: x, y: y), default: []].append(index) } }
    }
    private func bucket(_ value: Float) -> Int { Int(max(-1e9, min(1e9, (value / size).rounded(.down)))) }
    private func span(_ s: DirectedGeometry.Segment, margin: Float) -> (ClosedRange<Int>, ClosedRange<Int>) {
        (bucket(min(s.a.x, s.b.x) - margin)...bucket(max(s.a.x, s.b.x) + margin),
         bucket(min(s.a.y, s.b.y) - margin)...bucket(max(s.a.y, s.b.y) + margin))
    }
    /// Visits each indexed segment once whose bucket meets the query box. Callers apply the exact tests.
    func forEach(near query: DirectedGeometry.Segment, margin: Float, _ body: (Int, DirectedGeometry.Segment) -> Void) {
        let (xs, ys) = span(query, margin: max(margin, DirectedGeometry.epsilon * 2))
        if xs.count * ys.count > segments.count {
            for i in segments.indices { body(owners[i], segments[i]) }
            return
        }
        current += 1
        for x in xs { for y in ys {
            guard let list = cells[Cell(x: x, y: y)] else { continue }
            for i in list where stamps[i] != current { stamps[i] = current; body(owners[i], segments[i]) }
        } }
    }
}

/// Port assignment and corridor candidates share obstacle geometry for the whole component.
/// The exact-coordinate search is a repair path, not the common case for every edge.
final class DirectedRouter {
    typealias Ports = (Point, Point, Point, Point)
    let nodes: [LayoutNode], edges: [LayoutEdge], feedback: Set<LayoutEdge>
    let edgeIndices: [LayoutEdge: Int], configuration: DirectedLayoutConfiguration, pitch: Float
    var bodies: [Rect], obstacles: [Rect]
    let occupied = DirectedSegmentGrid()
    var ports: [LayoutEdge: Ports] = [:]
    let clearance: Float
    /// Strokes must never touch: the hard floor beneath `edgeSpacing`.
    let trackClearance: Float
    /// Preferred separation between parallel runs; routing relaxes to `trackClearance` only as a last resort.
    let edgeSpacing: Float
    private var spacing: Float
    private var coordinated = false
    private var retained: Set<LayoutEdge> = []
    private var costs: [Float] = [], previous: [Int] = [], closed: [Bool] = []

    init(nodes: [LayoutNode], edges: [LayoutEdge], feedback: Set<LayoutEdge>, edgeIndices: [LayoutEdge: Int], configuration: DirectedLayoutConfiguration, pitch: Float) {
        self.nodes = nodes; self.edges = edges; self.feedback = feedback; self.edgeIndices = edgeIndices
        self.configuration = configuration; self.pitch = pitch
        trackClearance = (configuration.edgeWidths.max() ?? 1) + 1
        edgeSpacing = max(configuration.edgeSpacing, trackClearance)
        spacing = edgeSpacing
        clearance = max(configuration.clearance, ((configuration.edgeWidths.max() ?? 1) * 2.5 + 4) / 2 + 2)
        bodies = nodes.map(\.bounds)
        let padding = clearance
        obstacles = nodes.map { $0.bounds.inflated(by: padding) }
    }

    func route(coordinated: Bool = true) throws {
        self.coordinated = coordinated && configuration.mode == .fresh
        assignPorts()
        var channels: [LayoutEdge: [Point]]
        if self.coordinated {
            let priorX = Dictionary(uniqueKeysWithValues: nodes.map { ($0, $0.center.x) })
            let plan = DirectedChannelPlan(nodes: nodes, edges: edges, feedback: feedback, ports: ports,
                edgeIndices: edgeIndices, clearance: clearance, spacing: edgeSpacing)
            channels = try plan.apply(minimumGap: configuration.layerSpacing)
            for edge in edges {
                var p = ports[edge]!
                p.0.x += edge.source.center.x - priorX[edge.source]!
                p.1.x += edge.target.center.x - priorX[edge.target]!
                ports[edge] = p
            }
            bodies = nodes.map(\.bounds)
            obstacles = bodies.map { $0.inflated(by: clearance) }
        } else { channels = hierarchyPaths() }
        let guides = edges.map(\.path), basePorts = ports
        try routePass(reverse: false, channelPaths: channels)
        let missing = edges.filter { $0.path.isEmpty }.count
        if missing > 0 {
            let first = edges.map(\.path), firstPorts = ports
            for (edge, guide) in zip(edges, guides) { edge.path = guide }
            ports = basePorts
            try routePass(reverse: true, channelPaths: channels)
            if edges.filter({ $0.path.isEmpty }).count > missing {
                for (edge, path) in zip(edges, first) { edge.path = path }
                ports = firstPorts
            }
        }
        try separateProximateRuns()
        try polish()
        // Incremental drawings keep their retained routes; only the new ones are improved.
        if configuration.mode != .fresh { try refine(); try improveWorstRoutes(); try polish() }
    }

    private func load(excluding skipped: LayoutEdge?) {
        occupied.removeAll()
        for edge in edges where edge !== skipped {
            let owner = edgeIndices[edge]!
            for segment in DirectedGeometry.segments(edge.path) { occupied.insert(segment, owner: owner) }
        }
    }

    /// Refine the selected drawing with every other route present. The initial pass
    /// sees only earlier edges, so a valid hierarchy guide can retain avoidable jogs.
    /// Each accepted shortcut is obstacle-safe and cannot add crossings or length.
    func refine() throws {
        let ordered = edges.filter { !retained.contains($0) }.sorted {
            let a = $0.path.count, b = $1.path.count
            return a == b ? edgeIndices[$0]! < edgeIndices[$1]! : a > b
        }
        spacing = edgeSpacing
        for edge in ordered where edge.path.count > 4 {
            try Task.checkCancellation()
            load(excluding: edge)
            let others = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
            func quality(_ path: [Point]) -> (crossings: Int, length: Float)? {
                var crossings = 0, length: Float = 0.0
                for segment in DirectedGeometry.segments(path) {
                    if !DirectedGeometry.clear(segment.a, segment.b, bodies: bodies)
                        || !DirectedGeometry.clear(segment.a, segment.b, bodies: others) { return nil }
                    length += segment.length
                    var rejected = false
                    occupied.forEach(near: segment, margin: edgeSpacing) { _, other in
                        if DirectedGeometry.shared(segment, other) || DirectedGeometry.nearShared(segment, other, spacing: edgeSpacing) { rejected = true }
                        else if DirectedGeometry.crossing(segment, other) != nil { crossings += 1 }
                    }
                    if rejected { return nil }
                }
                return (crossings, length)
            }
            var path = edge.path
            guard var score = quality(path) else { continue }
            // Preserve the first and last segments, and therefore the port direction
            // and arrowhead approach. Bound work even for unusually winding inputs.
            for _ in 0..<2 {
                var changed = false
                let count = path.count
                guard count > 4 else { break }
                outer: for span in stride(from: min(count - 3, 10), through: 2, by: -1) {
                    for i in 1..<(count - 1 - span) {
                        let j = i + span, a = path[i], b = path[j]
                        for elbow in [Point(x: a.x, y: b.y), Point(x: b.x, y: a.y)] {
                            let candidate = DirectedGeometry.compact(Array(path[...i]) + [elbow] + Array(path[j...]))
                            guard candidate.count < path.count, let next = quality(candidate),
                                  next.crossings <= score.crossings, next.length <= score.length + 0.0001 else { continue }
                            path = candidate; score = next; changed = true; break outer
                        }
                    }
                }
                if !changed { break }
            }
            edge.path = path
        }
    }

    /// Bounded rip-up and reroute of the worst remaining paths. Unlike the initial
    /// pass, each trial sees every other route. Endpoint approaches stay fixed and
    /// acceptance is Pareto-monotone in crossings, bends and Manhattan length.
    func improveWorstRoutes() throws {
        coordinated = true; spacing = edgeSpacing
        for _ in 0..<2 {
            var changed = false
            let worst = edges.filter { $0.path.count > 3 && !retained.contains($0) }.sorted {
                if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
                return edgeIndices[$0]! < edgeIndices[$1]!
            }.prefix(16)
            for edge in worst {
                try Task.checkCancellation()
                let original = edge.path
                load(excluding: edge)
                let nonEndpoints = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
                func quality(_ path: [Point]) -> (crossings: Int, bends: Int, length: Float)? {
                    let segments = DirectedGeometry.segments(path)
                    guard path.count >= 2, segments.allSatisfy({ DirectedGeometry.clear($0.a, $0.b, bodies: bodies)
                        && DirectedGeometry.clear($0.a, $0.b, bodies: nonEndpoints) }) else { return nil }
                    var hits: [Int: Set<Point>] = [:], rejected = false
                    for a in segments {
                        occupied.forEach(near: a, margin: edgeSpacing) { owner, b in
                            if DirectedGeometry.shared(a, b) || DirectedGeometry.nearShared(a, b, spacing: edgeSpacing) { rejected = true }
                            else if let p = DirectedGeometry.crossing(a, b) { hits[owner, default: []].insert(p) }
                        }
                        if rejected { return nil }
                    }
                    return (hits.values.reduce(0) { $0 + $1.count }, max(0, path.count - 2), segments.reduce(0) { $0 + $1.length })
                }
                guard var score = quality(original) else { continue }
                let start = original[0], end = original.last!
                let u = original[1] - start, v = original[original.count - 2] - end
                let escape = start + u / u.length * min(clearance, u.length)
                let entry = end + v / v.length * min(clearance, v.length)
                var best = original
                func consider(_ middle: [Point]) {
                    guard zip(middle, middle.dropFirst()).allSatisfy({ DirectedGeometry.clear($0, $1, bodies: obstacles) }) else { return }
                    let candidate = DirectedGeometry.compact([start] + middle + [end])
                    guard let next = quality(candidate), next.crossings <= score.crossings, next.bends <= score.bends,
                          next.length <= score.length + DirectedGeometry.epsilon,
                          next.crossings < score.crossings || next.bends < score.bends || next.length < score.length - DirectedGeometry.epsilon else { return }
                    best = candidate; score = next
                }
                let xs = Array(Set(original.map(\.x) + [(escape.x + entry.x) / 2])).sorted()
                let ys = Array(Set(original.map(\.y) + [(escape.y + entry.y) / 2] + exteriorLanes(from: escape, to: entry))).sorted()
                for x in xs { consider([escape, Point(x: x, y: escape.y), Point(x: x, y: entry.y), entry]) }
                for y in ys { consider([escape, Point(x: escape.x, y: y), Point(x: entry.x, y: y), entry]) }
                if best == original, let repaired = try search(from: escape, to: entry, startAxis: axis(u), endAxis: axis(v), visitLimit: 4096) {
                    consider(repaired)
                }
                if best != original { edge.path = best; changed = true }
            }
            if !changed { break }
        }
    }

    /// Final tidying of the finished routes: near-miss edges straight, tiny jogs gone.
    func polish() throws {
        spacing = edgeSpacing
        try straightenDoglegs()
        try removeMicroJogs()
    }

    /// Crossings of `path` with the loaded routes, or nil when it hits a body, shares a run or crowds one.
    private func crossingCount(_ path: [Point], others: [Rect], spacing: Float? = nil) -> Int? {
        let gap = spacing ?? edgeSpacing
        var count = 0
        for segment in DirectedGeometry.segments(path) {
            guard DirectedGeometry.clear(segment.a, segment.b, bodies: bodies), DirectedGeometry.clear(segment.a, segment.b, bodies: others) else { return nil }
            var rejected = false
            occupied.forEach(near: segment, margin: gap) { _, other in
                if DirectedGeometry.shared(segment, other) || DirectedGeometry.nearShared(segment, other, spacing: gap) { rejected = true }
                else if DirectedGeometry.crossing(segment, other) != nil { count += 1 }
            }
            if rejected { return nil }
        }
        return count
    }

    /// An interior jog shorter than `microLength` is removed by moving one of its two neighbouring runs onto the
    /// other's coordinate (the end runs hold the ports, so they stay). The move must keep the route clear and add no crossing.
    func removeMicroJogs(microLength: Float = 4) throws {
        for edge in edges.sorted(by: { edgeIndices[$0]! < edgeIndices[$1]! }) where !retained.contains(edge) && edge.path.count >= 5 {
            try Task.checkCancellation()
            var loaded = false, others: [Rect] = [], before = 0
            for _ in 0..<4 {
                let path = edge.path
                guard path.count >= 5,
                      let k = (1..<(path.count - 2)).first(where: { (path[$0 + 1] - path[$0]).length < microLength && (path[$0 + 1] - path[$0]).length > DirectedGeometry.epsilon }) else { break }
                if !loaded {
                    load(excluding: edge); loaded = true
                    others = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
                    guard let count = crossingCount(path, others: others) else { break }
                    before = count
                }
                let vertical = abs(path[k].x - path[k + 1].x) < DirectedGeometry.epsilon
                var changed = false
                let candidates = [k + 1, k].sorted { a, b in
                    let fa = a == k + 1 ? k + 1 : k - 1, fb = b == k + 1 ? k + 1 : k - 1
                    let ia = fa >= 1 && fa + 1 <= path.count - 2, ib = fb >= 1 && fb + 1 <= path.count - 2
                    return ia && !ib
                }
                for candidate in candidates {
                    // Moves the run that starts (after) or ends (before) at the jog onto the jog's far coordinate.
                    let first = candidate == k + 1 ? k + 1 : k - 1, second = first + 1
                    let target = candidate == k + 1 ? path[k] : path[k + 1]
                    let isPortSlide = first < 1 || second > path.count - 2
                    let gap = isPortSlide ? min(edgeSpacing, 8) : edgeSpacing
                    if isPortSlide {
                        guard vertical, first == 0 || second == path.count - 1 else { continue }
                        let atStart = first == 0
                        let node = atStart ? edge.source : edge.target, port = path[atStart ? 0 : path.count - 1]
                        guard let span = slideInterval(edge, node: node, at: port, margin: 6, spacing: gap),
                              target.y >= span.lo - DirectedGeometry.epsilon, target.y <= span.hi + DirectedGeometry.epsilon else { continue }
                    }
                    var next = path
                    for i in [first, second] { if vertical { next[i].y = target.y } else { next[i].x = target.x } }
                    next = DirectedGeometry.compact(next)
                    guard let count = crossingCount(next, others: others, spacing: gap), count <= before, next.count < path.count else { continue }
                    edge.path = next; before = count; changed = true
                    if var p = ports[edge] { p.0 = next[0]; p.1 = next[next.count - 1]; ports[edge] = p }
                    break
                }
                if !changed { break }
            }
        }
    }

    /// The free span along `node`'s `side` around the port at `point`: bounded by the side and the neighbouring
    /// ports (their order, and so the crossings they were assigned for, is kept).
    private func slideInterval(_ edge: LayoutEdge, node: LayoutNode, at point: Point, margin: Float = 8, spacing: Float? = nil) -> (lo: Float, hi: Float)? {
        let gap = spacing ?? edgeSpacing
        let side: PortConstraint = abs(point.x - node.bounds.left) < 0.001 ? .left : .right
        guard Self.onSide(point, side, of: node.bounds, margin: 0) else { return nil }
        var (lo, hi) = node.bounds.height > 2 * margin ? (node.bounds.top + margin, node.bounds.bottom - margin) : (node.bounds.center.y, node.bounds.center.y)
        for other in edges where other !== edge {
            for (end, owner) in [(other.path.first, other.source), (other.path.last, other.target)] where owner === node {
                guard let end, Self.onSide(end, side, of: node.bounds, margin: 0) else { continue }
                if end.y < point.y { lo = max(lo, end.y + gap) } else { hi = min(hi, end.y - gap) }
            }
        }
        return (lo, hi)
    }

    /// A Z-shaped route between two left/right ports is straightened by sliding its ports along their sides to
    /// a common coordinate (as close to where they are as the neighbouring ports allow, each end moving only
    /// as far as needed). The straight run must be clear and add no crossing, sharing or crowding.
    func straightenDoglegs() throws {
        let order = edges.filter { !retained.contains($0) && $0.path.count == 4 && $0.source !== $0.target }
            .sorted { edgeIndices[$0]! < edgeIndices[$1]! }
        for edge in order {
            try Task.checkCancellation()
            let path = edge.path
            guard path.count == 4, abs(path[0].y - path[1].y) < DirectedGeometry.epsilon, abs(path[2].y - path[3].y) < DirectedGeometry.epsilon,
                  abs(path[0].y - path[3].y) > DirectedGeometry.epsilon,
                  let s = slideInterval(edge, node: edge.source, at: path[0]), let t = slideInterval(edge, node: edge.target, at: path[3]) else { continue }
            let lo = max(s.lo, t.lo), hi = min(s.hi, t.hi)
            guard lo <= hi + DirectedGeometry.epsilon else { continue }
            load(excluding: edge)
            let others = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
            guard let before = crossingCount(path, others: others) else { continue }
            // The coordinate nearest the source end (then the target end) that both sides allow.
            let y = min(max(path[0].y, lo), hi)
            let next = [Point(x: path[0].x, y: y), Point(x: path[3].x, y: y)]
            guard let after = crossingCount(next, others: others), after <= before else { continue }
            edge.path = next
            if var p = ports[edge] { p.0 = next[0]; p.1 = next[1]; ports[edge] = p }
        }
    }

    /// Greedy routing leaves the occasional pair of runs closer than `edgeSpacing`. Each such
    /// route has its interior runs nudged to exactly the spacing from their neighbours; a nudge
    /// is kept only if it removes proximity without adding crossings or more than two bends.
    func separateProximateRuns() throws {
        spacing = edgeSpacing
        for _ in 0..<3 {
            load(excluding: nil)
            let troubled = edges.filter { edge in
                guard !retained.contains(edge), edge.path.count > 3 else { return false }
                let owner = edgeIndices[edge]!
                var near = false
                for segment in DirectedGeometry.segments(edge.path) {
                    occupied.forEach(near: segment, margin: edgeSpacing) { other, b in
                        if other != owner && !DirectedGeometry.shared(segment, b) && DirectedGeometry.nearShared(segment, b, spacing: edgeSpacing) { near = true }
                    }
                }
                return near
            }.sorted { edgeIndices[$0]! < edgeIndices[$1]! }
            if troubled.isEmpty { return }
            var changed = false
            for edge in troubled {
                try Task.checkCancellation()
                load(excluding: edge)
                let others = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
                func quality(_ path: [Point]) -> (proximity: Int, crossings: Int, bends: Int)? {
                    var near: Set<Int> = [], hits: [Int: Set<Point>] = [:], rejected = false
                    for segment in DirectedGeometry.segments(path) {
                        guard DirectedGeometry.clear(segment.a, segment.b, bodies: bodies), DirectedGeometry.clear(segment.a, segment.b, bodies: others) else { return nil }
                        occupied.forEach(near: segment, margin: edgeSpacing) { owner, b in
                            if DirectedGeometry.shared(segment, b) { rejected = true }
                            else if DirectedGeometry.nearShared(segment, b, spacing: edgeSpacing) { near.insert(owner) }
                            else if let p = DirectedGeometry.crossing(segment, b) { hits[owner, default: []].insert(p) }
                        }
                        if rejected { return nil }
                    }
                    return (near.count, hits.values.reduce(0) { $0 + $1.count }, max(0, path.count - 2))
                }
                var path = edge.path
                guard var score = quality(path) else { continue }
                for _ in 0..<4 where score.proximity > 0 {
                    var best: ([Point], (proximity: Int, crossings: Int, bends: Int))?
                    for k in 1..<(path.count - 2) {
                        let a = path[k], b = path[k + 1], horizontal = abs(a.y - b.y) < DirectedGeometry.epsilon
                        guard horizontal || abs(a.x - b.x) < DirectedGeometry.epsilon else { continue }
                        var targets: Set<Float> = []
                        occupied.forEach(near: DirectedGeometry.Segment(a: a, b: b), margin: edgeSpacing) { _, other in
                            guard other.horizontal == horizontal else { return }
                            let c = horizontal ? other.a.y : other.a.x
                            targets.insert(c - edgeSpacing); targets.insert(c + edgeSpacing)
                        }
                        for c in targets.sorted() {
                            var candidate = path
                            if horizontal { candidate[k].y = c; candidate[k + 1].y = c } else { candidate[k].x = c; candidate[k + 1].x = c }
                            candidate = DirectedGeometry.compact(candidate)
                            guard let next = quality(candidate), next.proximity < score.proximity, next.crossings <= score.crossings,
                                  next.bends <= score.bends + 2 else { continue }
                            if best == nil || (next.proximity, next.crossings, next.bends) < (best!.1.proximity, best!.1.crossings, best!.1.bends) { best = (candidate, next) }
                        }
                    }
                    guard let best else { break }
                    path = best.0; score = best.1
                }
                if path != edge.path { edge.path = path; changed = true }
            }
            if !changed { return }
        }
    }

    private func axis(_ direction: Point) -> Int { direction.x != 0 ? 1 : 2 }

    /// A route is accepted only when every stroke clears node bodies and the other nodes' padded obstacles.
    private func validated(_ start: Point, _ middle: [Point], _ end: Point, others: [Rect]) -> [Point]? {
        let path = DirectedGeometry.compact([start] + middle + [end])
        guard path.count >= 2, zip(path, path.dropFirst()).allSatisfy({ DirectedGeometry.clear($0, $1, bodies: bodies) && DirectedGeometry.clear($0, $1, bodies: others) }),
              zip(middle, middle.dropFirst()).allSatisfy({ DirectedGeometry.clear($0, $1, bodies: obstacles) }) else { return nil }
        return path
    }

    private func routePass(reverse: Bool, channelPaths: [LayoutEdge: [Point]]) throws {
        retained = []
        occupied.removeAll()
        func record(_ edge: LayoutEdge) {
            let owner = edgeIndices[edge]!
            for segment in DirectedGeometry.segments(edge.path) { occupied.insert(segment, owner: owner) }
        }
        if configuration.mode != .fresh {
            for edge in edges {
                guard let old = configuration.previousPaths[edgeIndices[edge]!], old.count >= 2 else { continue }
                let (start, end, sd, td) = ports[edge]!
                guard (old[0] - start).length < 0.001, (old.last! - end).length < 0.001 else { continue }
                var path = old
                path[0] = start; path[path.count - 1] = end
                if sd.x != 0 { path[1].y = start.y } else { path[1].x = start.x }
                if td.x != 0 { path[path.count - 2].y = end.y } else { path[path.count - 2].x = end.x }
                let others = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
                if zip(path, path.dropFirst()).allSatisfy({ DirectedGeometry.clear($0, $1, bodies: bodies) && DirectedGeometry.clear($0, $1, bodies: others) }) && pathCost(path).isFinite {
                    edge.path = path; retained.insert(edge); record(edge)
                }
            }
        }
        var order = edges.sorted {
            let a = abs($0.source.center.x - $0.target.center.x), b = abs($1.source.center.x - $1.target.center.x)
            return a == b ? edgeIndices[$0]! < edgeIndices[$1]! : a < b
        }
        if reverse { order.reverse() }
        let trackOrder = edges.sorted {
            let a = ports[$0]!, b = ports[$1]!
            let ad = a.1.y >= a.0.y, bd = b.1.y >= b.0.y
            if ad != bd { return ad }
            let ay = a.0.y + a.1.y, by = b.0.y + b.1.y
            if ay == by { return edgeIndices[$0]! < edgeIndices[$1]! }
            return ad ? ay > by : ay < by
        }
        let trackIndex = Dictionary(uniqueKeysWithValues: trackOrder.enumerated().map { ($0.element, $0.offset) })
        // The channel plan's tracks are mutually separated by construction, so they are
        // committed first and mark the space occupied; greedy routing then works around them.
        var committed: Set<LayoutEdge> = []
        if coordinated {
            for edge in edges.sorted(by: { edgeIndices[$0]! < edgeIndices[$1]! }) where !retained.contains(edge) {
                guard let guide = channelPaths[edge] else { continue }
                let (start, end, _, _) = ports[edge]!
                let others = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
                if let path = validated(start, guide, end, others: others) { edge.path = path; committed.insert(edge); record(edge) }
            }
        }
        for edge in order {
            try Task.checkCancellation()
            if retained.contains(edge) || committed.contains(edge) { continue }
            let base = ports[edge]!
            let fraction = (Float(trackIndex[edge]!) + 1) / Float(edges.count + 1)
            var result: [Point]?, used = base, alternatives: [Ports]?
            levels: for floor in spacingLevels {
                spacing = floor
                result = try attempt(edge, base, guide: channelPaths[edge], fraction: fraction)
                if result != nil { break }
                if alternatives == nil { alternatives = alternatePorts(for: edge) }
                for candidate in alternatives! {
                    if let path = try attempt(edge, candidate, guide: nil, fraction: fraction) { result = path; used = candidate; break levels }
                }
            }
            spacing = edgeSpacing
            if result != nil { ports[edge] = used }
            edge.path = result ?? []
            record(edge)
        }
    }

    /// Preferred spacing first; the hard stroke floor is used only when nothing else routes.
    private var spacingLevels: [Float] { edgeSpacing > trackClearance ? [edgeSpacing, trackClearance] : [edgeSpacing] }

    /// Candidate shapes, then the exact-coordinate repair, for one edge with fixed ports.
    private func attempt(_ edge: LayoutEdge, _ ports: Ports, guide: [Point]?, fraction: Float) throws -> [Point]? {
        let (start, end, sd, td) = ports
        let escape = start + sd * clearance, entry = end + td * clearance
        // Endpoints are never exempted from body validation (including self-loops).
        guard DirectedGeometry.clear(start, escape, bodies: bodies), DirectedGeometry.clear(entry, end, bodies: bodies) else { return nil }
        let otherObstacles = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
        var candidates: [[Point]] = []
        func add(_ middle: [Point]) { if let path = validated(start, middle, end, others: otherObstacles) { candidates.append(path) } }
        if let guide { add(guide) }
        let guided = candidates.first.flatMap { pathCost($0).isFinite ? $0 : nil }
        let xs = [escape.x + (entry.x - escape.x) * (0.2 + fraction * 0.6),
                  escape.x + (entry.x - escape.x) * (0.8 - fraction * 0.6)]
        for x in xs { add([escape, Point(x: x, y: escape.y), Point(x: x, y: entry.y), entry]) }
        let ys = [escape.y + (entry.y - escape.y) * (0.2 + fraction * 0.6),
                  escape.y + (entry.y - escape.y) * (0.8 - fraction * 0.6)]
        for y in ys { add([escape, Point(x: escape.x, y: y), Point(x: entry.x, y: y), entry]) }
        // Feedback and loops get independent exterior lanes; no diagonal loop shortcut.
        if sd.y != 0 || td.y != 0 || candidates.isEmpty {
            for y in exteriorLanes(from: escape, to: entry) { add([escape, Point(x: escape.x, y: y), Point(x: entry.x, y: y), entry]) }
        }
        if !coordinated, let guided { candidates = [guided] }
        var best: [Point]?, bestCost = Float.infinity
        for candidate in candidates {
            let cost = pathCost(candidate)
            if cost < bestCost { best = candidate; bestCost = cost }
        }
        if best == nil {
            var repaired = try search(from: escape, to: entry, startAxis: axis(sd), endAxis: axis(td))
            if repaired == nil { repaired = try search(from: escape, to: entry, startAxis: axis(sd), endAxis: axis(td), occupiedCoordinates: true) }
            if let repaired { add(repaired); best = candidates.last.flatMap { pathCost($0).isFinite ? $0 : nil } }
        }
        return best
    }

    /// Only obstacles and occupied runs within this edge's horizontal span consume
    /// outer lanes. Unrelated edges elsewhere cannot push a feedback route outward.
    private func exteriorLanes(from start: Point, to end: Point) -> [Float] {
        let left = min(start.x, end.x), right = max(start.x, end.x)
        let local = obstacles.filter { $0.right >= left && $0.left <= right }
        let top = min(start.y, end.y, local.map(\.top).min() ?? start.y) - clearance
        let bottom = max(start.y, end.y, local.map(\.bottom).max() ?? start.y) + clearance
        return [(top, Float(-1.0)), (bottom, Float(1.0))].map { initial, direction in
            var y = initial
            for _ in 0...occupied.segments.count {
                let line = DirectedGeometry.Segment(a: Point(x: left, y: y), b: Point(x: right, y: y))
                var blocked = false
                occupied.forEach(near: line, margin: spacing) { _, other in
                    if DirectedGeometry.nearShared(line, other, spacing: spacing, minimumLength: 0) { blocked = true }
                }
                if !blocked { break }
                y += direction * spacing
            }
            return y
        }
    }

    /// All forward edges crossing one rank gap use the same corridor. Sorting tracks
    /// against adjacent virtual nodes preserves the hierarchy's crossing reduction.
    private func hierarchyPaths() -> [LayoutEdge: [Point]] {
        struct Transition { var edge: LayoutEdge; var part: Int; var a: Point; var b: Point }
        let ranks = Array(Set(nodes.map { $0.center.x })).sorted()
        guard ranks.count > 1 else { return [:] }
        var corridors: [Int: [Transition]] = [:]
        var chains: [LayoutEdge: [Point]] = [:]
        for edge in edges where !feedback.contains(edge) && edge.source.center.x != edge.target.center.x {
            // A backward edge runs through the corridors like a forward one, with its points taken in rank order.
            let backward = edge.source.center.x > edge.target.center.x
            guard edge.path.count >= 2,
                  let first = ranks.firstIndex(of: min(edge.source.center.x, edge.target.center.x)),
                  let last = ranks.firstIndex(of: max(edge.source.center.x, edge.target.center.x)),
                  edge.path.count == last - first + 1 else { continue }
            let (start, end, sd, td) = ports[edge]!
            guard backward ? (sd.x < 0 && td.x > 0) : (sd.x > 0 && td.x < 0) else { continue }
            let points = [start + sd * clearance] + edge.path.dropFirst().dropLast() + [end + td * clearance]
            chains[edge] = backward ? Array(points.reversed()) : Array(points)
            for part in 0..<(points.count - 1) {
                corridors[first + part, default: []].append(Transition(edge: edge, part: part, a: points[part], b: points[part + 1]))
            }
        }
        var tracks: [LayoutEdge: [Int: Float]] = [:]
        for rank in corridors.keys.sorted() {
            var list = corridors[rank]!.sorted {
                let ad = $0.b.y >= $0.a.y, bd = $1.b.y >= $1.a.y
                if ad != bd { return ad }
                let ay = $0.a.y + $0.b.y, by = $1.a.y + $1.b.y
                if ay != by { return ad ? ay > by : ay < by }
                return edgeIndices[$0.edge]! < edgeIndices[$1.edge]!
            }
            let low = (nodes.filter { $0.center.x == ranks[rank] }.map { $0.bounds.right }.max() ?? ranks[rank]) + clearance
            let high = (nodes.filter { $0.center.x == ranks[rank + 1] }.map { $0.bounds.left }.min() ?? ranks[rank + 1]) - clearance
            func pairCrossings(_ a: Transition, _ b: Transition) -> Int {
                let x1 = low + (high - low) / 3, x2 = low + (high - low) * 2 / 3
                let p = DirectedGeometry.segments([a.a, Point(x: x1, y: a.a.y), Point(x: x1, y: a.b.y), a.b])
                let q = DirectedGeometry.segments([b.a, Point(x: x2, y: b.a.y), Point(x: x2, y: b.b.y), b.b])
                return p.reduce(0) { count, segment in count + q.filter { DirectedGeometry.crossing(segment, $0) != nil }.count }
            }
            if list.count > 1 {
                for _ in 0..<8 {
                    var changed = false
                    for i in 0..<(list.count - 1) {
                        if pairCrossings(list[i + 1], list[i]) < pairCrossings(list[i], list[i + 1]) {
                            list.swapAt(i, i + 1); changed = true
                        }
                    }
                    if !changed { break }
                }
            }
            for (i, transition) in list.enumerated() {
                tracks[transition.edge, default: [:]][transition.part] = low + (high - low) * Float(i + 1) / Float(list.count + 1)
            }
        }
        var result: [LayoutEdge: [Point]] = [:]
        for (edge, points) in chains {
            var path = [points[0]]
            for part in 0..<(points.count - 1) {
                let a = points[part], b = points[part + 1], x = tracks[edge]![part]!
                path += [Point(x: x, y: a.y), Point(x: x, y: b.y), b]
            }
            result[edge] = DirectedGeometry.compact(edge.source.center.x > edge.target.center.x ? path.reversed() : path)
        }
        return result
    }

    private func pathCost(_ path: [Point], minimumRun: Float = 12) -> Float {
        var value = Float(max(0, path.count - 2)) * 24
        for segment in DirectedGeometry.segments(path) {
            value += segment.length
            var blocked = false
            occupied.forEach(near: segment, margin: spacing) { _, other in
                if DirectedGeometry.shared(segment, other) || DirectedGeometry.nearShared(segment, other, spacing: spacing, minimumLength: minimumRun) { blocked = true }
                else if DirectedGeometry.crossing(segment, other) != nil { value += 350 }
            }
            if blocked { return .infinity }
        }
        return value
    }

    private struct End { var edge: LayoutEdge; var source: Bool; var neighbor: Point; var group = 3; var depth: Float = 0.0; var want: Float? }
    private struct SideKey: Hashable { var node: LayoutNode; var side: PortConstraint }

    /// The span of a left/right side where a port may sit: clear of the corners.
    static func sideRange(_ r: Rect) -> (lo: Float, hi: Float) {
        r.height > 16 ? (r.top + 8, r.bottom - 8) : (r.center.y, r.center.y)
    }

    static func onSide(_ point: Point, _ side: PortConstraint, of r: Rect, margin: Float) -> Bool {
        switch side {
        case .left: return abs(point.x - r.left) < 0.001 && point.y >= r.top + margin && point.y <= r.bottom - margin
        case .right: return abs(point.x - r.right) < 0.001 && point.y >= r.top + margin && point.y <= r.bottom - margin
        case .top: return abs(point.y - r.top) < 0.001 && point.x >= r.left + margin && point.x <= r.right - margin
        case .bottom: return abs(point.y - r.bottom) < 0.001 && point.x >= r.left + margin && point.x <= r.right - margin
        case .none: return false
        }
    }

    /// The nearest coordinate in [lo, hi] to `desired` that keeps `minimum` from every taken one.
    static func nearestFree(_ desired: Float, taken: [Float], lo: Float, hi: Float, minimum: Float) -> Float? {
        func free(_ t: Float) -> Bool { t >= lo - 0.0001 && t <= hi + 0.0001 && !taken.contains { abs($0 - t) < minimum - 0.0001 } }
        let wanted = min(hi, max(lo, desired))
        if free(wanted) { return wanted }
        let candidates = ([lo, hi] + taken.flatMap { [$0 - minimum, $0 + minimum] }).filter(free)
        return candidates.min { abs($0 - desired) == abs($1 - desired) ? $0 < $1 : abs($0 - desired) < abs($1 - desired) }
    }

    private func assignPorts() {
        var ends: [SideKey: [End]] = [:]
        var assigned: [LayoutEdge: [Point]] = [:]
        var loops: [LayoutNode: Int] = [:]
        for edge in edges {
            let a = edge.source.bounds, b = edge.target.bounds
            let sides: (PortConstraint, PortConstraint)
            if edge.source === edge.target { sides = (.top, .top) }
            else if feedback.contains(edge) {
                // Reporting links use the facing horizontal sides when vertically separated.
                // Forcing both ends onto the top sends lower targets around unrelated ranks.
                if a.bottom + clearance * 2 < b.top { sides = (.bottom, .top) }
                else if b.bottom + clearance * 2 < a.top { sides = (.top, .bottom) }
                else { sides = (.top, .top) }
            }
            else if edge.sourcePort != .none && edge.targetPort != .none { sides = (edge.sourcePort, edge.targetPort) }
            else if a.center.x < b.center.x { sides = (.right, .left) }
            else { sides = (.left, .right) }
            var source = End(edge: edge, source: true, neighbor: edge.path.count > 2 ? edge.path[1] : b.center)
            var target = End(edge: edge, source: false, neighbor: edge.path.count > 2 ? edge.path[edge.path.count - 2] : a.center)
            // Top and bottom ends order by the other endpoint, not by a stale path: left-going ends sit
            // left and right-going ends right, with self-loops between them. The farther the other
            // endpoint, the outer its arc and the nearer to the centre its port, so it never crosses
            // a nearer arc's horizontal run. Groups: 0 left-going, 1 loop starts, 2 loop ends, 3 aligned, 4 right-going.
            if edge.source === edge.target {
                let level = loops[edge.source, default: 0]; loops[edge.source] = level + 1
                source.group = 1; source.depth = Float(level + 1); target.group = 2; target.depth = Float(level + 1)
            } else {
                for (end, node, other) in [(0, edge.source, edge.target), (1, edge.target, edge.source)] {
                    let dx = other.center.x - node.center.x
                    let group = dx < 0 ? 0 : (dx > 0 ? 4 : 3)
                    if end == 0 { source.group = group; source.depth = abs(dx) } else { target.group = group; target.depth = abs(dx) }
                }
            }
            // Facing left/right ends slide along their side toward the other end, so a pair whose sides overlap
            // gets one shared coordinate (a straight edge) and neighbours more than a side apart still aim at each other.
            if sides.0 != .top && sides.0 != .bottom && sides.1 != .top && sides.1 != .bottom && edge.source !== edge.target {
                let direct = edge.path.count <= 2
                let (su, sv) = (Self.sideRange(a), Self.sideRange(b))
                let lo = max(su.lo, sv.lo), hi = min(su.hi, sv.hi)
                if direct {
                    let mid = (a.center.y + b.center.y) / 2
                    if lo <= hi { source.want = min(hi, max(lo, mid)); target.want = source.want }
                    else { source.want = min(su.hi, max(su.lo, b.center.y)); target.want = min(sv.hi, max(sv.lo, a.center.y)) }
                } else {
                    source.want = min(su.hi, max(su.lo, source.neighbor.y)); target.want = min(sv.hi, max(sv.lo, target.neighbor.y))
                }
            }
            ends[SideKey(node: edge.source, side: sides.0), default: []].append(source)
            ends[SideKey(node: edge.target, side: sides.1), default: []].append(target)
            assigned[edge] = [.zero, .zero, .zero, .zero]
        }
        for (key, unsorted) in ends {
            let vertical = key.side == .left || key.side == .right
            let sorted = unsorted.sorted {
                let ai = edgeIndices[$0.edge]!, bi = edgeIndices[$1.edge]!
                if !vertical {
                    if $0.group != $1.group { return $0.group < $1.group }
                    if $0.depth != $1.depth { return [1, 4].contains($0.group) ? $0.depth > $1.depth : $0.depth < $1.depth }
                    if ai != bi { return $0.group == 4 ? ai > bi : ai < bi }
                    return $0.source && !$1.source
                }
                if $0.neighbor.y != $1.neighbor.y { return $0.neighbor.y < $1.neighbor.y }
                return ai == bi ? $0.source && !$1.source : ai < bi
            }
            let r = key.node.bounds, extent = vertical ? r.height : r.width
            let count = sorted.count, spacing = min(pitch, max(0, extent - 24) / Float(max(1, count - 1)))
            let middle = vertical ? r.center.y : r.center.x
            var slots = (0..<count).map { middle + (Float($0) - Float(count - 1) / 2) * spacing }
            if vertical && sorted.contains(where: { $0.want != nil }) {
                // Ordered ports as close to their wanted coordinates as the spacing and the side allow.
                let range = Self.sideRange(r), step: Float = count > 1 ? min(pitch, max(0, range.hi - range.lo) / Float(count - 1)) : 0
                let fit = isotonicFit(sorted.enumerated().map { ($1.want ?? slots[$0]) - Float($0) * step }, weights: Array(repeating: 1, count: count))
                let top = range.lo, bottom = range.hi - Float(count - 1) * step
                slots = fit.enumerated().map { min(max($1, min(top, bottom)), max(top, bottom)) + Float($0) * step }
            }
            // Prior ports stay where they are; a new end takes the nearest free gap, in order
            // between its neighbours. Only when no gap keeps the spacing is the side re-spread.
            if configuration.mode != .fresh {
                var kept = [Float?](repeating: nil, count: count)
                for (i, end) in sorted.enumerated() {
                    guard let path = configuration.previousPaths[edgeIndices[end.edge]!], path.count >= 2 else { continue }
                    let point = end.source ? path[0] : path.last!
                    if Self.onSide(point, key.side, of: r, margin: 6) { kept[i] = vertical ? point.y : point.x }
                }
                if kept.contains(where: { $0 != nil }) {
                    var taken = kept.compactMap { $0 }, positions = kept, fits = true
                    let lo = (vertical ? r.top : r.left) + 6, hi = (vertical ? r.bottom : r.right) - 6
                    for i in 0..<count where positions[i] == nil {
                        let before = positions[..<i].last(where: { $0 != nil }) ?? nil
                        let after = positions[(i + 1)...].first(where: { $0 != nil }) ?? nil
                        let desired = before.map { b in after.map { ($0 + b) / 2 } ?? b + spacing } ?? after.map { $0 - spacing } ?? slots[i]
                        guard let t = Self.nearestFree(desired, taken: taken, lo: lo, hi: hi, minimum: spacing) else { fits = false; break }
                        positions[i] = t; taken.append(t)
                    }
                    if fits { slots = positions.map { $0! } }
                    else {
                        // No gap is wide enough: keep the order and move the prior ports as little as the spacing demands.
                        let wanted = (0..<count).map { i -> Float in
                            if let k = kept[i] { return k }
                            let before = kept[..<i].last(where: { $0 != nil }) ?? nil, after = kept[(i + 1)...].first(where: { $0 != nil }) ?? nil
                            return before.map { b in after.map { ($0 + b) / 2 } ?? b + spacing } ?? after.map { $0 - spacing } ?? slots[i]
                        }
                        let fit = isotonicFit(wanted.enumerated().map { $1 - Float($0) * spacing }, weights: Array(repeating: 1, count: count))
                        let first = lo, last = hi - Float(count - 1) * spacing
                        slots = fit.enumerated().map { min(max($1, min(first, last)), max(first, last)) + Float($0) * spacing }
                    }
                }
            }
            for (i, end) in sorted.enumerated() {
                let p: Point, d: Point
                switch key.side {
                case .left: p = Point(x: r.left, y: slots[i]); d = Point(x: -1, y: 0)
                case .right: p = Point(x: r.right, y: slots[i]); d = Point(x: 1, y: 0)
                case .top: p = Point(x: slots[i], y: r.top); d = Point(x: 0, y: -1)
                case .bottom: p = Point(x: slots[i], y: r.bottom); d = Point(x: 0, y: 1)
                case .none: continue
                }
                assigned[end.edge]![end.source ? 0 : 1] = p
                assigned[end.edge]![end.source ? 2 : 3] = d
            }
        }
        for (edge, p) in assigned { ports[edge] = (p[0], p[1], p[2], p[3]) }
    }

    /// Port pairs on the other sides, nearest first, each slotted into a free gap beside the ports
    /// already in use. An edge whose assigned sides are blocked is tried here before it is dropped.
    private func alternatePorts(for edge: LayoutEdge) -> [Ports] {
        let current = ports[edge]!, loop = edge.source === edge.target
        var options: [(distance: Float, order: Int, ports: Ports)] = []
        for (s, source) in [PortConstraint.top, .bottom, .left, .right].enumerated() {
            for (t, target) in [PortConstraint.top, .bottom, .left, .right].enumerated() where !loop || source == target {
                guard let sp = slot(on: edge.source, side: source, toward: edge.target.center, excluding: edge),
                      let tp = slot(on: edge.target, side: target, toward: edge.source.center, excluding: edge, extra: loop ? sp.0 : nil),
                      sp.0 != current.0 || tp.0 != current.1 else { continue }
                options.append((abs(sp.0.x - tp.0.x) + abs(sp.0.y - tp.0.y), s * 4 + t, (sp.0, tp.0, sp.1, tp.1)))
            }
        }
        return options.sorted { $0.distance == $1.distance ? $0.order < $1.order : $0.distance < $1.distance }.prefix(8).map(\.ports)
    }

    private func slot(on node: LayoutNode, side: PortConstraint, toward p: Point, excluding edge: LayoutEdge, extra: Point? = nil) -> (Point, Point)? {
        let r = node.bounds, vertical = side == .left || side == .right
        let lo = (vertical ? r.top : r.left) + 6, hi = (vertical ? r.bottom : r.right) - 6
        guard hi >= lo else { return nil }
        var taken = extra.map { [vertical ? $0.y : $0.x] } ?? []
        for (other, q) in ports where other !== edge {
            for (point, owner) in [(q.0, other.source), (q.1, other.target)] where owner === node && Self.onSide(point, side, of: r, margin: 0) {
                taken.append(vertical ? point.y : point.x)
            }
        }
        guard let t = Self.nearestFree(vertical ? p.y : p.x, taken: taken, lo: lo, hi: hi, minimum: edgeSpacing) else { return nil }
        switch side {
        case .left: return (Point(x: r.left, y: t), Point(x: -1, y: 0))
        case .right: return (Point(x: r.right, y: t), Point(x: 1, y: 0))
        case .top: return (Point(x: t, y: r.top), Point(x: 0, y: -1))
        case .bottom: return (Point(x: t, y: r.bottom), Point(x: 0, y: 1))
        case .none: return nil
        }
    }

    /// Rasterize exact-coordinate visibility links once per repair search. Obstacle and
    /// occupied-track costs are then O(1) per A* step, rather than scanning every edge.
    private func prepareGrid(xs: [Float], ys: [Float], obstacles: [Rect]) throws -> (horizontal: [Float], vertical: [Float]) {
        let width = xs.count, count = width * ys.count
        var horizontal = Array(repeating: Float(0), count: count), vertical = horizontal
        func lower(_ values: [Float], _ value: Float) -> Int {
            var low = 0, high = values.count
            while low < high { let mid = (low + high) / 2; if values[mid] < value { low = mid + 1 } else { high = mid } }
            return low
        }
        func points(_ values: [Float], _ low: Float, _ high: Float) -> Range<Int> {
            let first = lower(values, low + DirectedGeometry.epsilon)
            return first..<max(first, lower(values, high - DirectedGeometry.epsilon))
        }
        func links(_ values: [Float], _ low: Float, _ high: Float) -> Range<Int> {
            let first = max(0, lower(values, low + DirectedGeometry.epsilon) - 1)
            return first..<max(first, min(values.count - 1, lower(values, high - DirectedGeometry.epsilon)))
        }
        for rect in obstacles {
            try Task.checkCancellation()
            for y in points(ys, rect.top, rect.bottom) { for x in links(xs, rect.left, rect.right) { horizontal[y * width + x] = .infinity } }
            for x in points(xs, rect.left, rect.right) { for y in links(ys, rect.top, rect.bottom) { vertical[y * width + x] = .infinity } }
        }
        let window = Rect(x: xs[0], y: ys[0], width: xs[xs.count - 1] - xs[0], height: ys[ys.count - 1] - ys[0]).inflated(by: spacing)
        for (i, segment) in occupied.segments.enumerated() {
            if i % 128 == 0 { try Task.checkCancellation() }
            if max(segment.a.x, segment.b.x) < window.left || min(segment.a.x, segment.b.x) > window.right
                || max(segment.a.y, segment.b.y) < window.top || min(segment.a.y, segment.b.y) > window.bottom { continue }
            if segment.horizontal {
                for y in points(ys, segment.a.y - spacing, segment.a.y + spacing) {
                    for x in links(xs, min(segment.a.x, segment.b.x), max(segment.a.x, segment.b.x)) { horizontal[y * width + x] = .infinity }
                }
                let row = lower(ys, segment.a.y)
                for x in points(xs, min(segment.a.x, segment.b.x), max(segment.a.x, segment.b.x)) {
                    if row > 0 { vertical[(row - 1) * width + x] += 350 }
                    if row < ys.count - 1 && ys[row] == segment.a.y { vertical[row * width + x] += 350 }
                }
            } else {
                for x in points(xs, segment.a.x - spacing, segment.a.x + spacing) {
                    for y in links(ys, min(segment.a.y, segment.b.y), max(segment.a.y, segment.b.y)) { vertical[y * width + x] = .infinity }
                }
                let column = lower(xs, segment.a.x)
                for y in points(ys, min(segment.a.y, segment.b.y), max(segment.a.y, segment.b.y)) {
                    if column > 0 { horizontal[y * width + column - 1] += 350 }
                    if column < width - 1 && xs[column] == segment.a.x { horizontal[y * width + column] += 350 }
                }
            }
        }
        return (horizontal, vertical)
    }

    /// The main pass searches a window around the endpoints that widens only when the
    /// narrower one fails; every grid is capped. `startAxis`/`endAxis` (1 horizontal, 2 vertical)
    /// seed the first direction and price a bend at the arrival, as the port approaches are fixed.
    private func search(from start: Point, to end: Point, startAxis: Int, endAxis: Int, occupiedCoordinates: Bool = false, visitLimit: Int? = nil) throws -> [Point]? {
        let margins: [Float] = visitLimit == nil ? [96, 384, .infinity] : [.infinity]
        let cap = visitLimit == nil ? 262_144 : 65_536
        let box = Rect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
        var lastShape = (0, 0)
        for margin in margins {
            let window = margin.isFinite ? box.inflated(by: margin) : nil
            let local = window.map { w in obstacles.filter { $0.inflated(by: 1).intersects(w) } } ?? obstacles
            var xs = local.flatMap { [$0.left - 1, $0.right + 1] } + [start.x, end.x]
            var ys = local.flatMap { [$0.top - 1, $0.bottom + 1] } + [start.y, end.y]
            if occupiedCoordinates {
                xs += occupied.segments.filter { !$0.horizontal }.flatMap { [$0.a.x - spacing, $0.a.x + spacing] }
                ys += occupied.segments.filter(\.horizontal).flatMap { [$0.a.y - spacing, $0.a.y + spacing] }
            }
            if let window { xs += [window.left, window.right]; ys += [window.top, window.bottom] }
            let xv = Array(Set(window.map { w in xs.filter { $0 >= w.left && $0 <= w.right } } ?? xs)).sorted()
            let yv = Array(Set(window.map { w in ys.filter { $0 >= w.top && $0 <= w.bottom } } ?? ys)).sorted()
            if (xv.count, yv.count) == lastShape { continue }
            lastShape = (xv.count, yv.count)
            if xv.count * yv.count > cap { return nil }
            if let path = try search(xs: xv, ys: yv, obstacles: local, from: start, to: end, startAxis: startAxis, endAxis: endAxis, visitLimit: visitLimit) { return path }
        }
        return nil
    }

    private func search(xs: [Float], ys: [Float], obstacles local: [Rect], from start: Point, to end: Point, startAxis: Int, endAxis: Int, visitLimit: Int?) throws -> [Point]? {
        let width = xs.count, height = ys.count, cells = width * height, goal = cells * 3
        let first = ys.firstIndex(of: start.y)! * width + xs.firstIndex(of: start.x)!
        let last = ys.firstIndex(of: end.y)! * width + xs.firstIndex(of: end.x)!
        // The work buffers are moved out of the router for the loop and handed back afterwards.
        var costs = self.costs, previous = self.previous, closed = self.closed
        self.costs = []; self.previous = []; self.closed = []
        defer { self.costs = costs; self.previous = previous; self.closed = closed }
        if costs.count < goal + 1 {
            costs = [Float](repeating: .infinity, count: goal + 1); previous = [Int](repeating: -1, count: goal + 1); closed = [Bool](repeating: false, count: goal + 1)
        } else {
            for i in 0...goal { costs[i] = .infinity; previous[i] = -1; closed[i] = false }
        }
        var queue = DirectedMinHeap()
        let grid = try prepareGrid(xs: xs, ys: ys, obstacles: local)
        let initial = first * 3 + startAxis
        costs[initial] = 0; queue.push(initial, priority: abs(start.x - end.x) + abs(start.y - end.y))
        var visited = 0
        let steps = [(1, 0, 1), (-1, 0, 1), (0, 1, 2), (0, -1, 2)]
        while let current = queue.pop() {
            visited += 1
            if let visitLimit, visited > visitLimit { return nil }
            if visited % 128 == 0 { try Task.checkCancellation() }
            if closed[current] { continue }; closed[current] = true
            if current == goal {
                var at = previous[current], path: [Point] = []
                while at != -1 { let cell = at / 3; path.append(Point(x: xs[cell % width], y: ys[cell / width])); at = previous[at] }
                return DirectedGeometry.compact(path.reversed())
            }
            let cell = current / 3, direction = current % 3
            if cell == last {
                let cost = costs[current] + (direction != endAxis ? 24 : 0)
                if cost < costs[goal] { costs[goal] = cost; previous[goal] = current; queue.push(goal, priority: cost) }
                continue
            }
            let x = cell % width, y = cell / width, base = costs[current]
            for (dx, dy, nextDirection) in steps {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let nextCell = ny * width + nx, next = nextCell * 3 + nextDirection
                let congestion = dy == 0 ? grid.horizontal[min(cell, nextCell)] : grid.vertical[min(cell, nextCell)]
                let cost = base + abs(xs[x] - xs[nx]) + abs(ys[y] - ys[ny]) + congestion + (direction != 0 && direction != nextDirection ? 24 : 0)
                if cost < costs[next] { costs[next] = cost; previous[next] = current; queue.push(next, priority: cost + abs(xs[nx] - end.x) + abs(ys[ny] - end.y)) }
            }
        }
        return nil
    }
}

private struct DirectedMinHeap {
    private var values: [(state: Int, priority: Float)] = []
    mutating func push(_ state: Int, priority: Float) {
        values.append((state, priority)); var i = values.count - 1
        while i > 0 { let parent = (i - 1) / 2; guard less(i, parent) else { break }; values.swapAt(i, parent); i = parent }
    }
    mutating func pop() -> Int? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast().state }
        let result = values[0].state; values[0] = values.removeLast(); var i = 0
        while i * 2 + 1 < values.count {
            var child = i * 2 + 1
            if child + 1 < values.count && less(child + 1, child) { child += 1 }
            guard less(child, i) else { break }; values.swapAt(child, i); i = child
        }
        return result
    }
    private func less(_ a: Int, _ b: Int) -> Bool {
        values[a].priority == values[b].priority ? values[a].state < values[b].state : values[a].priority < values[b].priority
    }
}
