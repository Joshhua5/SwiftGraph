import Foundation

public final class SeriesParallelLayoutOperation: LayoutExecutionReporting {
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }

    public init(backend: LayoutBackend, executor: LayoutExecutor = .shared) {
        self.backend = backend
        self.executor = executor
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let operation = HierarchicalLayoutOperation(
            backend: backend,
            executor: executor,
            configuration: .init(),
            transpose: true
        )
        try await operation.applyLayoutAsync(graph)
        lastMetrics = operation.lastMetrics
    }
}
