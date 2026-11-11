import Foundation

enum PresetRouting {
    case polyline, layered, bsp, channel
    case bundled(Float)
    case curves(Int)

    var style: RouteStyle {
        switch self {
        case .polyline, .layered, .bundled: .polyline
        case .bsp, .channel: .orthogonal
        case .curves: .curved
        }
    }

    var curveIterations: Int {
        guard case .curves(let iterations) = self else { return RouteFinishing.defaultCurveIterations }
        return iterations
    }

    func apply(_ graph: LayoutGraph) -> [LayoutEdge] {
        var failed: [LayoutEdge] = []
        switch self {
        case .polyline, .bundled:
            failed = PolylineEdgeRouter().route(graph).unroutableEdges(in: graph)
            if case .bundled(let k) = self {
                let bundler = EdgeBundlingRouter()
                bundler.k = k
                bundler.routeEdges(graph)
            }
        case .layered, .curves:
            failed = ObstaclePolyline.repair(graph, shortenDetours: true)
            EdgeSeparator().routeEdges(graph)
        case .bsp:
            failed = BspEdgeRouter().route(graph).unroutableEdges(in: graph)
        case .channel:
            failed = ChannelEdgeRouter().route(graph).unroutableEdges(in: graph)
            EdgeSeparator().routeEdges(graph)
        }
        // No later whole-graph router may invalidate the measured container envelope.
        failed += RouteFinishing.finish(graph, style: style, curveIterations: curveIterations)
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
        case .bsp: builder.routeBsp(backend: backend, executor: executor)
        case .channel:
            builder.routeChannel(backend: backend, executor: executor)
                .separateEdges(backend: backend, executor: executor)
        }
        // No later whole-graph router may invalidate the measured container envelope.
        builder.finishRoutes(style: style, backend: backend, executor: executor, curveIterations: curveIterations)
        try await builder.applyAsync()
        let failed = LayoutStageScope.run("Verify clearance") {
            let scene = ObstaclePolyline.Scene(graph.nodes)
            return graph.edges.filter { !scene.clear($0.path, $0) }
        }
        return (failed, builder.lastExecutionMetrics)
    }
}
