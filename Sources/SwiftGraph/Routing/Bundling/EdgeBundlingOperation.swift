import Foundation

/// Async routing operation; self-loops and node geometry are preserved.
public final class EdgeBundlingOperation: AsyncLayoutAlgorithm {
    public var configuration: EdgeBundlingConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?

    /// Unroutable edges are final paths for which obstacle repair could not find a clear alternative, as indices
    /// into `graph.edges`.
    public private(set) var report = RoutingReport()

    /// Final paths for which obstacle repair could not find a clear alternative.
    @available(*, deprecated, message: "Use report.unroutable")
    public var unroutableEdgeIndices: [Int] { report.unroutable }

    public init(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configuration: EdgeBundlingConfiguration = .init()
    ) {
        self.backend = backend
        self.executor = executor
        self.configuration = configuration
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        report = RoutingReport()
        let start = ContinuousClock.now
        let configuration = self.configuration
        try Task.checkCancellation()
        try configuration.validate()
        let checkpoint = try GraphCheckpoint(graph)
        let paths = graph.edges.map(\.path)
        let routing = try RoutingCheckpoint(graph, labels: Array(repeating: nil, count: graph.edges.count))
        let result = try await executor.bundle(
            checkpoint.snapshot,
            paths: paths,
            configuration: configuration,
            backend: backend,
            routing: routing.snapshot
        )
        try Task.checkCancellation()
        guard checkpoint.matches(graph),
            routing.matches(graph, labels: Array(repeating: nil, count: graph.edges.count)),
            graph.edges.map(\.path) == paths
        else { throw LayoutExecutionError.staleGraph }
        for edge in result.paths { graph.edges[edge.index].path = edge.points }
        report = RoutingReport(unroutable: result.unroutable)
        var metrics = result.metrics
        metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics
    }
}
