import Foundation

/// Shortest polyline that keeps `padding` clear of every obstacle, finished with `EdgeSeparator`.
/// Ports are not interpreted.
public final class PolylineEdgeRouter: EdgeRouter {
    public var padding: Double = 10
    /// Spreads edges sharing a collinear stretch this far apart; 0 leaves them overlapping.
    public var edgeSpacing: Double = 6
    /// Edges with no clear route; they keep a straight centre-to-centre line so they stay visible.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = []
        guard !graph.nodes.isEmpty else { return }
        for edge in graph.edges where edge.source !== edge.target {
            if RoutingCompute.isCancelled { return }
            let start = edge.source.center, end = edge.target.center
            let obstacles = ObstaclePolyline.obstacles(edge, graph)
            var path = [start, end]
            if !ObstaclePolyline.clear(path, obstacles) {
                let found = ObstaclePolyline.search(start, end, obstacles, padding: padding)
                if RoutingCompute.isCancelled { return }
                if let found { path = found } else { unroutableEdges.append(edge) }
            }
            edge.path = path
        }
        if edgeSpacing > 0 {
            let separator = EdgeSeparator(); separator.spacing = edgeSpacing; separator.routeEdges(graph)
        }
    }
}

/// Obstacle-aware visibility search, shared by the polyline router and layout repairs.
enum ObstaclePolyline {
    static func obstacles(_ edge: LayoutEdge, _ graph: LayoutGraph) -> [Rect] {
        graph.nodes.filter {
            $0 !== edge.source && $0 !== edge.target &&
            !($0.isGroup && (isAncestor($0, of: edge.source) || isAncestor($0, of: edge.target)))
        }.map(\.bounds).filter { $0.width > 0 && $0.height > 0 }
    }
    static func clear(_ path: [Point], _ obstacles: [Rect]) -> Bool {
        if let compute = RoutingCompute.current { return path.count >= 2 && compute.hits(path, obstacles).isEmpty }
        return path.count >= 2 && !zip(path, path.dropFirst()).contains { a, b in
            obstacles.contains { $0.intersectsLine(a, b) }
        }
    }
    static func search(_ start: Point, _ end: Point, _ obstacles: [Rect], padding: Double) -> [Point]? {
        guard !obstacles.contains(where: { $0.contains(start) || $0.contains(end) }) else { return nil }
        if clear([start, end], obstacles) { return [start, end] }
        var points = [start, end], seen: Set<Point> = [start, end]
        let gap = padding.isFinite ? max(1e-5, padding) : 10
        func distance(_ p: Point, _ r: Rect) -> Double {
            max(0, max(max(r.left - p.x, p.x - r.right), max(r.top - p.y, p.y - r.bottom)))
        }
        // Near endpoints may need less padding, but never less body clearance.
        let expanded = obstacles.map { r -> (Rect, Rect) in
            let clearance = min(gap, min(distance(start, r), distance(end, r)) / 2)
            let padded = r.inflated(by: clearance)
            return (padded, padded.inflated(by: -min(1e-7, clearance / 2)))
        }
        let blocking = expanded.map { $0.1 }
        for (r, _) in expanded {
            if RoutingCompute.isCancelled { return nil }
            for point in [Point(x: r.left, y: r.top), Point(x: r.right, y: r.top),
                          Point(x: r.right, y: r.bottom), Point(x: r.left, y: r.bottom)] {
                if !blocking.contains(where: { $0.contains(point) }), seen.insert(point).inserted { points.append(point) }
            }
        }
        let bounds = blocking.dropFirst().reduce(blocking[0]) { $0.union($1) }.inflated(by: 1)
        let tree = QuadTree<Rect>(bounds: bounds)
        for r in blocking { tree.insert(bounds: r, item: r) }
        func visible(_ a: Point, _ b: Point) -> Bool {
            let area = Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).inflated(by: 1e-6)
            return !tree.query(area).contains { $0.intersectsLine(a, b) }
        }
        let metalVisibility = RoutingCompute.current?.visibility(points, blocking)
        var distance = Array(repeating: Double.infinity, count: points.count)
        var previous = Array(repeating: -1, count: points.count), visited = Array(repeating: false, count: points.count)
        distance[0] = 0
        for _ in points.indices {
            if RoutingCompute.isCancelled { return nil }
            guard let current = points.indices.filter({ !visited[$0] && distance[$0].isFinite }).min(by: {
                distance[$0] == distance[$1] ? $0 < $1 : distance[$0] < distance[$1]
            }) else { return nil }
            if current == 1 {
                var result = [end], index = 1
                while previous[index] >= 0 { index = previous[index]; result.append(points[index]) }
                return result.reversed()
            }
            visited[current] = true
            for next in points.indices where !visited[next] {
                if next % 64 == 0 && RoutingCompute.isCancelled { return nil }
                let candidate = distance[current] + (points[current] - points[next]).length
                if candidate < distance[next] && (metalVisibility?[current * points.count + next] ?? visible(points[current], points[next])) {
                    distance[next] = candidate; previous[next] = current
                }
            }
        }
        return nil
    }
    static func repair(_ graph: LayoutGraph, edges: [LayoutEdge]? = nil) {
        for edge in edges ?? graph.edges where edge.source !== edge.target {
            if RoutingCompute.isCancelled { return }
            let obstacles = obstacles(edge, graph)
            if clear(edge.path, obstacles) { continue }
            let path = search(edge.source.center, edge.target.center, obstacles, padding: 10)
            if RoutingCompute.isCancelled { return }
            edge.path = path ?? []
        }
    }
}
