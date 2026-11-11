import Foundation

public final class DirectedLayoutAsyncOperation: LayoutExecutionReporting {
    public var configuration: DirectedLayoutConfiguration
    public var cache: DirectedLayoutCache?
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public private(set) var lastDiagnostics: DirectedLayoutDiagnostics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }

    public init(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configuration: DirectedLayoutConfiguration = .init(),
        cache: DirectedLayoutCache? = nil
    ) {
        self.backend = backend
        self.executor = executor
        self.configuration = configuration
        self.cache = cache
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        lastDiagnostics = nil
        let start = ContinuousClock.now
        let configuration = self.configuration
        try Task.checkCancellation()
        try configuration.validateExecution()
        let transaction = try LayoutTransaction(graph)
        let snapshot = try DirectedExecutionSnapshot(transaction.working)
        let result = try await executor.directed(snapshot, configuration: configuration, cache: cache, backend: backend)
        for (node, bounds) in zip(transaction.working.nodes, result.bounds) { node.bounds = bounds }
        for (edge, path) in zip(transaction.working.edges, result.paths) { edge.path = path }
        transaction.working.routeStyle = .orthogonal
        try transaction.commit(to: graph)
        var metrics = result.metrics
        metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics
        lastDiagnostics = result.diagnostics
    }
}
