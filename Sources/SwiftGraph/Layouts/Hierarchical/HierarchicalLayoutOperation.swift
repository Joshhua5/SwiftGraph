import Foundation

/// Rank construction stays on CPU. Metal performs ordering and weighted isotonic
/// block decisions; Float reconstruction preserves the synchronous coordinate precision.
public final class HierarchicalLayoutOperation: LayoutExecutionReporting {
    public var configuration: HierarchicalLayoutConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
    let transpose: Bool

    public init(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configuration: HierarchicalLayoutConfiguration = .init()
    ) {
        self.backend = backend
        self.executor = executor
        self.configuration = configuration
        transpose = false
    }

    init(
        backend: LayoutBackend,
        executor: LayoutExecutor,
        configuration: HierarchicalLayoutConfiguration,
        transpose: Bool
    ) {
        self.backend = backend
        self.executor = executor
        self.configuration = configuration
        self.transpose = transpose
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now
        let configuration = self.configuration
        try configuration.validate()
        try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        let snapshot = try GraphCheckpoint(transaction.working).snapshot
        guard snapshot.edges.count == transaction.working.edges.count else {
            throw LayoutExecutionError.invalidInput("Hierarchy edge endpoints must belong to the graph.")
        }
        let result = try await executor.hierarchical(
            snapshot,
            configuration: configuration,
            transpose: transpose,
            backend: backend
        )
        for (node, bounds) in zip(transaction.working.nodes, result.bounds) { node.bounds = bounds }
        if configuration.routesEdges {
            for (edge, path) in zip(transaction.working.edges, result.paths) { edge.path = path }
        }
        try transaction.commit(to: graph)
        var metrics = result.metrics
        metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics
    }
}
