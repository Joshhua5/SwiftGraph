import Foundation

/// Async composition on detached geometry, committed only after every child succeeds.
/// Cores must preserve topology and treat caller payloads/custom metadata as read-only.
public final class ComponentLayoutOperation: LayoutExecutionReporting {
    public private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []
    public var coreLayout: any AsyncLayoutAlgorithm
    public var componentSpacing: Float = 50
    public var preferredAspectRatio: Float = 1
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
        let operation = ComponentLayoutOperation(coreLayout, backend: backend, executor: executor)
        operation.componentSpacing = componentSpacing
        operation.preferredAspectRatio = preferredAspectRatio
        try await operation.applyWorking(transaction.working)
        try transaction.commit(to: graph)
        lastExecutionMetrics = operation.lastExecutionMetrics
    }

    private func applyWorking(_ graph: LayoutGraph) async throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        let components = a.components()
        if components.count == 1 {
            let coreStart = ContinuousClock.now
            try await coreLayout.applyLayoutAsync(graph)
            lastExecutionMetrics += compositionCoreRecords(
                coreLayout,
                requested: backend,
                graph: graph,
                start: coreStart
            )
            return
        }
        var graphs: [LayoutGraph] = []
        // Components share 97% of the stage by node count; packing takes the rest.
        let slices = LayoutStageScope.slices(components.map { Double($0.count) })
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            let g = subgraph(graph, nodes: component.map { a.nodes[$0] })
            let coreStart = ContinuousClock.now
            try await LayoutStageScope.run(
                "Component \(index + 1)/\(components.count)",
                from: 0.97 * slices[index].from,
                to: 0.97 * slices[index].to
            ) {
                try await coreLayout.applyLayoutAsync(g)
            }
            lastExecutionMetrics += compositionCoreRecords(coreLayout, requested: backend, graph: g, start: coreStart)
            let b = g.bounds
            translate(g, by: Point(x: -b.x, y: -b.y))
            graphs.append(g)
        }
        let packingStart = ContinuousClock.now
        let shifts = LayoutStageScope.run("Pack", from: 0.97) {
            packedTranslations(graphs.map(\.bounds), spacing: componentSpacing, aspectRatio: preferredAspectRatio)
        }
        for (g, shift) in zip(graphs, shifts) { translate(g, by: shift) }
        if backend != .cpu {
            lastExecutionMetrics.append(
                compositionCPURecord(
                    backend,
                    count: graph.nodes.count,
                    start: packingStart,
                    stages: ["component packing"]
                )
            )
        }
    }
}
