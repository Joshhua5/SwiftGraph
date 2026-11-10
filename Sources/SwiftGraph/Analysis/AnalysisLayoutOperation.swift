import Foundation

public final class AnalysisLayoutOperation: LayoutExecutionReporting {
    public let kind: AnalysisKind
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public var pageRank: PageRankConfiguration
    public var clusters: ClusterAnalysisConfiguration
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }

    public init(
        _ kind: AnalysisKind,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        pageRank: PageRankConfiguration = .init(),
        clusters: ClusterAnalysisConfiguration = .init()
    ) {
        self.kind = kind
        self.backend = backend
        self.executor = executor
        self.pageRank = pageRank
        self.clusters = clusters
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now
        let pageRank = self.pageRank
        let clusters = self.clusters
        if kind == .pageRank { try pageRank.validate() } else { try clusters.validate() }
        try Task.checkCancellation()
        let checkpoint = try GraphCheckpoint(graph)
        let ranks = graph.nodes.map { $0.metadata[GraphMetadataKeys.pageRank] as? Double }
        let labels = graph.nodes.map { $0.metadata[GraphMetadataKeys.cluster] as? Int }
        let result = try await executor.analysis(
            checkpoint.snapshot,
            kind: kind,
            pageRank: pageRank,
            clusters: clusters,
            backend: backend
        )
        try Task.checkCancellation()
        guard checkpoint.matches(graph),
            graph.nodes.map({ $0.metadata[GraphMetadataKeys.pageRank] as? Double }) == ranks,
            graph.nodes.map({ $0.metadata[GraphMetadataKeys.cluster] as? Int }) == labels
        else { throw LayoutExecutionError.staleGraph }
        if let values = result.ranks {
            guard values.count == graph.nodes.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw OrganicLayoutError.metalFailure("Invalid PageRank output")
            }
            for i in graph.nodes.indices { graph.nodes[i].metadata[GraphMetadataKeys.pageRank] = values[i] }
        }
        if let values = result.labels {
            guard values.count == graph.nodes.count, values.allSatisfy({ $0 >= 0 && $0 < graph.nodes.count }) else {
                throw OrganicLayoutError.metalFailure("Invalid cluster labels")
            }
            for i in graph.nodes.indices { graph.nodes[i].metadata[GraphMetadataKeys.cluster] = values[i] }
        }
        var metrics = result.metrics
        metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics
    }
}
