import Foundation

/// Lays out deterministic label-propagation clusters independently and packs them.
/// Cluster assignment and all child geometry commit together after success.
public final class ClusterLayoutOperation: LayoutExecutionReporting {
    public var coreLayout: any AsyncLayoutAlgorithm
    public var backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastExecutionMetrics: [LayoutExecutionMetrics] = []

    public init(_ core: any AsyncLayoutAlgorithm, backend: LayoutBackend, executor: LayoutExecutor = .shared) {
        coreLayout = core
        self.backend = backend
        self.executor = executor
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastExecutionMetrics = []
        let transaction = try LayoutTransaction(graph)
        let working = transaction.working
        let analysis = LayoutBuilder.create(working).analyzeClusters(backend: backend, executor: executor)
        try await LayoutStageScope.run("Clusters", to: 0.2) { try await analysis.applyAsync() }
        var metrics = analysis.lastExecutionMetrics
        var groups: [Int: [LayoutNode]] = [:]
        var order: [Int] = []
        for (i, node) in working.nodes.enumerated() {
            let id = node.metadata[GraphMetadataKeys.cluster] as? Int ?? (-i - 1)
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(node)
        }
        var graphs: [LayoutGraph] = []
        var packingSeconds = 0.0
        let slices = LayoutStageScope.slices(order.map { Double(groups[required: $0].count) })
        for (index, id) in order.enumerated() {
            try Task.checkCancellation()
            let group = subgraph(working, nodes: groups[required: id])
            let coreStart = ContinuousClock.now
            try await LayoutStageScope.run(
                "Cluster \(index + 1)/\(order.count)",
                from: 0.2 + 0.8 * slices[index].from,
                to: 0.2 + 0.8 * slices[index].to
            ) {
                try await coreLayout.applyLayoutAsync(group)
            }
            metrics += compositionCoreRecords(coreLayout, requested: backend, graph: group, start: coreStart)
            let normalizationStart = ContinuousClock.now
            let bounds = group.bounds
            translate(group, by: Point(x: -bounds.x, y: -bounds.y))
            graphs.append(group)
            packingSeconds += normalizationStart.duration(to: .now).seconds
        }
        let packingStart = ContinuousClock.now
        let width = max(400, sqrt(graphs.reduce(Float(0)) { $0 + $1.bounds.width * $1.bounds.height }) * 1.5)
        var x: Float = 0.0
        var y: Float = 0.0
        var rowHeight: Float = 0.0
        for group in graphs {
            try Task.checkCancellation()
            let bounds = group.bounds
            if x > 0 && x + bounds.width > width {
                x = 0
                y += rowHeight + 80
                rowHeight = 0
            }
            translate(group, by: Point(x: x, y: y))
            x += bounds.width + 80
            rowHeight = max(rowHeight, bounds.height)
        }
        try transaction.commit(to: graph)
        packingSeconds += packingStart.duration(to: .now).seconds
        metrics.append(
            LayoutExecutionMetrics(
                requestedBackend: backend,
                backend: .cpu,
                fallbackReason: nil,
                nodeCount: working.nodes.count,
                iterations: 0,
                computeSeconds: packingSeconds,
                totalSeconds: packingSeconds,
                gpuSeconds: nil,
                deviceName: nil,
                cpuStages: ["deterministic cluster normalization and packing"]
            )
        )
        lastExecutionMetrics = metrics
    }
}
