import Foundation

/// Async composition on detached geometry, committed only after every child succeeds.
/// Cores must preserve topology and treat caller payloads/custom metadata as read-only.
public final class SubgraphLayoutOperation: LayoutExecutionReporting {
    public private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []
    public var selectedNodeIds: Set<String> = []
    public var coreLayout: any AsyncLayoutAlgorithm
    public var preserveCentroid = true

    /// Clearance takes precedence over centroid preservation. Disable for legacy placement.
    public var avoidUnselectedNodes = true
    public let backend: LayoutBackend
    public let executor: LayoutExecutor

    public init(
        _ coreLayout: any AsyncLayoutAlgorithm,
        backend: LayoutBackend = .cpu,
        executor: LayoutExecutor = .shared
    ) {
        self.coreLayout = coreLayout
        self.backend = backend
        self.executor = executor
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastExecutionMetrics = []
        try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        let operation = SubgraphLayoutOperation(coreLayout, backend: backend, executor: executor)
        operation.selectedNodeIds = selectedNodeIds
        operation.preserveCentroid = preserveCentroid
        operation.avoidUnselectedNodes = avoidUnselectedNodes
        try await operation.applyWorking(transaction.working)
        try transaction.commit(to: graph)
        lastExecutionMetrics = operation.lastExecutionMetrics
    }

    private func applyWorking(_ graph: LayoutGraph) async throws {
        try Task.checkCancellation()
        let g = subgraph(graph, nodes: graph.nodes.filter { selectedNodeIds.contains($0.id) })
        guard !g.nodes.isEmpty else { return }
        func centroid() -> Point { g.nodes.reduce(Point.zero) { $0 + $1.center } / Float(g.nodes.count) }
        let initial = centroid()
        let coreStart = ContinuousClock.now
        try await LayoutStageScope.run("Layout", to: 0.8) { try await coreLayout.applyLayoutAsync(g) }
        lastExecutionMetrics += compositionCoreRecords(coreLayout, requested: backend, graph: g, start: coreStart)
        let clearanceStart = ContinuousClock.now
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
        if backend != .cpu {
            lastExecutionMetrics.append(
                compositionCPURecord(
                    backend,
                    count: graph.nodes.count,
                    start: clearanceStart,
                    stages: ["centroid preservation and selection clearance"]
                )
            )
        }
        let routing = subgraph(graph, nodes: graph.nodes)
        routing.edges = graph.edges.filter {
            selectedNodeIds.contains($0.source.id) != selectedNodeIds.contains($0.target.id)
        }
        try await LayoutStageScope.run("Route edges", from: 0.8) {
            if backend == .cpu {
                ChannelEdgeRouter().routeEdges(routing)
            } else {
                let router = RoutingLayoutOperation(.channel, backend: backend, executor: executor)
                try await router.applyLayoutAsync(routing)
                lastExecutionMetrics += router.lastExecutionMetrics
            }
        }
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
