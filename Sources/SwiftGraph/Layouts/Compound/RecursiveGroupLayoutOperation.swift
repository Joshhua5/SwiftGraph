import Foundation

/// Async composition on detached geometry, committed only after every child succeeds.
/// Cores must preserve topology and treat caller payloads/custom metadata as read-only.
public final class RecursiveGroupLayoutOperation: LayoutExecutionReporting {
    public private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public var coreLayout: any AsyncLayoutAlgorithm
    public var groupPadding: Float = 20

    /// Refine framed placement using incoming boundary connections after fitting the frames.
    public var optimizeIncomingEdges: Bool = true

    /// Disable group-level polyline routing when a separate router runs after group placement.
    public var routesEdges: Bool = true
    var presetRouting: ((LayoutGraph) async throws -> (failures: [LayoutEdge], metrics: [LayoutExecutionMetrics]))?
    public var groupLayoutSelector: ((LayoutNode) -> any AsyncLayoutAlgorithm)?
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
        unroutableEdges = []
        try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        let original = try GroupLayoutEngine(graph, padding: groupPadding)
        // Resolve against caller identities before suspending, then use only detached geometry.
        let layouts = original.groups.map { groupLayoutSelector?($0) ?? coreLayout }
        let refineIncoming = optimizeIncomingEdges
        let shouldRouteEdges = routesEdges
        let engine = try GroupLayoutEngine(transaction.working, padding: groupPadding)
        var records: [LayoutExecutionMetrics] = []
        var failures = Set<LayoutEdge>()
        // Groups share the stage by child count, leaving the tail for incoming-edge refinement.
        let groupShare = refineIncoming && shouldRouteEdges ? 0.9 : 1.0
        let slices = LayoutStageScope.slices(engine.groups.map { Double($0.children.count + 1) })
        for (index, (group, layout)) in zip(engine.groups, layouts).enumerated() {
            try Task.checkCancellation()
            try await LayoutStageScope.run(
                "Group \(index + 1)/\(engine.groups.count)",
                from: groupShare * slices[index].from,
                to: groupShare * slices[index].to
            ) {
                let projectionStart = ContinuousClock.now
                let projection = engine.projection(for: group)
                if backend != .cpu {
                    records.append(
                        compositionCPURecord(
                            backend,
                            count: projection.graph.nodes.count,
                            start: projectionStart,
                            stages: ["group edge projection"]
                        )
                    )
                }
                if !group.children.isEmpty {
                    let coreStart = ContinuousClock.now
                    try await LayoutStageScope.run("Layout", to: 0.7) {
                        try await layout.applyLayoutAsync(projection.graph)
                    }
                    records += compositionCoreRecords(
                        layout,
                        requested: backend,
                        graph: projection.graph,
                        start: coreStart
                    )
                    let placementStart = ContinuousClock.now
                    try engine.accept(projection, in: group)
                    if backend != .cpu {
                        records.append(
                            compositionCPURecord(
                                backend,
                                count: projection.graph.nodes.count,
                                start: placementStart,
                                stages: ["frame overlap repair and rigid subtree placement"]
                            )
                        )
                    }
                }
                let routing = engine.routingGraph(for: group, allOwnedEdges: presetRouting != nil)
                if !routing.edges.isEmpty {
                    try await LayoutStageScope.run("Route edges", from: 0.7, to: 0.95) {
                        if let presetRouting {
                            let result = try await presetRouting(routing)
                            failures.formUnion(result.failures)
                            records += result.metrics
                        } else if !shouldRouteEdges {
                            for edge in routing.edges where edge.path.count < 2 {
                                edge.path = [edge.source.center, edge.target.center]
                            }
                        } else if backend == .cpu {
                            failures.formUnion(PolylineEdgeRouter().route(routing).unroutableEdges(in: routing))
                        } else {
                            let router = RoutingLayoutOperation(.polyline, backend: backend, executor: executor)
                            try await router.applyLayoutAsync(routing)
                            failures.formUnion(router.report.unroutableEdges(in: routing))
                            records += router.lastExecutionMetrics
                        }
                    }
                }
                let fitStart = ContinuousClock.now
                try engine.finish(group, routed: routing.edges)
                if backend != .cpu {
                    records.append(
                        compositionCPURecord(
                            backend,
                            count: group.children.count,
                            start: fitStart,
                            stages: ["group frame measurement and translation"]
                        )
                    )
                }
            }
        }
        if refineIncoming && shouldRouteEdges {
            let start = ContinuousClock.now
            try LayoutStageScope.run("Incoming edges", from: groupShare) {
                try engine.refineIncomingEdges(excluding: failures)
            }
            if backend != .cpu {
                records.append(
                    compositionCPURecord(
                        backend,
                        count: transaction.working.nodes.count,
                        start: start,
                        stages: ["incoming group edge alignment and route validation"]
                    )
                )
            }
        }
        try transaction.commit(to: graph)
        lastExecutionMetrics = records
        unroutableEdges = zip(graph.edges, transaction.working.edges).compactMap { failures.contains($1) ? $0 : nil }
    }
}
