import Foundation

/// Routes on the bounded segments of the hierarchical BSP visibility graph: every cut at every depth, plus lanes round
/// nodes no straight cut separates. By default routes leave and enter through orthogonal side ports, keep `margin`
/// clear of the outermost nodes, prefer fewer bends and finish with `EdgeSeparator`. Source and target port
/// constraints and candidates choose the sides; without them, a graph whose edges mostly run one way prefers leaving
/// on the downstream side and entering on the upstream one. Edges with no route through the partition are retried
/// without port constraints, then drawn as an obstacle-aware polyline or an orthogonal L/Z, and reported.
/// Unusually long partition routes are compared with a finer channel route before lane separation.
public final class BspEdgeRouter: EdgeRouter {
    /// Clearance between the outermost nodes and the outer routing frame.
    public var margin: Float = 20
    /// Extra cost per bend, so straight and single-bend routes beat equal-length staircases.
    public var bendPenalty: Float = 40
    /// Lane spacing for edges sharing a channel; 0 leaves them merged.
    public var edgeSpacing: Float = 10
    /// Edges with no route through the partition: a polyline, L/Z or straight line was drawn instead.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        let calculator = BspGridCalculator(); calculator.buildTree(graph)
        var segments = calculator.getAllGridSegments()
        unroutableEdges = []
        // The first four segments are the frame: top, bottom, left, right.
        let frame = segments.count >= 4 ? Rect(x: segments[0].start.x, y: segments[0].start.y,
                                                width: segments[0].end.x - segments[0].start.x, height: segments[2].end.y - segments[2].start.y) : nil
        if let frame, margin > 0 { segments = Self.expand(segments, frame: frame, by: margin) }
        let flow = OrthogonalPorts.flow(graph).direction
        // One graph for every edge; each edge only adds its own port stubs to a copy.
        let base = segments.isEmpty ? nil : LayoutStageScope.run("Visibility graph", to: 0.2) { BspVisibilityGraph(segments) }
        let blockers = BspBlockers(graph)
        let routing = LayoutStageScope.begin("Route", from: 0.2)
        for (position, edge) in graph.edges.enumerated() where edge.source !== edge.target {
            if RoutingCompute.isCancelled { return }
            routing.tick(position, of: graph.edges.count)
            let obstacles = ObstaclePolyline.obstacles(edge, graph).map(ObstaclePolyline.interior)
            let cuts = blockers.cuts(for: edge)
            var path = base.flatMap { orthogonalRoute(edge, $0, segments, obstacles, cuts, flow: flow, constrained: true) }
            if path == nil, edge.sourcePort != .none || edge.targetPort != .none || !edge.sourcePortCandidates.isEmpty || !edge.targetPortCandidates.isEmpty {
                path = base.flatMap { orthogonalRoute(edge, $0, segments, obstacles, cuts, flow: flow, constrained: false) }
            }
            if RoutingCompute.isCancelled { return }
            if path == nil { unroutableEdges.append(edge); path = RoutingFallback.route(edge, graph) }
            if let current = path, ObstaclePolyline.length(current) > 4 * max(1, (edge.target.center - edge.source.center).length) {
                let candidate = LayoutEdge(source: edge.source, target: edge.target)
                candidate.sourcePort = edge.sourcePort; candidate.targetPort = edge.targetPort
                candidate.sourcePortCandidates = edge.sourcePortCandidates; candidate.targetPortCandidates = edge.targetPortCandidates
                let local = LayoutGraph(); local.nodes = graph.nodes; local.edges = [candidate]
                let router = ChannelEdgeRouter(); router.gridSize = 10; router.congestionPenalty = 0
                router.routeEdges(local)
                if router.unroutableEdges.isEmpty, ObstaclePolyline.Scene(graph.nodes).clear(candidate.path, edge),
                   zip(candidate.path, candidate.path.dropFirst()).allSatisfy({ abs($0.x - $1.x) < 1e-4 || abs($0.y - $1.y) < 1e-4 }),
                   ObstaclePolyline.length(candidate.path) < ObstaclePolyline.length(current) * 0.75 {
                    path = candidate.path
                    unroutableEdges.removeAll { $0 === edge }
                }
            }
            edge.path = path!
        }
        routing.end()
        if edgeSpacing > 0 {
            let separator = EdgeSeparator(); separator.spacing = edgeSpacing; separator.routeEdges(graph)
        }
    }
    /// Moves the frame out by `amount`, extending every segment that ended on it.
    private static func expand(_ segments: [(start: Point, end: Point)], frame: Rect, by amount: Float) -> [(start: Point, end: Point)] {
        let outer = frame.inflated(by: amount)
        func move(_ p: Point) -> Point {
            var q = p
            if abs(p.x - frame.left) < 1e-5 { q.x = outer.left } else if abs(p.x - frame.right) < 1e-5 { q.x = outer.right }
            if abs(p.y - frame.top) < 1e-5 { q.y = outer.top } else if abs(p.y - frame.bottom) < 1e-5 { q.y = outer.bottom }
            return q
        }
        return segments.map { (move($0.start), move($0.end)) }
    }
    private func sides(_ active: PortConstraint, _ candidates: [PortConstraint]) -> Set<PortConstraint>? {
        let allowed = active != .none ? [active] : candidates.filter { $0 != .none }
        return allowed.isEmpty ? nil : Set(allowed)
    }
    /// Cost of using a side: nothing when it follows the flow, half a bend sideways, a bend against it.
    private func sideCost(_ side: PortConstraint, desired: Point?) -> Float {
        guard let desired else { return 0 }
        let d = portDirection(side), dot = d.x * desired.x + d.y * desired.y
        return dot > 0 ? 0 : dot < 0 ? bendPenalty : bendPenalty / 2
    }
    private func orthogonalRoute(_ edge: LayoutEdge, _ base: BspVisibilityGraph, _ segments: [(start: Point, end: Point)], _ obstacles: [Rect],
                                 _ cuts: @escaping (Point, Point) -> Bool, flow: Point?, constrained: Bool) -> [Point]? {
        let from = constrained ? sides(edge.sourcePort, edge.sourcePortCandidates) : nil, to = constrained ? sides(edge.targetPort, edge.targetPortCandidates) : nil
        let sources = Self.ports(edge.source.bounds, facing: edge.target.bounds, segments, obstacles).filter { from?.contains($0.side) ?? true }
        let targets = Self.ports(edge.target.bounds, facing: edge.source.bounds, segments, obstacles).filter { to?.contains($0.side) ?? true }
        guard !sources.isEmpty, !targets.isEmpty else { return nil }
        var visibility = base
        for port in sources + targets { visibility.attach(port.port, to: port.hit) }
        let leaving = flow, entering = flow.map { $0 * -1 }
        guard let path = visibility.path(from: sources.map { ($0.port, sideCost($0.side, desired: leaving)) }, to: targets.map { ($0.port, sideCost($0.side, desired: entering)) }, bendPenalty: bendPenalty, blocked: cuts) else { return nil }
        // Drop straight-through points so aligned neighbours get a single segment.
        var result: [Point] = []
        for p in path {
            if result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                if abs((b.x - a.x) * (p.y - b.y) - (b.y - a.y) * (p.x - b.x)) < 1e-5 { result[result.count - 1] = p; continue }
            }
            result.append(p)
        }
        return result.count >= 2 && ObstaclePolyline.clear(result, obstacles) ? result : nil
    }
    /// Candidate ports on each side (its middle, and positions aligned with the other node), each joined by an
    /// unobstructed perpendicular ray to the first channel it meets.
    private static func ports(_ r: Rect, facing other: Rect, _ segments: [(start: Point, end: Point)], _ obstacles: [Rect]) -> [(port: Point, hit: Point, side: PortConstraint)] {
        func positions(_ lo: Float, _ hi: Float, _ otherLo: Float, _ otherHi: Float) -> [Float] {
            let inset = min(10, (hi - lo) / 4)
            func clamp(_ v: Float) -> Float { min(max(v, lo + inset), hi - inset) }
            var values = [(lo + hi) / 2, clamp((otherLo + otherHi) / 2)]
            if max(lo, otherLo) < min(hi, otherHi) { values.append(clamp((max(lo, otherLo) + min(hi, otherHi)) / 2)) }
            return values.reduce(into: []) { result, v in if !result.contains(where: { abs($0 - v) < 1e-5 }) { result.append(v) } }
        }
        var result: [(port: Point, hit: Point, side: PortConstraint)] = []
        let horizontal = positions(r.left, r.right, other.left, other.right), vertical = positions(r.top, r.bottom, other.top, other.bottom)
        let sides = horizontal.map { (Point(x: $0, y: r.top), Point(x: 0, y: -1), PortConstraint.top) } + horizontal.map { (Point(x: $0, y: r.bottom), Point(x: 0, y: 1), PortConstraint.bottom) }
            + vertical.map { (Point(x: r.left, y: $0), Point(x: -1, y: 0), PortConstraint.left) } + vertical.map { (Point(x: r.right, y: $0), Point(x: 1, y: 0), PortConstraint.right) }
        for (port, direction, side) in sides {
            var best: Point?, distance = Float.infinity
            for s in segments {
                let along = direction.x == 0
                // A ray along y meets horizontal segments spanning the port's x, and vice versa.
                guard along ? abs(s.start.y - s.end.y) < 1e-5 : abs(s.start.x - s.end.x) < 1e-5 else { continue }
                let (lo, hi) = along ? (min(s.start.x, s.end.x), max(s.start.x, s.end.x)) : (min(s.start.y, s.end.y), max(s.start.y, s.end.y))
                let coordinate = along ? port.x : port.y
                guard coordinate >= lo - 1e-5 && coordinate <= hi + 1e-5 else { continue }
                let d = along ? (s.start.y - port.y) * direction.y : (s.start.x - port.x) * direction.x
                if d > 1e-5 && d < distance { distance = d; best = port + direction * d }
            }
            if let hit = best {
                let clear: Bool
                if let compute = RoutingCompute.current {
                    clear = compute.hits([port, hit], obstacles).isEmpty
                } else {
                    clear = !obstacles.contains(where: { $0.intersectsLine(port, hit) })
                }
                if clear { result.append((port, hit, side)) }
            }
        }
        return result
    }
}

