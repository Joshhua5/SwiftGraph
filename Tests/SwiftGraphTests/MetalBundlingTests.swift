import Foundation
import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct MetalBundlingTests {
    func midpointBoundaryGraph() -> LayoutGraph {
        let graph = LayoutGraph()
        for (i, x) in [-10.0, 2.2, -6.1, 6.1].enumerated() {
            let node = LayoutNode(id: String(i), width: 0, height: 0); node.center = Point(x: x, y: 0); graph.addNode(node)
        }
        graph.addEdge(LayoutEdge(source: graph.nodes[0], target: graph.nodes[1]))
        graph.addEdge(LayoutEdge(source: graph.nodes[2], target: graph.nodes[3]))
        return graph
    }

    @Test func midpointCompatibilityMatchesLegacyAtDistanceBoundary() throws {
        let graph = midpointBoundaryGraph()
        var configuration = EdgeBundlingConfiguration(); configuration.iterations = 1; configuration.segments = 2
        configuration.bundlingDistance = 3.9
        let midpoint = (graph.edges[0].source.center + graph.edges[0].target.center) / 2
        let alternate = graph.edges[0].source.center + (graph.edges[0].target.center - graph.edges[0].source.center) / 2
        #expect(midpoint.x == -3.9 && alternate.x < -3.9)
        let prepared = try GraphCheckpoint(graph).snapshot.prepareBundling(configuration, tolerance: 0.01)
        #expect(prepared.state.compatible.count == 2)
        #expect(prepared.state.offsets == [0, 1, 2])
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func gpuBundlingKeepsMidpointBoundaryCompatibility() async throws {
        let cpu = midpointBoundaryGraph(), gpu = midpointBoundaryGraph()
        var configuration = EdgeBundlingConfiguration(); configuration.iterations = 1; configuration.segments = 2
        configuration.bundlingDistance = 3.9
        try await EdgeBundlingOperation(backend: .cpu, configuration: configuration).applyLayoutAsync(cpu)
        let operation = EdgeBundlingOperation(backend: .metal, configuration: configuration)
        try await operation.applyLayoutAsync(gpu)
        #expect(operation.lastMetrics?.backend == .metal)
        for (a, b) in zip(cpu.edges, gpu.edges) {
            for (p, q) in zip(a.path, b.path) { #expect((p - q).length < 1e-5) }
        }
    }

    func graph() -> LayoutGraph {
        let g = LayoutGraph()
        for i in 0..<8 {
            let n = LayoutNode(id: String(i), width: 20, height: 10)
            n.center = Point(x: i % 2 == 0 ? 10 : 300, y: Double(i / 2) * 30)
            g.addNode(n)
        }
        for i in stride(from: 0, to: 8, by: 2) {
            let reverse = i % 4 == 0
            g.addEdge(LayoutEdge(source: g.nodes[reverse ? i + 1 : i], target: g.nodes[reverse ? i : i + 1]))
        }
        let loop = LayoutEdge(source: g.nodes[0], target: g.nodes[0])
        loop.path = [Point(x: 1, y: 2), Point(x: 3, y: 4)]; g.addEdge(loop)
        return g
    }

    @Test func asyncCPUBundlingMatchesDefault() async throws {
        let a = graph(), b = graph(), router = EdgeBundlingRouter()
        router.routeEdges(a)
        let operation = EdgeBundlingOperation(backend: .cpu)
        try await operation.applyLayoutAsync(b)
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
        #expect(operation.lastMetrics?.backend == .cpu)
    }

    @Test func zeroSegmentsAndMemoryValidation() async throws {
        let g = graph(), executor = LayoutExecutor(metalEnabled: false)
        var configuration = EdgeBundlingConfiguration(); configuration.segments = 0
        let operation = EdgeBundlingOperation(backend: .metal, executor: executor, configuration: configuration)
        let loop = g.edges.last!.path
        try await operation.applyLayoutAsync(g)
        #expect(g.edges.dropLast().allSatisfy { $0.path == [$0.source.center, $0.target.center] })
        #expect(g.edges.last!.path == loop)
        #expect(operation.lastMetrics?.fallbackReason == .noWork)
        operation.configuration.segments = .max
        let paths = g.edges.map(\.path)
        await #expect(throws: LayoutExecutionError.self) { try await operation.applyLayoutAsync(g) }
        #expect(g.edges.map(\.path) == paths)
    }

    @Test func automaticSelectionAndUnavailableDeviceAreExplicit() async throws {
        let below = EdgeBundlingOperation(backend: .automatic)
        try await below.applyLayoutAsync(graph())
        #expect(below.lastMetrics?.fallbackReason == .belowThreshold)
        var options = MetalLayoutOptions(); options.minimumBundlingEdgeCount = 0; options.minimumIterations = 0
        let executor = LayoutExecutor(options: options, metalEnabled: false)
        let automatic = EdgeBundlingOperation(backend: .automatic, executor: executor)
        try await automatic.applyLayoutAsync(graph())
        #expect(automatic.lastMetrics?.backend == .cpu && automatic.lastMetrics?.fallbackReason == .metalUnavailable)
        let explicit = EdgeBundlingOperation(backend: .metal, executor: executor), g = graph()
        let paths = g.edges.map(\.path)
        await #expect(throws: OrganicLayoutError.self) { try await explicit.applyLayoutAsync(g) }
        #expect(g.edges.map(\.path) == paths && explicit.lastMetrics == nil)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func automaticSelectionAndPrecisionFallbackMatchReferenceBackends() async throws {
        var options = MetalLayoutOptions(); options.minimumBundlingEdgeCount = 0; options.minimumIterations = 0
        let executor = LayoutExecutor(options: options), a = graph(), b = graph()
        let automatic = EdgeBundlingOperation(backend: .automatic, executor: executor)
        let explicit = EdgeBundlingOperation(backend: .metal, executor: executor)
        try await automatic.applyLayoutAsync(a); try await explicit.applyLayoutAsync(b)
        #expect(automatic.lastMetrics?.backend == .metal && a.edges.map(\.path) == b.edges.map(\.path))
        let wide = graph(), reference = graph()
        wide.nodes[0].x = -1e10; reference.nodes[0].x = -1e10
        let before = wide.edges.map(\.path), submitted = await executor.statistics().submittedBatches
        await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(wide) }
        #expect(wide.edges.map(\.path) == before)
        try await automatic.applyLayoutAsync(wide)
        try await EdgeBundlingOperation(backend: .cpu).applyLayoutAsync(reference)
        #expect(wide.edges.map(\.path) == reference.edges.map(\.path))
        #expect(automatic.lastMetrics?.fallbackReason == .precisionLimit)
        #expect(await executor.statistics().submittedBatches == submitted)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: [1, 3, 8, 9, 30])
    func metalMatchesCPUBundlesAndKeepsEndpoints(_ iterations: Int) async throws {
        let a = graph(), b = graph(), before = b.nodes.map(\.bounds), loop = b.edges.last!.path
        var configuration = EdgeBundlingConfiguration(); configuration.iterations = iterations
        try await EdgeBundlingOperation(backend: .cpu, configuration: configuration).applyLayoutAsync(a)
        let operation = EdgeBundlingOperation(backend: .metal, configuration: configuration)
        try await LayoutBuilder.create(b).useAsyncAlgorithm(operation).applyAsync()
        #expect(operation.lastMetrics?.backend == .metal)
        #expect(b.nodes.map(\.bounds) == before)
        #expect(b.edges.last!.path == loop)
        for (x, y) in zip(a.edges.dropLast(), b.edges.dropLast()) {
            #expect(x.path.count == y.path.count)
            for (p, q) in zip(x.path, y.path) { #expect((p - q).length < 0.01) }
            #expect(y.path.first == y.source.center && y.path.last == y.target.center)
        }
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func organicAndBundlingShareExecutorAndPreserveRouteOrder() async throws {
        let g = graph(), executor = LayoutExecutor()
        try await LayoutBuilder.create(g)
            .useOrganic(backend: .metal, executor: executor) { $0.iterations = 2 }
            .routeWithBundling(backend: .metal, executor: executor) { $0.iterations = 3 }
            .routeSelfLoops().clipEdgeEndpoints().applyAsync()
        #expect(g.edges.allSatisfy { $0.path.count >= 2 })
        #expect(g.edges.last!.path.count > 2)
        let stats = await executor.statistics()
        #expect(stats.pipelineBuilds == 2)
        #expect(stats.bufferReuses > 0)
        #expect(stats.submittedBatches == stats.completedBatches)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func largeOffsetBundleEndpointsAreExact() async throws {
        let g = graph()
        for n in g.nodes { n.center = n.center + Point(x: 1e12, y: -1e12) }
        try await EdgeBundlingOperation(backend: .metal).applyLayoutAsync(g)
        for edge in g.edges where edge.source !== edge.target {
            #expect(edge.path.first == edge.source.center && edge.path.last == edge.target.center)
            #expect(edge.path.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        }
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: [false, true])
    func suspendedBundleRejectsEditsOrCancellation(_ cancel: Bool) async throws {
        let g = graph()
        var options = MetalLayoutOptions(); options.iterationsPerBatch = 1
        let executor = LayoutExecutor(options: options)
        var c = EdgeBundlingConfiguration(); c.iterations = 1_000; c.k = 0
        let operation = EdgeBundlingOperation(backend: .metal, executor: executor, configuration: c)
        let task = Task { try await operation.applyLayoutAsync(g) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await executor.statistics().submittedBatches == 0 {
            if ContinuousClock.now >= deadline { throw LayoutExecutionError.invalidInput("No GPU submission") }
            try await Task.sleep(for: .milliseconds(1))
        }
        if cancel { task.cancel() }
        else { g.edges[0].path = [Point(x: -999, y: -999)] }
        let paths = g.edges.map(\.path)
        if cancel { await #expect(throws: CancellationError.self) { try await task.value } }
        else { await #expect(throws: LayoutExecutionError.staleGraph) { try await task.value } }
        #expect(g.edges.map(\.path) == paths)
        #expect(operation.lastMetrics == nil)
        let stats = await executor.statistics()
        #expect(stats.submittedBatches == stats.completedBatches)
    }
}
