import Foundation

/// Neighbor averaging on the chosen backend; anchor selection and overlap cleanup
/// use the CPU contract. Even zero iterations perform cleanup and create straight routes.
public final class BarycenterLayoutOperation: AsyncLayoutAlgorithm {
    public var configuration: BarycenterLayoutConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?

    public init(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configuration: BarycenterLayoutConfiguration = .init()
    ) {
        self.backend = backend
        self.executor = executor
        self.configuration = configuration
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now
        let configuration = self.configuration
        try Task.checkCancellation()
        try configuration.validate()
        let transaction = try LayoutTransaction(graph)
        let snapshot = try GraphCheckpoint(transaction.working).snapshot
        let result = try await executor.barycenter(snapshot, configuration: configuration, backend: backend)
        for (node, center) in zip(transaction.working.nodes, result.centers) where node.center != center {
            node.center = center
        }
        straightEdges(transaction.working)
        try transaction.commit(to: graph)
        var metrics = result.metrics
        metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics
    }
}
