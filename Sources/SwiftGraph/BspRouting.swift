import Foundation

/// Routes on the bounded segments of the hierarchical BSP visibility graph. By default routes leave and enter
/// through orthogonal side ports, keep `margin` clear of the outermost nodes, prefer fewer bends and finish with
/// `EdgeSeparator`.
public final class BspEdgeRouter: EdgeRouter {
    /// Clearance between the outermost nodes and the outer routing frame.
    public var margin: Double = 20
    /// Extra cost per bend, so straight and single-bend routes beat equal-length staircases.
    public var bendPenalty: Double = 40
    /// Lane spacing for edges sharing a channel; 0 leaves them merged.
    public var edgeSpacing: Double = 6
    /// Edges with no route through the partition; they keep a straight centre-to-centre line.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        let calculator = BspGridCalculator(); calculator.buildTree(graph)
        let global = calculator.getGlobalGridSegments()
        unroutableEdges = []
        // The first four global segments are the frame: top, bottom, left, right.
        let frame = global.count >= 4 ? Rect(x: global[0].start.x, y: global[0].start.y,
                                              width: global[0].end.x - global[0].start.x, height: global[2].end.y - global[2].start.y) : nil
        let blockers = graph.nodes.filter { !$0.isGroup }
        for edge in graph.edges where edge.source !== edge.target {
            if RoutingCompute.isCancelled { return }
            var segments = global + calculator.getLocalGridSegments(edge.source) + calculator.getLocalGridSegments(edge.target)
            if let frame, margin > 0 { segments = Self.expand(segments, frame: frame, by: margin) }
            let obstacles = blockers.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: -1e-6) }
            let path = orthogonalRoute(edge, segments, obstacles)
            if RoutingCompute.isCancelled { return }
            if path == nil { unroutableEdges.append(edge) }
            edge.path = path ?? [edge.source.center, edge.target.center]
        }
        if edgeSpacing > 0 {
            let separator = EdgeSeparator(); separator.spacing = edgeSpacing; separator.routeEdges(graph)
        }
    }
    /// Moves the frame out by `amount`, extending every segment that ended on it.
    private static func expand(_ segments: [(start: Point, end: Point)], frame: Rect, by amount: Double) -> [(start: Point, end: Point)] {
        let outer = frame.inflated(by: amount)
        func move(_ p: Point) -> Point {
            var q = p
            if abs(p.x - frame.left) < 1e-6 { q.x = outer.left } else if abs(p.x - frame.right) < 1e-6 { q.x = outer.right }
            if abs(p.y - frame.top) < 1e-6 { q.y = outer.top } else if abs(p.y - frame.bottom) < 1e-6 { q.y = outer.bottom }
            return q
        }
        return segments.map { (move($0.start), move($0.end)) }
    }
    private func orthogonalRoute(_ edge: LayoutEdge, _ segments: [(start: Point, end: Point)], _ obstacles: [Rect]) -> [Point]? {
        let sources = Self.ports(edge.source.bounds, facing: edge.target.bounds, segments, obstacles)
        let targets = Self.ports(edge.target.bounds, facing: edge.source.bounds, segments, obstacles)
        guard !sources.isEmpty, !targets.isEmpty else { return nil }
        var visibility = BspVisibilityGraph(segments)
        for port in sources + targets { visibility.attach(port.port, to: port.hit) }
        guard let path = visibility.path(from: sources.map(\.port), to: targets.map(\.port), bendPenalty: bendPenalty) else { return nil }
        // Drop straight-through points so aligned neighbours get a single segment.
        var result: [Point] = []
        for p in path {
            if result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                if abs((b.x - a.x) * (p.y - b.y) - (b.y - a.y) * (p.x - b.x)) < 1e-9 { result[result.count - 1] = p; continue }
            }
            result.append(p)
        }
        return result.count >= 2 ? result : nil
    }
    /// Candidate ports on each side (its middle, and positions aligned with the other node), each joined by an
    /// unobstructed perpendicular ray to the first channel it meets.
    private static func ports(_ r: Rect, facing other: Rect, _ segments: [(start: Point, end: Point)], _ obstacles: [Rect]) -> [(port: Point, hit: Point)] {
        func positions(_ lo: Double, _ hi: Double, _ otherLo: Double, _ otherHi: Double) -> [Double] {
            let inset = min(10, (hi - lo) / 4)
            func clamp(_ v: Double) -> Double { min(max(v, lo + inset), hi - inset) }
            var values = [(lo + hi) / 2, clamp((otherLo + otherHi) / 2)]
            if max(lo, otherLo) < min(hi, otherHi) { values.append(clamp((max(lo, otherLo) + min(hi, otherHi)) / 2)) }
            return values.reduce(into: []) { result, v in if !result.contains(where: { abs($0 - v) < 1e-6 }) { result.append(v) } }
        }
        var result: [(port: Point, hit: Point)] = []
        let horizontal = positions(r.left, r.right, other.left, other.right), vertical = positions(r.top, r.bottom, other.top, other.bottom)
        let sides = horizontal.map { (Point(x: $0, y: r.top), Point(x: 0, y: -1)) } + horizontal.map { (Point(x: $0, y: r.bottom), Point(x: 0, y: 1)) }
            + vertical.map { (Point(x: r.left, y: $0), Point(x: -1, y: 0)) } + vertical.map { (Point(x: r.right, y: $0), Point(x: 1, y: 0)) }
        for (port, direction) in sides {
            var best: Point?, distance = Double.infinity
            for s in segments {
                let along = direction.x == 0
                // A ray along y meets horizontal segments spanning the port's x, and vice versa.
                guard along ? abs(s.start.y - s.end.y) < 1e-9 : abs(s.start.x - s.end.x) < 1e-9 else { continue }
                let (lo, hi) = along ? (min(s.start.x, s.end.x), max(s.start.x, s.end.x)) : (min(s.start.y, s.end.y), max(s.start.y, s.end.y))
                let coordinate = along ? port.x : port.y
                guard coordinate >= lo - 1e-6 && coordinate <= hi + 1e-6 else { continue }
                let d = along ? (s.start.y - port.y) * direction.y : (s.start.x - port.x) * direction.x
                if d > 1e-6 && d < distance { distance = d; best = port + direction * d }
            }
            if let hit = best, (RoutingCompute.current.map { $0.hits([port, hit], obstacles).isEmpty } ?? !obstacles.contains(where: { $0.intersectsLine(port, hit) })) { result.append((port, hit)) }
        }
        return result
    }
}

