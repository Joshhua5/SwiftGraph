import Foundation

/// Accelerates pairwise ring clearance. Traversal, component packing and obstacle
/// repair retain CPU semantics, including the synchronous formats' treatment of groups.
public final class RadialLayoutOperation: LayoutExecutionReporting {
    public let style: RadialLayoutStyle
    public var configuration: RadialLayoutConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }

    public init(
        style: RadialLayoutStyle = .radial,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configuration: RadialLayoutConfiguration? = nil
    ) {
        self.style = style
        self.backend = backend
        self.executor = executor
        self.configuration = configuration ?? .init(spacing: style == .star ? 200 : 100)
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now
        let configuration = self.configuration
        try Task.checkCancellation()
        try configuration.validate()
        let transaction = try LayoutTransaction(graph)
        let snapshot = try GraphCheckpoint(transaction.working).snapshot
        let executor = self.executor
        let style = self.style
        let backend = self.backend
        let result = try await LayoutStageScope.run("Placement", to: 0.9) {
            try await executor.radial(snapshot, style: style, configuration: configuration, backend: backend)
        }
        for (node, bounds) in zip(transaction.working.nodes, result.bounds) { node.bounds = bounds }
        if result.routeEdges {
            LayoutStageScope.run("Route edges", from: 0.9) {
                straightEdges(transaction.working)
                ObstaclePolyline.repair(transaction.working)
            }
        }
        try transaction.commit(to: graph)
        var metrics = result.metrics
        metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics
    }
}
