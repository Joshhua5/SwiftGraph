import Foundation

/// Edges between the same two nodes get lanes spread either side of the straight line. When a lane would cross a node
/// the group follows the shortest way round instead, with the lanes spread along it; a lone edge keeps its route.
public final class ParallelEdgeRouter: EdgeRouter {
    public var edgeSpacing: Float = 20

    /// Fallbacks are lanes that follow the way round; unroutable edges are lanes that cut a node with no clear way
    /// round. A lone edge's route is not checked.
    public private(set) var report = RoutingReport()

    public init() {}

    public func routeEdges(_ graph: LayoutGraph) {
        var failed: [LayoutEdge] = []
        var fellBack: [LayoutEdge] = []
        defer { report = RoutingReport(graph, unroutable: failed, fallbacks: fellBack) }
        var groups: [Set<LayoutNode>: [LayoutEdge]] = [:]
        for e in graph.edges where e.source !== e.target { groups[[e.source, e.target], default: []].append(e) }
        for (position, edges) in groups.values.enumerated() {
            if RoutingCompute.isCancelled { return }
            if position & 15 == 0 { LayoutStageScope.tick(position, of: groups.count) }
            guard edges.count > 1 else {
                if edges[0].path.count < 2 { edges[0].path = [edges[0].source.center, edges[0].target.center] }
                continue
            }
            let a = edges[0].source.center
            let b = edges[0].target.center
            let delta = b - a
            let length = max(0.001, delta.length)
            let normal = Point(x: -delta.y / length, y: delta.x / length)
            let offsets = edges.indices.map { (Float($0) - Float(edges.count - 1) / 2) * edgeSpacing }
            let midpoints = RoutingCompute.current?
                .parallel(
                    Array(repeating: a, count: edges.count),
                    Array(repeating: b, count: edges.count),
                    offsets: offsets
                )
            let obstacles = ObstaclePolyline.obstacles(edges[0], graph)
            var base: [Point]??
            for (i, e) in edges.enumerated() {
                let forward = e.source === edges[0].source
                var path = [a, midpoints?[i] ?? ((a + b) / 2 + normal * offsets[i]), b]
                if !ObstaclePolyline.clear(path, obstacles) {
                    if base == nil {
                        base = .some(
                            ObstaclePolyline.search(a, b, obstacles, padding: 10 + (offsets.map(abs).max() ?? 0))
                                .flatMap { $0.count > 2 ? $0 : nil }
                        )
                    }
                    // `base` was assigned just above if it was still nil; its inner optional is the search result.
                    if let around = base!,
                        let free = [offsets[i], offsets[i] / 2, 0].map({ offsetPolyline(around, by: $0) })
                            .first(where: { ObstaclePolyline.clear($0, obstacles) })
                    {
                        path = free
                        fellBack.append(e)
                    } else {
                        failed.append(e)
                    }
                }
                e.path = forward ? path : path.reversed()
            }
        }
    }
}