/// Quantize equality and hashing identically: tolerance-only equality severs segment chains.
struct BspPointKey: Hashable {
    var x: Int64; var y: Int64
    init(_ p: Point) { x = Int64(floor(p.x / 1e-4 + 0.5)); y = Int64(floor(p.y / 1e-4 + 0.5)) }
}
struct BspVisibilityGraph {
    private var points: [Point] = []
    private var indices: [BspPointKey: Int] = [:]
    private var adjacency: [[Int]] = []
    private let segments: [(start: Point, end: Point)]
    init(_ segments: [(start: Point, end: Point)]) {
        self.segments = segments
        for s in segments { _ = insert(s.start); _ = insert(s.end) }
        let candidates = RoutingCompute.current?.overlapMatrix(segments)
        for i in segments.indices {
            for j in (i + 1)..<segments.count where candidates == nil || candidates![i * segments.count + j] != 0 {
                if let p = intersection(segments[i], segments[j]) { _ = insert(p) }
            }
        }
        for s in segments {
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
    /// A* over (vertex, axis) states from any start to any end, charging `bendPenalty` per change of axis.
    func path(from starts: [Point], to ends: [Point], bendPenalty: Double) -> [Point]? {
        let goals = Set(ends.compactMap { indices[BspPointKey($0)] })
        func estimate(_ p: Point) -> Double { ends.map { abs($0.x - p.x) + abs($0.y - p.y) }.min() ?? 0 }
        var queue = RoutingPriorityQueue<Int>(), costs: [Int: Double] = [:], previous: [Int: Int] = [:]
        for start in starts {
            guard let a = indices[BspPointKey(start)], costs[a * 3] == nil else { continue }
            costs[a * 3] = 0; queue.push(a * 3, priority: estimate(start))
        }
        var settled = Set<Int>()
        while let state = queue.pop() {
            if RoutingCompute.isCancelled { return nil }
            guard settled.insert(state).inserted else { continue }
            let vertex = state / 3, axis = state % 3
            if goals.contains(vertex) {
                var path = [points[vertex]], cursor = state
                while let p = previous[cursor] { path.append(points[p / 3]); cursor = p }
                return path.reversed()
            }
            for next in adjacency[vertex] {
                let d = points[next] - points[vertex]
                let nextAxis = abs(d.x) >= abs(d.y) ? 1 : 2
                let cost = costs[state]! + abs(d.x) + abs(d.y) + (axis != 0 && axis != nextAxis ? bendPenalty : 0)
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
