import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct HierarchyBackendTests {
    func graph(_ count: Int = 19, fractional: Bool = false) -> LayoutGraph {
        let graph = LayoutGraph()
        for i in 0..<count {
            let node = LayoutNode(id: "n\(i)", width: 12 + Float(i % 7) + (fractional ? Float(i % 3) / 7 : 0), height: 9 + Float(i % 5))
            node.center = Point(x: Float(i * 19), y: Float(i % 4 * 17)); graph.addNode(node)
        }
        if count > 1 { for i in 1..<count { graph.addEdge(LayoutEdge(source: graph.nodes[(i - 1) / 2], target: graph.nodes[i])) } }
        if count > 4 {
            graph.addEdge(LayoutEdge(source: graph.nodes[0], target: graph.nodes[count - 1]))
            graph.addEdge(LayoutEdge(source: graph.nodes[count - 1], target: graph.nodes[1]))
            graph.addEdge(LayoutEdge(source: graph.nodes[2], target: graph.nodes[2]))
            graph.addEdge(LayoutEdge(source: graph.nodes[0], target: graph.nodes[1]))
            graph.nodes[3].isGroup = true
            graph.nodes[0].metadata[GraphMetadataKeys.fixed] = true
            graph.edges[0].sourcePort = .left; graph.edges[0].targetPort = .top
        }
        return graph
    }
    func configuration(_ narrow: Bool) -> HierarchicalLayoutConfiguration {
        var configuration = HierarchicalLayoutConfiguration()
        configuration.layerSeparation = 27.25; configuration.nodeSeparation = 13.125
        configuration.maxNodesPerRank = narrow ? 3 : nil
        return configuration
    }
    func expectNear(_ a: LayoutGraph, _ b: LayoutGraph, tolerance: Float = 1e-4) {
        #expect(a.nodes.count == b.nodes.count && a.edges.count == b.edges.count)
        for (x, y) in zip(a.nodes, b.nodes) {
            #expect((x.center - y.center).length < tolerance)
            #expect(x.width == y.width && x.height == y.height)
        }
        for (x, y) in zip(a.edges, b.edges) {
            #expect(x.path.count == y.path.count)
            for (p, q) in zip(x.path, y.path) { #expect((p - q).length < tolerance) }
            #expect(x.sourcePort == y.sourcePort && x.targetPort == y.targetPort)
        }
    }
    @Test(arguments: [0, 1, 19], [false, true])
    func cpuParityIncludesVirtualNodesCyclesGroupsAndRankCapacity(_ count: Int, _ narrow: Bool) async throws {
        let a = graph(count, fractional: true), b = graph(count, fractional: true), c = configuration(narrow)
        let legacy = HierarchicalLayoutAlgorithm(); legacy.layerSeparation = c.layerSeparation
        legacy.nodeSeparation = c.nodeSeparation; legacy.maxNodesPerRank = c.maxNodesPerRank
        try legacy.applyLayout(a)
        let operation = HierarchicalLayoutOperation(backend: .cpu, configuration: c)
        try await operation.applyLayoutAsync(b); expectNear(a, b)
        #expect(operation.lastMetrics?.backend == .cpu)
    }
    @Test(arguments: [0, 1, 19])
    func cpuSeriesParallelPreservesTransposeSemantics(_ count: Int) async throws {
        let a = graph(count, fractional: true), b = graph(count, fractional: true)
        try SeriesParallelLayoutAlgorithm().applyLayout(a)
        try await SeriesParallelLayoutOperation(backend: .cpu).applyLayoutAsync(b); expectNear(a, b)
    }
    @Test func explicitUnavailableValidationAndDanglingEndpointsAreTransactional() async throws {
        var options = MetalLayoutOptions(); options.minimumNodeCount = 0
        let executor = LayoutExecutor(options: options, metalEnabled: false)
        let graph = graph(), before = graph.nodes.map(\.bounds)
        let explicit = HierarchicalLayoutOperation(backend: .metal, executor: executor)
        await #expect(throws: OrganicLayoutError.self) { try await explicit.applyLayoutAsync(graph) }
        #expect(graph.nodes.map(\.bounds) == before && explicit.lastMetrics == nil)
        let automatic = HierarchicalLayoutOperation(backend: .automatic, executor: executor)
        try await automatic.applyLayoutAsync(graph)
        #expect(automatic.lastMetrics?.fallbackReason == .metalUnavailable)
        explicit.configuration.layerSeparation = .nan
        await #expect(throws: LayoutExecutionError.self) { try await explicit.applyLayoutAsync(graph) }
        explicit.configuration = .init()
        try await explicit.applyLayoutAsync(LayoutGraph())
        #expect(explicit.lastMetrics?.fallbackReason == .noWork)
        graph.addEdge(LayoutEdge(source: graph.nodes[0], target: LayoutNode(id: "outside", width: 1, height: 1)))
        await #expect(throws: LayoutExecutionError.self) { try await automatic.applyLayoutAsync(graph) }
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"), arguments: [1, 19, 129], [false, true])
    func metalParityUsesRealOrderingAndPAV(_ count: Int, _ narrow: Bool) async throws {
        let a = graph(count, fractional: true), b = graph(count, fractional: true), c = configuration(narrow)
        try await HierarchicalLayoutOperation(backend: .cpu, configuration: c).applyLayoutAsync(a)
        let executor = LayoutExecutor(), operation = HierarchicalLayoutOperation(backend: .metal, executor: executor, configuration: c)
        try await operation.applyLayoutAsync(b); expectNear(a, b)
        #expect(operation.lastMetrics?.backend == .metal)
        #expect(operation.lastMetrics?.metalStages.contains("weighted-isotonic-block-decisions") == true)
        #expect(await executor.statistics().submittedBatches > 0)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"))
    func seriesParallelMetalParityAndResourceReuse() async throws {
        let a = graph(33), b = graph(33), executor = LayoutExecutor()
        try SeriesParallelLayoutAlgorithm().applyLayout(a)
        let operation = SeriesParallelLayoutOperation(backend: .metal, executor: executor)
        try await operation.applyLayoutAsync(b); expectNear(a, b)
        let first = await executor.statistics()
        try await operation.applyLayoutAsync(graph(33))
        let second = await executor.statistics()
        #expect(first.pipelineBuilds == 3 && second.pipelineBuilds == first.pipelineBuilds)
        #expect(second.bufferReuses >= first.bufferReuses + 11)
        #expect(second.submittedBatches == second.completedBatches)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"))
    func precisionFailureBeforeSubmissionAndAutomaticFallback() async throws {
        var options = MetalLayoutOptions(); options.minimumNodeCount = 0
        let executor = LayoutExecutor(options: options), graph = graph(), reference = self.graph()
        graph.nodes[0].width = 1e10; reference.nodes[0].width = 1e10
        let before = graph.nodes.map(\.bounds)
        let explicit = HierarchicalLayoutOperation(backend: .metal, executor: executor)
        await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(graph) }
        #expect(graph.nodes.map(\.bounds) == before)
        #expect(await executor.statistics().submittedBatches == 0)
        let automatic = HierarchicalLayoutOperation(backend: .automatic, executor: executor)
        try await automatic.applyLayoutAsync(graph)
        try await HierarchicalLayoutOperation(backend: .cpu).applyLayoutAsync(reference)
        expectNear(graph, reference); #expect(automatic.lastMetrics?.fallbackReason == .precisionLimit)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"), arguments: [false, true])
    func submittedHierarchyDrainsCancellationAndRejectsStalePorts(_ cancel: Bool) async throws {
        let graph = graph(257), before = graph.nodes.map(\.bounds), executor = LayoutExecutor()
        let operation = HierarchicalLayoutOperation(backend: .metal, executor: executor, configuration: configuration(true))
        let task = Task { try await operation.applyLayoutAsync(graph) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await executor.statistics().submittedBatches == 0 {
            if ContinuousClock.now >= deadline { throw LayoutExecutionError.invalidInput("No hierarchy submission") }
            await Task.yield()
        }
        if cancel { task.cancel() } else { graph.edges[0].sourcePort = .right }
        if cancel { await #expect(throws: CancellationError.self) { try await task.value } }
        else { await #expect(throws: LayoutExecutionError.staleGraph) { try await task.value } }
        #expect(graph.nodes.map(\.bounds) == before && operation.lastMetrics == nil)
        let statistics = await executor.statistics()
        #expect(statistics.submittedBatches == statistics.completedBatches)
    }
}
