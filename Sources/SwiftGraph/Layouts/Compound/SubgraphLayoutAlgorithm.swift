import Foundation

public final class SubgraphLayoutAlgorithm: LayoutAlgorithm {
    public var selectedNodeIds: Set<String> = []
    public var coreLayout: any LayoutAlgorithm
    public var preserveCentroid = true

    /// Clearance takes precedence over centroid preservation. Disable for legacy placement.
    public var avoidUnselectedNodes = true

    public init(_ coreLayout: any LayoutAlgorithm) { self.coreLayout = coreLayout }

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let g = subgraph(graph, nodes: graph.nodes.filter { selectedNodeIds.contains($0.id) })
        guard !g.nodes.isEmpty else { return }
        func centroid() -> Point { g.nodes.reduce(Point.zero) { $0 + $1.center } / Float(g.nodes.count) }
        let initial = centroid()
        try LayoutStageScope.run("Layout", to: 0.8) { try coreLayout.applyLayout(g) }
        if preserveCentroid { translate(g, by: initial - centroid()) }
        if avoidUnselectedNodes {
            let obstacles =
                graph.nodes
                .filter { node in
                    !selectedNodeIds.contains(node.id)
                        && !g.nodes.contains {
                            isAncestor(node, of: $0) || isAncestor($0, of: node)
                        }
                }
                .map(\.bounds)
                + graph.edges
                .filter {
                    !selectedNodeIds.contains($0.source.id) && !selectedNodeIds.contains($0.target.id)
                }
                .flatMap { edge in
                    // Moving the selection must not obstruct a route whose endpoints are untouched.
                    zip(edge.path, edge.path.dropFirst())
                        .map { a, b in
                            Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                        }
                }
            var envelope = g.bounds
            for edge in g.edges {
                for p in edge.path { envelope = envelope.union(Rect(x: p.x, y: p.y)) }
                if edge.labelBounds.width > 0 { envelope = envelope.union(edge.labelBounds) }
            }
            let padded = obstacles.map { $0.inflated(by: 10) }
            if padded.contains(where: { $0.intersects(envelope) }),
                let best = try nearestClearOffset(envelope, avoiding: padded)
            {
                translate(g, by: best)
            }
        }
        let routing = subgraph(graph, nodes: graph.nodes)
        routing.edges = graph.edges.filter {
            selectedNodeIds.contains($0.source.id) != selectedNodeIds.contains($0.target.id)
        }
        ChannelEdgeRouter().routeEdges(routing)
        if avoidUnselectedNodes {
            ObstaclePolyline.repair(
                graph,
                edges: graph.edges.filter {
                    selectedNodeIds.contains($0.source.id) || selectedNodeIds.contains($0.target.id)
                }
            )
        }
        try Task.checkCancellation()
    }
}
