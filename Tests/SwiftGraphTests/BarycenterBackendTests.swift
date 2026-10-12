import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct BarycenterBackendTests {
    func graph(_ count: Int = 17, explicitAnchors: Bool = true, origin: Double = 0) -> LayoutGraph {
        let graph = LayoutGraph()
        for i in 0..<count {
            let node = LayoutNode(id: String(i), width: 8 + Double(i % 3), height: 8)
            node.center = Point(x: origin + Double(i * 50), y: origin + Double(i % 3 * 90))
            graph.addNode(node)
        }
        for i in 1..<count { graph.addEdge(LayoutEdge(source: graph.nodes[i - 1], target: graph.nodes[i])) }
        if count > 2 {
            graph.addEdge(LayoutEdge(source: graph.nodes[0], target: graph.nodes[1]))
            let loop = LayoutEdge(source: graph.nodes[1], target: graph.nodes[1]); loop.path = [.zero]
            graph.addEdge(loop)
        }
        if explicitAnchors && count > 0 {
            graph.nodes[0].metadata[GraphMetadataKeys.fixed] = true
            graph.nodes[count - 1].metadata[GraphMetadataKeys.fixed] = true
        }
        return graph
    }
    func configuration(_ iterations: Int = 3) -> BarycenterLayoutConfiguration {
        var value = BarycenterLayoutConfiguration(); value.iterations = iterations; return value
    }
    func automaticOptions() -> MetalLayoutOptions {
        var options = MetalLayoutOptions(); options.minimumNodeCount = 0; options.minimumIterations = 0; return options
    }

    @Test(arguments: [0, 1, 3], [false, true])
    func cpuMatchesExistingAnchorsCleanupAndRoutes(_ iterations: Int, _ anchors: Bool) async throws {
        let a = graph(explicitAnchors: anchors), b = graph(explicitAnchors: anchors)
        a.nodes[3].isGroup = true; b.nodes[3].isGroup = true
        let algorithm = BarycenterLayoutAlgorithm(); algorithm.iterations = iterations
        try algorithm.applyLayout(a)
        let operation = BarycenterLayoutOperation(backend: .cpu, configuration: configuration(iterations))
        try await operation.applyLayoutAsync(b)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
        #expect(operation.lastMetrics?.backend == .cpu)
    }

    @Test func selectionValidationAndEmptyGraphsAreExplicit() async throws {
        let small = BarycenterLayoutOperation(backend: .automatic)
        try await small.applyLayoutAsync(graph())
        #expect(small.lastMetrics?.fallbackReason == .belowThreshold)
        let executor = LayoutExecutor(options: automaticOptions(), metalEnabled: false)
        let automatic = BarycenterLayoutOperation(backend: .automatic, executor: executor)
        try await automatic.applyLayoutAsync(graph())
        #expect(automatic.lastMetrics?.fallbackReason == .metalUnavailable)
        let explicit = BarycenterLayoutOperation(backend: .metal, executor: executor)
        let g = graph(), before = g.nodes.map(\.bounds)
        await #expect(throws: OrganicLayoutError.self) { try await explicit.applyLayoutAsync(g) }
        #expect(g.nodes.map(\.bounds) == before && explicit.lastMetrics == nil)
        explicit.configuration.iterations = -1
        await #expect(throws: LayoutExecutionError.self) { try await explicit.applyLayoutAsync(g) }
        explicit.configuration = configuration()
        try await explicit.applyLayoutAsync(LayoutGraph())
        #expect(explicit.lastMetrics?.fallbackReason == .noWork)
        try await explicit.applyLayoutAsync(graph(1))
        #expect(explicit.lastMetrics?.fallbackReason == .noWork)
    }

    @Test func zeroIterationsStillSeparatesAndPreservesSelfLoops() async throws {
        let g = graph(3), a = graph(3)
        for graph in [g, a] { graph.nodes[1].center = graph.nodes[0].center }
        let algorithm = BarycenterLayoutAlgorithm(); algorithm.iterations = 0; try algorithm.applyLayout(a)
        let op = BarycenterLayoutOperation(backend: .metal, executor: LayoutExecutor(metalEnabled: false), configuration: configuration(0))
        try await op.applyLayoutAsync(g)
        #expect(g.nodes.map(\.bounds) == a.nodes.map(\.bounds))
        #expect(g.edges.map(\.path) == a.edges.map(\.path))
        #expect(op.lastMetrics?.fallbackReason == .noWork)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"), arguments: [3, 127, 128, 129], [false, true])
    func metalMatchesCPUAndKeepsAnchors(_ count: Int, _ anchors: Bool) async throws {
        let a = graph(count, explicitAnchors: anchors), b = graph(count, explicitAnchors: anchors)
        let original = b.nodes.map(\.bounds), c = configuration(1)
        try await BarycenterLayoutOperation(backend: .cpu, configuration: c).applyLayoutAsync(a)
        let operation = BarycenterLayoutOperation(backend: .metal, configuration: c)
        try await operation.applyLayoutAsync(b)
        #expect(operation.lastMetrics?.backend == .metal)
        for (x, y) in zip(a.nodes, b.nodes) { #expect((x.center - y.center).length < 0.01) }
        if anchors { #expect(b.nodes.first!.bounds == original.first! && b.nodes.last!.bounds == original.last!) }
        #expect(b.edges.last!.path == [.zero])
        #expect(b.edges.filter { $0.source !== $0.target }.allSatisfy { $0.path == [$0.source.center, $0.target.center] })
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func automaticSelectionPrecisionFallbackAndResourceReuse() async throws {
        let executor = LayoutExecutor(options: automaticOptions()), a = graph(), b = graph()
        let automatic = BarycenterLayoutOperation(backend: .automatic, executor: executor)
        let explicit = BarycenterLayoutOperation(backend: .metal, executor: executor)
        try await automatic.applyLayoutAsync(a); try await explicit.applyLayoutAsync(b)
        #expect(automatic.lastMetrics?.backend == .metal)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        let stats = await executor.statistics()
        #expect(stats.pipelineBuilds == 2 && stats.bufferReuses >= 5)
        let large = graph(), reference = graph()
        large.nodes[0].x = -1e10; reference.nodes[0].x = -1e10
        let before = large.nodes.map(\.bounds), submitted = stats.submittedBatches
        await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(large) }
        #expect(large.nodes.map(\.bounds) == before)
        try await automatic.applyLayoutAsync(large)
        try await BarycenterLayoutOperation(backend: .cpu).applyLayoutAsync(reference)
        #expect(automatic.lastMetrics?.fallbackReason == .precisionLimit)
        #expect(large.nodes.map(\.bounds) == reference.nodes.map(\.bounds))
        #expect(await executor.statistics().submittedBatches == submitted)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func localOriginAndConcurrentRequestsPreserveGeometry() async throws {
        let a = graph(17), b = graph(17, origin: 1e12), executor = LayoutExecutor()
        let c = configuration(1), pin = b.nodes[0].bounds
        let first = Task { try await BarycenterLayoutOperation(backend: .metal, executor: executor, configuration: c).applyLayoutAsync(a) }
        let second = Task { try await BarycenterLayoutOperation(backend: .metal, executor: executor, configuration: c).applyLayoutAsync(b) }
        try await first.value; try await second.value
        #expect(b.nodes[0].bounds == pin)
        for i in a.nodes.indices { #expect((b.nodes[i].center - Point(x: 1e12, y: 1e12) - a.nodes[i].center).length < 0.001) }
        let stats = await executor.statistics()
        #expect(stats.submittedBatches == stats.completedBatches)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"), arguments: [false, true])
    func suspendedMetalRejectsEditsAndCancellation(_ cancel: Bool) async throws {
        let g = graph(129), original = g.nodes.map(\.bounds)
        var options = automaticOptions(); options.iterationsPerBatch = 1
        let executor = LayoutExecutor(options: options)
        let operation = BarycenterLayoutOperation(backend: .metal, executor: executor, configuration: configuration(cancel ? 100_000 : 1_000))
        let task = Task { try await operation.applyLayoutAsync(g) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await executor.statistics().submittedBatches == 0 {
            if ContinuousClock.now >= deadline { throw LayoutExecutionError.invalidInput("No barycenter GPU submission") }
            await Task.yield()
        }
        if cancel { task.cancel() } else { g.edges[0].sourcePort = .top }
        if cancel { await #expect(throws: CancellationError.self) { try await task.value } }
        else { await #expect(throws: LayoutExecutionError.staleGraph) { try await task.value } }
        #expect(g.nodes.map(\.bounds) == original && operation.lastMetrics == nil)
        let stats = await executor.statistics()
        #expect(stats.submittedBatches == stats.completedBatches)
    }
}
