import Foundation

/// Small placement-only compositions used on measured container proxies.
final class PresetPlacement: LayoutAlgorithm {
    private let operation: (LayoutGraph) throws -> Void
    init(_ operation: @escaping (LayoutGraph) throws -> Void) { self.operation = operation }
    func applyLayout(_ graph: LayoutGraph) throws { try Task.checkCancellation(); try operation(graph) }
}

final class AsyncPresetPlacement: LayoutExecutionReporting {
    private let configure: (LayoutBuilder) -> Void
    private let preservedKeys: [String]
    private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []
    init(preserving keys: [String] = [], _ configure: @escaping (LayoutBuilder) -> Void) {
        self.configure = configure; preservedKeys = keys
    }
    func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastExecutionMetrics = []
        let old = graph.nodes.map(\.metadata)
        defer {
            for (node, values) in zip(graph.nodes, old) {
                for key in preservedKeys { node.metadata[key] = values[key] }
            }
        }
        let builder = LayoutBuilder.create(graph); configure(builder)
        try await builder.applyAsync(); lastExecutionMetrics = builder.lastExecutionMetrics
    }
}

enum PresetRouting {
    case polyline, layered, bsp, channel, bundled(Float), curves(Int)

    func apply(_ graph: LayoutGraph) -> [LayoutEdge] {
        var failed: [LayoutEdge] = []
        switch self {
        case .polyline, .bundled:
            let router = PolylineEdgeRouter(); router.routeEdges(graph); failed = router.unroutableEdges
            if case let .bundled(k) = self {
                let bundler = EdgeBundlingRouter(); bundler.k = k; bundler.routeEdges(graph)
            }
        case .layered, .curves:
            failed = ObstaclePolyline.repair(graph, shortenDetours: true)
            EdgeSeparator().routeEdges(graph)
            if case let .curves(iterations) = self {
                let curves = CurveFittingEdgeRouter(); curves.iterations = iterations; curves.routeEdges(graph)
            }
        case .bsp:
            let router = BspEdgeRouter(); router.routeEdges(graph); failed = router.unroutableEdges
        case .channel:
            let router = ChannelEdgeRouter(); router.routeEdges(graph); failed = router.unroutableEdges
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

extension LayoutBuilder {
    @discardableResult
    func groupedPreset(_ core: any LayoutAlgorithm, routing: PresetRouting) -> Self {
        let groups = RecursiveGroupLayout(core)
        groups.presetRouting = { routing.apply($0) }
        // Alignment after fitting must not regenerate a preset's final routes.
        groups.optimizeIncomingEdges = false
        return useAlgorithm(groups)
    }

    @discardableResult
    func groupedPreset(_ core: any AsyncLayoutAlgorithm, routing: PresetRouting, backend: LayoutBackend, executor: LayoutExecutor) -> Self {
        let groups = RecursiveGroupLayoutOperation(core, backend: backend, executor: executor)
        groups.presetRouting = { try await routing.apply($0, backend: backend, executor: executor) }
        groups.optimizeIncomingEdges = false
        return useAsyncAlgorithm(groups)
    }
}

extension PresetRouting {
    func apply(_ graph: LayoutGraph, backend: LayoutBackend, executor: LayoutExecutor) async throws -> (failures: [LayoutEdge], metrics: [LayoutExecutionMetrics]) {
        let builder = LayoutBuilder.create(graph)
        switch self {
        case .polyline, .bundled:
            builder.routePolyline(backend: backend, executor: executor)
            if case let .bundled(k) = self { builder.routeWithBundling(backend: backend, executor: executor) { $0.k = k } }
        case .layered, .curves:
            builder.transform { ObstaclePolyline.repair($0, shortenDetours: true) }
                .separateEdges(backend: backend, executor: executor)
            if case let .curves(iterations) = self { builder.routeCurveFitting(backend: backend, executor: executor) { $0.iterations = iterations } }
        case .bsp: builder.routeBsp(backend: backend, executor: executor)
        case .channel: builder.routeChannel(backend: backend, executor: executor).separateEdges(backend: backend, executor: executor)
        }
        builder.routeSelfLoops(backend: backend, executor: executor)
            .transform { ObstaclePolyline.repair($0, spacing: 0, shortenDetours: true) }
            .clipEdgeEndpoints(backend: backend, executor: executor)
            .distributePorts(backend: backend, executor: executor)
        try await builder.applyAsync()
        let scene = ObstaclePolyline.Scene(graph.nodes)
        let failed = graph.edges.filter { !scene.clear($0.path, $0) }
        return (failed, builder.lastExecutionMetrics)
    }
}

func positionNetworkHubs(_ graph: LayoutGraph, hubCount: Int) {
    let hubs = graph.nodes.enumerated().sorted {
        let l = $0.element.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0
        let r = $1.element.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0
        return l == r ? $0.offset < $1.offset : l > r
    }.prefix(max(0, hubCount)).map(\.element)
    let minimum = min(Float(300), Float(max(1, graph.nodes.count)) * 25)
    let radius = fittedCircleRadius(hubs.map(\.bounds), minimum: minimum)
    for (i, hub) in hubs.enumerated() {
        hub.metadata[GraphMetadataKeys.fixed] = true
        let angle = 2 * Float.pi * Float(i) / Float(hubs.count)
        hub.center = Point(x: radius * cos(angle), y: radius * sin(angle))
    }
    let fixed = Set(hubs)
    for node in graph.nodes { node.metadata[GraphMetadataKeys.layoutSubset] = !fixed.contains(node) }
}

func networkPlacement(_ graph: LayoutGraph, hubCount: Int, iterations: Int) throws {
    try PageRankAlgorithm().applyLayout(graph)
    let old = graph.nodes.map { ($0.metadata[GraphMetadataKeys.fixed], $0.metadata[GraphMetadataKeys.layoutSubset]) }
    defer {
        for (node, values) in zip(graph.nodes, old) {
            node.metadata[GraphMetadataKeys.fixed] = values.0
            node.metadata[GraphMetadataKeys.layoutSubset] = values.1
        }
    }
    positionNetworkHubs(graph, hubCount: hubCount)
    let organic = OrganicLayoutAlgorithm(); organic.scope = .subset; organic.iterations = Float(iterations)
    try organic.applyLayout(graph)
}