/// Every node interior and group title of one routing pass in a single tree. An edge's links are tested against
/// exactly the rects `ObstaclePolyline.obstacles(edge, graph).map(ObstaclePolyline.interior)` holds, without
/// rebuilding a tree for each edge.
private struct BspBlockers {
    private let nodes: [LayoutNode]
    private let tree: QuadTree<(node: Int, header: Bool)>
    init(_ graph: LayoutGraph) {
        nodes = graph.nodes
        var entries: [(rect: Rect, node: Int, header: Bool)] = []
        func add(_ r: Rect, _ node: Int, header: Bool) {
            guard r.width > 0 && r.height > 0 else { return }
            let inner = ObstaclePolyline.interior(r)
            if inner.width > 0 && inner.height > 0 { entries.append((inner, node, header)) }
        }
        for (i, n) in nodes.enumerated() { add(n.bounds, i, header: false) }
        for (i, n) in nodes.enumerated() { if let title = n.groupTitleBounds { add(title, i, header: true) } }
        let bounds = entries.first.map { first in entries.dropFirst().reduce(first.rect) { $0.union($1.rect) } } ?? Rect()
        tree = QuadTree(bounds: bounds.inflated(by: 1))
        for e in entries { tree.insert(bounds: e.rect, item: (e.node, e.header)) }
    }
    /// Whether a link of `edge` is cut: its own ends, and groups containing them, are not obstacles; titles are,
    /// unless they belong to an end.
    func cuts(for edge: LayoutEdge) -> (Point, Point) -> Bool {
        let s = edge.source, t = edge.target
        let end = nodes.map { $0 === s || $0 === t }
        let body = nodes.indices.map { i in !end[i] && !(nodes[i].isGroup && (isAncestor(nodes[i], of: s) || isAncestor(nodes[i], of: t))) }
        let tree = tree
        return { a, b in
            tree.contains(intersecting: RoutingCompute.bounds(a, b).inflated(by: 1e-4)) { r, entry in
                (entry.header ? !end[entry.node] : body[entry.node]) && r.intersectsLine(a, b)
            }
        }
    }
}

