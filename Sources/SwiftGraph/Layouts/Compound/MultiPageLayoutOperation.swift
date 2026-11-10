import Foundation

/// Async composition on detached geometry, committed only after every child succeeds.
/// Cores must preserve topology and treat caller payloads/custom metadata as read-only.
public final class MultiPageLayoutOperation: LayoutExecutionReporting {
    public private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []
    public var pageWidth: Float = 800
    public var pageHeight: Float = 1100
    public var pageSpacing: Float = 100
    public var coreLayout: any AsyncLayoutAlgorithm
    public let backend: LayoutBackend
    public let executor: LayoutExecutor

    public init(
        _ coreLayout: (any AsyncLayoutAlgorithm)? = nil,
        backend: LayoutBackend = .cpu,
        executor: LayoutExecutor = .shared
    ) {
        self.backend = backend
        self.executor = executor
        if let coreLayout {
            self.coreLayout = coreLayout
        } else if backend == .cpu {
            self.coreLayout = HierarchicalLayoutAlgorithm()
        } else {
            self.coreLayout = HierarchicalLayoutOperation(backend: backend, executor: executor)
        }
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastExecutionMetrics = []
        try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        let operation = MultiPageLayoutOperation(coreLayout, backend: backend, executor: executor)
        operation.pageWidth = pageWidth
        operation.pageHeight = pageHeight
        operation.pageSpacing = pageSpacing
        try await operation.applyWorking(transaction.working)
        try transaction.commit(to: graph)
        lastExecutionMetrics = operation.lastExecutionMetrics
    }

    private func applyWorking(_ graph: LayoutGraph) async throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        let components = a.components()
        let slices = LayoutStageScope.slices(components.map { Double($0.count) })
        for (i, component) in components.enumerated() {
            try Task.checkCancellation()
            let g = subgraph(graph, nodes: component.map { a.nodes[$0] })
            let coreStart = ContinuousClock.now
            try await LayoutStageScope.run("Page \(i + 1)/\(components.count)", from: slices[i].from, to: slices[i].to)
            {
                try await coreLayout.applyLayoutAsync(g)
            }
            lastExecutionMetrics += compositionCoreRecords(coreLayout, requested: backend, graph: g, start: coreStart)
            let packingStart = ContinuousClock.now
            let b = g.bounds
            translate(
                g,
                by: Point(
                    x: Float(i % 3) * (pageWidth + pageSpacing) + (pageWidth - b.width) / 2 - b.x,
                    y: Float(i / 3) * (pageHeight + pageSpacing) + (pageHeight - b.height) / 2 - b.y
                )
            )
            if backend != .cpu {
                lastExecutionMetrics.append(
                    compositionCPURecord(backend, count: g.nodes.count, start: packingStart, stages: ["page packing"])
                )
            }
        }
    }
}
