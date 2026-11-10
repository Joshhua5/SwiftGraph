import Foundation

/// Scales node sizes from PageRank before executing a caller-selected layout.
/// Analysis, size changes and the child layout commit together.
public final class ImportanceLayoutOperation: LayoutExecutionReporting {
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
        let analysis = LayoutBuilder.create(working).analyzePageRank(backend: backend, executor: executor)
        try await LayoutStageScope.run("Rank", to: 0.3) { try await analysis.applyAsync() }
        let scalingStart = ContinuousClock.now
        for node in working.nodes {
            let scale = Float(1 + 2 * (node.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0))
            node.width *= scale
            node.height *= scale
        }
        let scalingSeconds = scalingStart.duration(to: .now).seconds
        let coreStart = ContinuousClock.now
        try await LayoutStageScope.run("Layout", from: 0.3) { try await coreLayout.applyLayoutAsync(working) }
        try transaction.commit(to: graph)
        lastExecutionMetrics =
            analysis.lastExecutionMetrics
            + [
                LayoutExecutionMetrics(
                    requestedBackend: backend,
                    backend: .cpu,
                    fallbackReason: nil,
                    nodeCount: working.nodes.count,
                    iterations: 0,
                    computeSeconds: scalingSeconds,
                    totalSeconds: scalingSeconds,
                    gpuSeconds: nil,
                    deviceName: nil,
                    cpuStages: ["PageRank size scaling"]
                )
            ]
            + compositionCoreRecords(coreLayout, requested: backend, graph: working, start: coreStart)
    }
}