/// Quantize equality and hashing identically: tolerance-only equality severs segment chains.
struct BspPointKey: Hashable {
    var x: Int64; var y: Int64
    init(_ p: Point) { x = Int64(floor(Double(p.x) / 1e-4 + 0.5)); y = Int64(floor(Double(p.y) / 1e-4 + 0.5)) }
}
struct BspVisibilityGraph {
    private var points: [Point] = []
    private var indices: [BspPointKey: Int] = [:]
    private var adjacency: [[Int]] = []
    private let segments: [(start: Point, end: Point)]
    init(_ segments: [(start: Point, end: Point)]) {
        self.segments = segments
        for s in segments { _ = insert(s.start); _ = insert(s.end) }
        if let candidates = RoutingCompute.current?.overlapPairs(segments) {
            for i in segments.indices {
                if RoutingCompute.isCancelled { return }
                for j in candidates[i] {
                    if let p = intersection(segments[i], segments[j]) { _ = insert(p) }
                }
            }
        } else {
            for i in segments.indices {
                if RoutingCompute.isCancelled { return }
                for j in (i + 1)..<segments.count {
                    if let p = intersection(segments[i], segments[j]) { _ = insert(p) }
                }
            }
        }
        for s in segments {
            if RoutingCompute.isCancelled { return }
            let vertical = abs(s.start.x - s.end.x) < 0.001
            let on = points.indices.filter { onSegment(s, points[$0]) }.sorted { vertical ? points[$0].y < points[$1].y : points[$0].x < points[$1].x }
            for (a, b) in zip(on, on.dropFirst()) { link(a, b) }
        }
    }
    @discardableResult private mutating func insert(_ p: Point) -> Int {
        let key = BspPointKey(p)
        if let i = indices[key] { return i }
        let i = points.count; points.append(p); adjacency.append([]); indices[key] = i; return i
    }
    private mutating func link(_ a: Int, _ b: Int) { adjacency[a].append(b); adjacency[b].append(a) }
    /// Joins a side port to its hit point, splicing the hit into every segment it lies on.
    mutating func attach(_ port: Point, to hit: Point) {
        let existing = indices[BspPointKey(hit)] != nil, h = insert(hit)
        if !existing {
            for s in segments where onSegment(s, hit) {
                let vertical = abs(s.start.x - s.end.x) < 0.001
                let along = { (p: Point) in vertical ? p.y : p.x }
                let on = points.indices.filter { $0 != h && onSegment(s, points[$0]) }
                if let before = on.filter({ along(points[$0]) < along(hit) }).max(by: { along(points[$0]) < along(points[$1]) }) { link(h, before) }
                if let after = on.filter({ along(points[$0]) > along(hit) }).min(by: { along(points[$0]) < along(points[$1]) }) { link(h, after) }
            }
        }
        if BspPointKey(port) != BspPointKey(hit) { link(insert(port), h) }
    }
    func path(from starts: [Point], to ends: [Point], bendPenalty: Float) -> [Point]? {
        path(from: starts.map { ($0, 0) }, to: ends.map { ($0, 0) }, bendPenalty: bendPenalty)
    }
    /// A* over (vertex, axis) states from any start to any end, charging `bendPenalty` per change of axis and each
    /// port's own cost for starting or finishing there.
    /// `blocked` replaces `obstacles` when the caller already indexes them: it reports whether a link is cut.
    func path(from starts: [(Point, Float)], to ends: [(Point, Float)], bendPenalty: Float, obstacles: [Rect] = [],
              blocked: ((Point, Point) -> Bool)? = nil) -> [Point]? {
        let cuts: (Point, Point) -> Bool
        if let blocked { cuts = blocked } else {
            let obstacleBounds = obstacles.first.map { first in obstacles.dropFirst().reduce(first) { $0.union($1) } } ?? Rect()
            let tree = QuadTree<Rect>(bounds: obstacleBounds.inflated(by: 1))
            for r in obstacles where r.width > 0 && r.height > 0 { tree.insert(bounds: r, item: r) }
            cuts = { a, b in tree.contains(intersecting: RoutingCompute.bounds(a, b).inflated(by: 1e-4)) { r, _ in r.intersectsLine(a, b) } }
        }
        var goals: [Int: Float] = [:]
        for (p, c) in ends { if let i = indices[BspPointKey(p)], c < goals[i, default: .infinity] { goals[i] = c } }
        let targets = ends.map(\.0)
        func estimate(_ p: Point) -> Float {
            var best = Float.infinity
            for t in targets { best = min(best, abs(t.x - p.x) + abs(t.y - p.y)) }
            return targets.isEmpty ? 0 : best
        }
        var queue = RoutingPriorityQueue<Int>(), costs: [Int: Float] = [:], previous: [Int: Int] = [:]
        for (start, cost) in starts {
            guard let a = indices[BspPointKey(start)], cost < costs[a * 3, default: .infinity] else { continue }
            costs[a * 3] = cost; queue.push(a * 3, priority: cost + estimate(start))
        }
        var settled = Set<Int>()
        while let state = queue.pop() {
            if RoutingCompute.isCancelled { return nil }
            guard settled.insert(state).inserted else { continue }
            let vertex = state / 3, axis = state % 3
            if goals[vertex] != nil {
                var path = [points[vertex]], cursor = state
                while let p = previous[cursor] { path.append(points[p / 3]); cursor = p }
                return path.reversed()
            }
            for next in adjacency[vertex] {
                let a = points[vertex], b = points[next]
                if cuts(a, b) { continue }
                let d = points[next] - points[vertex]
                let nextAxis = abs(d.x) >= abs(d.y) ? 1 : 2
                let cost = costs[state]! + abs(d.x) + abs(d.y) + (axis != 0 && axis != nextAxis ? bendPenalty : 0) + (goals[next] ?? 0)
                let key = next * 3 + nextAxis
                if cost < costs[key, default: .infinity] {
                    costs[key] = cost; previous[key] = state
                    queue.push(key, priority: cost + estimate(points[next]))
                }
            }
        }
        return nil
    }
    private func onSegment(_ s: (start: Point, end: Point), _ p: Point) -> Bool { abs((s.start - p).length + (p - s.end).length - (s.start - s.end).length) < 0.001 }
    private func intersection(_ a: (start: Point, end: Point), _ b: (start: Point, end: Point)) -> Point? {
        let da = a.end - a.start, db = b.end - b.start
        let denominator = db.y * da.x - db.x * da.y
        if denominator == 0 { return nil }
        let delta = a.start - b.start
        let u = (db.x * delta.y - db.y * delta.x) / denominator
        let v = (da.x * delta.y - da.y * delta.x) / denominator
        return u >= 0 && u <= 1 && v >= 0 && v <= 1 ? a.start + da * u : nil
    }
}
