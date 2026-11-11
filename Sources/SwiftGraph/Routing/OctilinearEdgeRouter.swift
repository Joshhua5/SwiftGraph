import Foundation

/// Straight, or one 45-degree stretch and one axis-aligned stretch. Each edge takes the diagonal at its start or its
/// end,
/// whichever avoids nodes, then siblings' shared stretches, then bends that sit on another route.
public final class OctilinearEdgeRouter: EdgeRouter {
    public init() {}

    public func routeEdges(_ graph: LayoutGraph) {
        graph.routeStyle = .octilinear
        let edges = graph.edges.filter { $0.source !== $0.target }
        let bends = RoutingCompute.current?.octilinear(edges.map { $0.source.center }, edges.map { $0.target.center })
        var routed: [(edge: LayoutEdge, path: [Point])] = []
        // Edges with a single possible route go first, so the ones with a choice can steer clear of them.
        func bendOf(_ e: LayoutEdge) -> Point? {
            let a = e.source.center
            let b = e.target.center
            let d = b - a
            let diagonal = min(abs(d.x), abs(d.y))
            let bend = a + Point(x: d.x >= 0 ? diagonal : -diagonal, y: d.y >= 0 ? diagonal : -diagonal)
            return (bend - a).length > 1 && (bend - b).length > 1 ? bend : nil
        }
        for e in edges where bendOf(e) == nil {
            e.path = [e.source.center, e.target.center]
            routed.append((e, e.path))
        }
        for (i, e) in edges.enumerated() {
            if RoutingCompute.isCancelled { return }
            LayoutStageScope.tick(i, of: edges.count)
            let a = e.source.center
            let b = e.target.center
            guard let bend = bendOf(e) else { continue }
            let first = bends?[i] ?? bend
            let options = [[a, first, b], [a, b - (first - a), b]]
            let obstacles = ObstaclePolyline.obstacles(e, graph)
            let scores = options.enumerated()
                .map { k, path -> [Int] in
                    let segments = Array(zip(path, path.dropFirst()))
                    let hits = obstacles.filter { r in segments.contains { r.intersectsLine($0.0, $0.1) } }.count
                    var shared = 0
                    var onRoute = 0
                    for other in routed {
                        let sibling =
                            other.edge.source === e.source || other.edge.target === e.source
                            || other.edge.source === e.target || other.edge.target === e.target
                        for (c, f) in zip(other.path, other.path.dropFirst()) {
                            if sibling && segments.contains(where: { overlaps($0.0, $0.1, c, f) }) { shared += 1 }
                            if onSegment(path[1], c, f) { onRoute += 1 }
                        }
                    }
                    return [hits, shared, onRoute, k]
                }
            // `scores` maps the two `options`, so it is never empty.
            let best = scores.indices.min { scores[$0].lexicographicallyPrecedes(scores[$1]) }!
            e.path = options[best]
            routed.append((e, e.path))
        }
    }
}

/// Shifts the interior vertices of `path` sideways by `offset` (mitred, capped); the ends stay where they are.
func offsetPolyline(_ path: [Point], by offset: Float) -> [Point] {
    guard path.count > 2 else { return path }
    func normal(_ a: Point, _ b: Point) -> Point {
        let d = b - a
        let l = max(1e-6, d.length)
        return Point(x: -d.y / l, y: d.x / l)
    }
    return path.indices.map { i in
        guard i > 0 && i < path.count - 1 else { return path[i] }
        let n1 = normal(path[i - 1], path[i])
        let n2 = normal(path[i], path[i + 1])
        let sum = n1 + n2
        let l = sum.length
        guard l > 1e-6 else { return path[i] }
        return path[i] + sum / l * (offset / max(0.5, l / 2))
    }
}
