import Foundation

/// Shortest polyline that keeps `padding` clear of every obstacle. Ports are not interpreted.
/// Set `avoidAllObstacles = false` for the C# reference's two-corner detour around the first intersected obstacle.
public final class PolylineEdgeRouter: EdgeRouter {
    public var padding: Double = 10
    public var avoidAllObstacles = true
    /// Empty in legacy mode. Impossible routes keep the legacy detour so the edge stays visible.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = []
        guard !graph.nodes.isEmpty else { return }
        let tree = QuadTree<LayoutNode>(bounds: enclosingBounds(graph.nodes).inflated(by: 500))
        for node in graph.nodes { tree.insert(bounds: node.bounds, item: node) }
        for edge in graph.edges where edge.source !== edge.target {
            if Task.isCancelled { return }
            let start = edge.source.center, end = edge.target.center
            let area = Rect(x: min(start.x, end.x) - padding, y: min(start.y, end.y) - padding, width: abs(start.x - end.x) + padding * 2, height: abs(start.y - end.y) + padding * 2)
            var candidates: [LayoutNode] = []
            tree.query(area, results: &candidates)
            let obstacle = candidates.first { node in
                node !== edge.source && node !== edge.target && !(node.isGroup && (isAncestor(node, of: edge.source) || isAncestor(node, of: edge.target))) && node.bounds.intersectsLine(start, end)
            }
            edge.path = [start]
            if let obstacle { edge.path += detour(start, end, obstacle.bounds) }
            edge.path.append(end)
            if avoidAllObstacles {
                let obstacles = ObstaclePolyline.obstacles(edge, graph)
                if !ObstaclePolyline.clear(edge.path, obstacles) {
                    let path = ObstaclePolyline.search(start, end, obstacles, padding: padding)
                    if Task.isCancelled { return }
                    if let path { edge.path = path } else { unroutableEdges.append(edge) }
                }
            }
        }
    }
    private func detour(_ start: Point, _ end: Point, _ bounds: Rect) -> [Point] {
        let horizontal = abs(end.x - start.x) > abs(end.y - start.y)
        let mid = (start + end) / 2
        let primarySide = horizontal ? mid.y < bounds.center.y : mid.x < bounds.center.x
        func build(_ before: Bool) -> [Point] {
            if horizontal {
                let y = before ? bounds.top - padding : bounds.bottom + padding
                return [Point(x: bounds.left - padding, y: y), Point(x: bounds.right + padding, y: y)]
            }
            let x = before ? bounds.left - padding : bounds.right + padding
            return [Point(x: x, y: bounds.top - padding), Point(x: x, y: bounds.bottom + padding)]
        }
        func crosses(_ points: [Point]) -> Bool {
            let path = [start] + points + [end]
            return zip(path, path.dropFirst()).contains { bounds.intersectsLine($0, $1) }
        }
        let primary = build(primarySide)
        if !crosses(primary) { return primary }
        let fallback = build(!primarySide)
        return crosses(fallback) ? primary : fallback
    }
}

/// Shared by layout repairs; legacy routing never calls this search.
enum ObstaclePolyline {
    static func obstacles(_ edge: LayoutEdge, _ graph: LayoutGraph) -> [Rect] {
        graph.nodes.filter {
            $0 !== edge.source && $0 !== edge.target &&
            !($0.isGroup && (isAncestor($0, of: edge.source) || isAncestor($0, of: edge.target)))
        }.map(\.bounds).filter { $0.width > 0 && $0.height > 0 }
    }
    static func clear(_ path: [Point], _ obstacles: [Rect]) -> Bool {
        path.count >= 2 && !zip(path, path.dropFirst()).contains { a, b in
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
            if Task.isCancelled { return nil }
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
        var distance = Array(repeating: Double.infinity, count: points.count)
        var previous = Array(repeating: -1, count: points.count), visited = Array(repeating: false, count: points.count)
        distance[0] = 0
        for _ in points.indices {
            if Task.isCancelled { return nil }
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
                if next % 64 == 0 && Task.isCancelled { return nil }
                let candidate = distance[current] + (points[current] - points[next]).length
                if candidate < distance[next] && visible(points[current], points[next]) {
                    distance[next] = candidate; previous[next] = current
                }
            }
        }
        return nil
    }
    static func repair(_ graph: LayoutGraph, edges: [LayoutEdge]? = nil) {
        for edge in edges ?? graph.edges where edge.source !== edge.target {
            if Task.isCancelled { return }
            let obstacles = obstacles(edge, graph)
            if clear(edge.path, obstacles) { continue }
            let path = search(edge.source.center, edge.target.center, obstacles, padding: 10)
            if Task.isCancelled { return }
            edge.path = path ?? []
        }
    }
}
