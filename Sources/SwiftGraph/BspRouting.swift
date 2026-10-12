import Foundation

/// Routes on the bounded segments of the hierarchical BSP visibility graph.
public final class BspEdgeRouter: EdgeRouter {
    /// Searches that used the reference's direct-line fallback.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        let calculator = BspGridCalculator(); calculator.buildTree(graph)
        let global = calculator.getGlobalGridSegments()
        unroutableEdges = []
        for edge in graph.edges where edge.source !== edge.target {
            if Task.isCancelled { return }
            let segments = global + calculator.getLocalGridSegments(edge.source) + calculator.getLocalGridSegments(edge.target)
            var visibility = BspVisibilityGraph(segments)
            let start = boundary(edge.source.bounds, toward: edge.target.center), end = boundary(edge.target.bounds, toward: edge.source.center)
            visibility.connect(start, segments: segments); visibility.connect(end, segments: segments)
            let found = visibility.path(from: start, to: end)
            if Task.isCancelled { return }
            var path = found ?? [start, end]
            let length = zip(path, path.dropFirst()).reduce(0.0) { $0 + ($1.1 - $1.0).length }
            if path.count < 2 || length < 0.5 { path = [edge.source.center, edge.target.center] }
            if found == nil || length < 0.5 { unroutableEdges.append(edge) }
            edge.path = path
        }
    }
    private func boundary(_ r: Rect, toward target: Point) -> Point {
        let c = r.center, d = target - c
        if d == .zero { return c }
        var t = Double.infinity
        if d.x > 0 { t = min(t, (r.right - c.x) / d.x) }
        if d.x < 0 { t = min(t, (r.left - c.x) / d.x) }
        if d.y > 0 { t = min(t, (r.bottom - c.y) / d.y) }
        if d.y < 0 { t = min(t, (r.top - c.y) / d.y) }
        return c + d * t
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
    init(_ segments: [(start: Point, end: Point)]) {
        for s in segments { _ = insert(s.start); _ = insert(s.end) }
        for i in segments.indices {
            for j in (i + 1)..<segments.count {
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
    mutating func connect(_ p: Point, segments: [(start: Point, end: Point)]) {
        if indices[BspPointKey(p)] != nil { return }
        var closest: (start: Point, end: Point)?, projection = p, distance = Double.infinity
        for s in segments {
            let d = s.end - s.start
            let t = d.lengthSquared == 0 ? 0 : max(0, min(1, ((p.x - s.start.x) * d.x + (p.y - s.start.y) * d.y) / d.lengthSquared))
            let q = s.start + d * t, length = (q - p).length
            if length < distance { distance = length; projection = q; closest = s }
        }
        guard let closest else { return }
        if BspPointKey(p) == BspPointKey(projection) { projection = p }
        let a = insert(p), b = insert(projection); link(a, b)
        // Match the reference's two nearest existing points on this bounded segment.
        let neighbors = points.indices.filter { $0 != b && onSegment(closest, points[$0]) }.sorted { (points[$0] - projection).length < (points[$1] - projection).length }.prefix(2)
        for n in neighbors { link(b, n) }
    }
    func path(from start: Point, to end: Point) -> [Point]? {
        guard let a = indices[BspPointKey(start)], let b = indices[BspPointKey(end)] else { return nil }
        var queue = RoutingPriorityQueue<(Int, Point)>(), costs = [a: 0.0], previous: [Int: Point] = [:]
        queue.push((a, start), priority: 0)
        while let (current, currentPoint) = queue.pop() {
            if Task.isCancelled { return nil }
            if current == b {
                var p = currentPoint, path = [p]
                while let predecessor = previous[indices[BspPointKey(p)]!] { p = predecessor; path.append(p) }
                path.reverse(); return path.count >= 2 ? path : [start, end]
            }
            for next in adjacency[current] {
                let cost = costs[current]! + (currentPoint - points[next]).length
                if cost < costs[next, default: .infinity] {
                    costs[next] = cost; previous[next] = currentPoint
                    queue.push((next, points[next]), priority: cost + (points[next] - end).length)
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
