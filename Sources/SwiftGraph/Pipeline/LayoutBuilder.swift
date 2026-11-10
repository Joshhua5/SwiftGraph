/// An ordered, reusable layout pipeline. Configuration closures run when a step is added.
public final class LayoutBuilder {
    public let graph: LayoutGraph
    private var pipeline: [Step] = []
    private let executionReport = LayoutPipelineReport()

    /// Records completed backend-aware stages from the latest applyAsync call.
    /// On failure, records from earlier successful pipeline stages remain available.
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { executionReport.metrics }
    public var pipelineLength: Int { pipeline.count }

    public init(graph: LayoutGraph) { self.graph = graph }

    public static func create(_ graph: LayoutGraph) -> LayoutBuilder { LayoutBuilder(graph: graph) }

    @discardableResult public func useAlgorithm(_ algorithm: any LayoutAlgorithm) -> Self {
        append(layoutStageName(algorithm)) { [executionReport] graph in
            try await algorithm.applyLayoutAsync(graph)
            executionReport.metrics += (algorithm as? any LayoutExecutionReporting)?.lastExecutionMetrics ?? []
        }
    }

    @discardableResult public func useAsyncAlgorithm(_ algorithm: any AsyncLayoutAlgorithm) -> Self {
        append(layoutStageName(algorithm)) { [executionReport] graph in
            try await algorithm.applyLayoutAsync(graph)
            executionReport.metrics += (algorithm as? any LayoutExecutionReporting)?.lastExecutionMetrics ?? []
        }
    }

    @discardableResult public func useAlgorithm<A: LayoutAlgorithm>(_ algorithm: A, configure: (A) -> Void) -> Self {
        configure(algorithm)
        return useAlgorithm(algorithm)
    }

    @discardableResult public func routeEdges(_ router: any EdgeRouter) -> Self {
        append(layoutStageName(router)) { graph in router.routeEdges(graph) }
    }

    @discardableResult public func routeEdges<R: EdgeRouter>(_ router: R, configure: (R) -> Void) -> Self {
        configure(router)
        return routeEdges(router)
    }

    @discardableResult public func transform(_ operation: @escaping (LayoutGraph) throws -> Void) -> Self {
        append("Transform") { graph in try operation(graph) }
    }

    @discardableResult public func transformAsync(_ operation: @escaping (LayoutGraph) async throws -> Void) -> Self {
        append("Transform", operation)
    }

    /// Renames the most recently added step and sets its share of overall progress (default weight 1).
    @discardableResult public func stage(_ name: String? = nil, weight: Double = 1) -> Self {
        guard !pipeline.isEmpty else { return self }
        if let name { pipeline[pipeline.count - 1].name = name }
        pipeline[pipeline.count - 1].weight = max(0, weight)
        return self
    }

    public func applyAsync() async throws {
        executionReport.metrics = []
        for step in pipeline {
            try Task.checkCancellation()
            try await step.run(graph)
            try Task.checkCancellation()
        }
    }

    /// Runs the pipeline, reporting named stages and overall completion to `progress`.
    /// The handler is called on background threads and must return quickly. Calling this from the main actor
    /// runs the layout there; UI code should prefer `layoutProgress()` or a `@concurrent` caller.
    public func applyAsync(progress: (@Sendable (LayoutProgress) -> Void)?) async throws {
        guard let progress else { return try await applyAsync() }
        try await applyAsync(sink: LayoutProgressSink(handler: progress))
    }

    func applyAsync(sink: LayoutProgressSink) async throws {
        executionReport.metrics = []
        let steps = pipeline
        let slices = LayoutStageScope.slices(steps.map(\.weight))
        try await withLayoutProgress(sink) {
            for (step, slice) in zip(steps, slices) {
                try Task.checkCancellation()
                try await LayoutStageScope.run(step.name, from: slice.from, to: slice.to) { try await step.run(graph) }
                try Task.checkCancellation()
            }
        }
    }

    /// Runs the pipeline off the calling actor and streams its progress. Ending iteration early, or cancelling
    /// the consuming task, cancels the layout. Do not read or mutate the builder or its graph until the stream ends.
    public func layoutProgress() -> AsyncThrowingStream<LayoutProgress, Error> {
        let builder = UncheckedBuilder(value: self)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // Detached so that a main-actor consumer does not run the layout on the main thread.
            let task = Task.detached(priority: Task.currentPriority) {
                do {
                    try await builder.value.applyAsync { continuation.yield($0) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func append(_ name: String, _ run: @escaping (LayoutGraph) async throws -> Void) -> Self {
        pipeline.append(Step(name: name, weight: 1, run: run))
        return self
    }

    private struct Step {
        var name: String
        var weight: Double
        let run: (LayoutGraph) async throws -> Void
    }
}

private final class LayoutPipelineReport {
    var metrics: [LayoutExecutionMetrics] = []
}

/// The stream contract hands the builder to its detached task until the stream finishes.
private struct UncheckedBuilder: @unchecked Sendable { let value: LayoutBuilder }

/// A readable stage name from a type name, e.g. `HierarchicalLayoutOperation` → "Hierarchical".
func layoutStageName(_ value: Any) -> String {
    var name = String(describing: type(of: value))
    if let generic = name.firstIndex(of: "<") { name = String(name[..<generic]) }
    for suffix in [
        "LayoutAsyncOperation", "LayoutOperation", "LayoutAlgorithm", "EdgeRouter", "Operation", "Algorithm", "Router",
    ]
    where name.hasSuffix(suffix) && name.count > suffix.count {
        name.removeLast(suffix.count)
        break
    }
    return value is any EdgeRouter ? "\(name) routing" : name
}
