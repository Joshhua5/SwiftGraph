import Foundation

enum PresetRouting {
    case polyline, layered, bsp, channel
    case bundled(Float)
    case curves(Int)

    func apply(_ graph: LayoutGraph) -> [LayoutEdge] {
        var failed: [LayoutEdge] = []
        switch self {
        case .polyline, .bundled:
            let router = PolylineEdgeRouter()
            router.routeEdges(graph)
            failed = router.unroutableEdges
            if case .bundled(let k) = self {
                let bundler = EdgeBundlingRouter()
                bundler.k = k
                bundler.routeEdges(graph)
            }
        case .layered, .curves:
            failed = ObstaclePolyline.repair(graph, shortenDetours: true)
            EdgeSeparator().routeEdges(graph)
            if case .curves(let iterations) = self {
                let curves = CurveFittingEdgeRouter()
                curves.iterations = iterations
                curves.routeEdges(graph)
            }
        case .bsp:
            let router = BspEdgeRouter()
            router.routeEdges(graph)
            failed = router.unroutableEdges
        case .channel:
            let router = ChannelEdgeRouter()
            router.routeEdges(graph)
            failed = router.unroutableEdges
            EdgeSeparator().routeEdges(graph)
        }
        // No later whole-graph router may invalidate the measured container envelope.
        SelfLoopRouter().routeEdges(graph)
        failed += ObstaclePolyline.repair(graph, spacing: 0, shortenDetours: true)
        EdgeEndpointClipper.clipToNodeBounds(graph)
        PortDistributor().routeEdges(graph)
        let scene = ObstaclePolyline.Scene(graph.nodes)
        return Array(Set(failed.filter { !scene.clear($0.path, $0) }))
    }
}

extension PresetRouting {
    func apply(
        _ graph: LayoutGraph,
        backend: LayoutBackend,
        executor: LayoutExecutor
    ) async throws -> (failures: [LayoutEdge], metrics: [LayoutExecutionMetrics]) {
        let builder = LayoutBuilder.create(graph)
        switch self {
        case .polyline, .bundled:
            builder.routePolyline(backend: backend, executor: executor)
            if case .bundled(let k) = self {
                builder.routeWithBundling(backend: backend, executor: executor) { $0.k = k }
            }
        case .layered, .curves:
            builder.transform { g in
                LayoutStageScope.run("Pre-separation repair") { _ = ObstaclePolyline.repair(g, shortenDetours: true) }
            }
            .separateEdges(backend: backend, executor: executor)
            if case .curves(let iterations) = self {
                builder.routeCurveFitting(backend: backend, executor: executor) { $0.iterations = iterations }
            }
        case .bsp: builder.routeBsp(backend: backend, executor: executor)
        case .channel:
            builder.routeChannel(backend: backend, executor: executor)
                .separateEdges(backend: backend, executor: executor)
        }
        builder.routeSelfLoops(backend: backend, executor: executor)
            .transform { g in
                LayoutStageScope.run("Post-routing repair") {
                    _ = ObstaclePolyline.repair(g, spacing: 0, shortenDetours: true)
                }
            }
            .clipEdgeEndpoints(backend: backend, executor: executor)
            .distributePorts(backend: backend, executor: executor)
        try await builder.applyAsync()
        let failed = LayoutStageScope.run("Verify clearance") {
            let scene = ObstaclePolyline.Scene(graph.nodes)
            return graph.edges.filter { !scene.clear($0.path, $0) }
        }
        return (failed, builder.lastExecutionMetrics)
    }
}
