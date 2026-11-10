import Foundation

public final class TreeLayoutOperation: LayoutExecutionReporting {
    public let style: TreeLayoutStyle
    public var configuration: TreeLayoutConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }

    public init(
        style: TreeLayoutStyle,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configuration: TreeLayoutConfiguration = .init()
    ) {
        self.style = style
        self.backend = backend
        self.executor = executor
        self.configuration = configuration
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now
        let configuration = self.configuration
        try Task.checkCancellation()
        try configuration.validate(style)
        let assistantInput = graph.nodes.map { ($0.data as? String)?.lowercased() == "assistant" }
        let transaction = try LayoutTransaction(graph)
        let computeStart = ContinuousClock.now
        let plan = try LayoutStageScope.run("Plan", to: 0.3) {
            try treePlacementPlan(transaction.working, style: style, configuration: configuration)
        }
        let style = self.style
        let executor = self.executor
        let backend = self.backend
        var result = try await LayoutStageScope.run("Placement", from: 0.3, to: 0.9) {
            let result = try await executor.placement(plan.state, backend: backend)
            if result.bounds == nil { try configuration.algorithm(style).applyLayout(transaction.working) }
            return result
        }
        if let bounds = result.bounds {
            for (node, bound) in zip(plan.targets, bounds) { node.bounds = bound }
            if style == .tree || style == .orgChart {
                let a = Adjacency(transaction.working)
                LayoutStageScope.run("Pack forest", from: 0.9) {
                    packForest(
                        a.nodes,
                        components: Forest(a).components,
                        spacing: max(20, style == .tree ? configuration.nodeSeparation : configuration.siblingDistance)
                    )
                }
            }
            if style != .treeMap { straightEdges(transaction.working) }
            result.metrics.metalStages = [
                style == .treeMap ? "subtree weights and rectangle partition" : "ordered tree placement"
            ]
            result.metrics.cpuStages = [
                style == .treeMap
                    ? "snapshot, forest traversal and orientation precision analysis" : "snapshot and forest traversal"
            ]
            if style != .treeMap { result.metrics.cpuStages.append("edge routing") }
        } else {
            result.metrics.cpuStages = ["tree placement"]
            if style != .treeMap { result.metrics.cpuStages.append("edge routing") }
        }
        if style == .tree || style == .orgChart { result.metrics.cpuStages.append("component rectangle packing") }
        result.metrics.computeSeconds = computeStart.duration(to: .now).seconds
        if style == .orgChart
            && assistantInput != graph.nodes.map({ ($0.data as? String)?.lowercased() == "assistant" })
        {
            throw LayoutExecutionError.staleGraph
        }
        try transaction.commit(to: graph)
        result.metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = result.metrics
    }
}
