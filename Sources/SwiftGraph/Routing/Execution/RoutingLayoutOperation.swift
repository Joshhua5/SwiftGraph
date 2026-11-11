import Foundation

public final class RoutingLayoutOperation: AsyncLayoutAlgorithm, LayoutExecutionReporting {
    public var configuration: RoutingConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    /// What the last run's router could not do, as indices into `graph.edges`.
    public private(set) var report = RoutingReport()
    @available(*, deprecated, message: "Use report.unroutable")
    public var unroutableEdgeIndices: [Int] { report.unroutable }
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }

    /// Evaluated on the graph's owner before suspension, never transferred to a compute queue.
    public var labelProvider: (LayoutEdge) -> String? = LabelPlacementAlgorithm().labelProvider

    public init(
        _ kind: RoutingKind,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }
    ) {
        var configuration = RoutingConfiguration(kind)
        configure(&configuration)
        self.configuration = configuration
        self.backend = backend
        self.executor = executor
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        report = RoutingReport()
        let start = ContinuousClock.now
        let configuration = self.configuration
        try Task.checkCancellation()
        try configuration.validate()
        let readsLabelText = configuration.kind == .labelPlacement
        let labelTexts =
            readsLabelText ? graph.edges.map(labelProvider) : [String?](repeating: nil, count: graph.edges.count)
        let checkpoint = try RoutingCheckpoint(graph, labels: labelTexts)
        if configuration.kind == .bsp {
            guard
                checkpoint.snapshot.hierarchy.allSatisfy({
                    [$0.bounds.x, $0.bounds.y, $0.bounds.right, $0.bounds.bottom]
                        .allSatisfy { Double(abs($0)) < Double(Int64.max) * 1e-4 / 8 }
                })
            else {
                throw LayoutExecutionError.invalidInput("BSP coordinates exceed quantized indexing range.")
            }
        }
        if configuration.kind == .orthogonalGrouped || configuration.kind == .edgeSeparation {
            let coordinates =
                checkpoint.related.flatMap { [$0.x, $0.y, $0.bounds.right, $0.bounds.bottom] }
                + graph.edges.flatMap { $0.path.flatMap { [$0.x, $0.y] } }
            guard coordinates.allSatisfy({ Double(abs($0)) < Double(Int.max / 8) }) else {
                throw LayoutExecutionError.invalidInput("Routing coordinates exceed integer indexing range.")
            }
        }
        if configuration.kind == .channel, !graph.nodes.isEmpty {
            // The condition above guarantees `graph.nodes` is non-empty.
            let origin = Point(x: graph.nodes.map(\.x).min()! - 50, y: graph.nodes.map(\.y).min()! - 50)
            let spans = graph.nodes.flatMap {
                [$0.x - origin.x, $0.bounds.right - origin.x, $0.y - origin.y, $0.bounds.bottom - origin.y]
            }
            guard spans.allSatisfy({ $0.isFinite && Double(abs($0)) < Double(Int.max / 64) }),
                configuration.gridSize < Int.max / 1_024,
                Double(abs(configuration.bendPenalty)) < Double(Int.max / 64),
                configuration.congestionPenalty < Int.max / max(64, graph.edges.count * 8)
            else {
                throw LayoutExecutionError.invalidInput("Channel local grid or costs exceed integer indexing range.")
            }
        }
        let result = try await executor.routing(checkpoint.snapshot, configuration: configuration, backend: backend)
        try Task.checkCancellation()
        guard
            checkpoint.matches(
                graph,
                labels: readsLabelText
                    ? graph.edges.map(labelProvider) : [String?](repeating: nil, count: graph.edges.count)
            )
        else { throw LayoutExecutionError.staleGraph }
        guard result.bounds.count == checkpoint.related.count else {
            throw LayoutExecutionError.invalidInput("Routing hierarchy result size changed.")
        }
        for i in checkpoint.related.indices { checkpoint.related[i].bounds = result.bounds[i] }
        graph.root.bounds = result.rootBounds
        for i in graph.edges.indices {
            graph.edges[i].path = result.paths[i]
            graph.edges[i].labelBounds = result.labels[i]
        }
        var metrics = result.metrics
        metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics
        report = result.report
    }
}
