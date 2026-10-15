import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct DirectedBackendTests {
    func graph() -> LayoutGraph {
        let graph = LayoutGraph()
        for i in 0..<6 { graph.addNode(LayoutNode(id: "n\(i)", width: 25, height: 15)) }
        for (a, b) in [(0, 1), (0, 2), (1, 3), (2, 3), (3, 4), (4, 1), (2, 2)] {
            let edge = LayoutEdge(source: graph.nodes[a], target: graph.nodes[b]); graph.addEdge(edge)
        }
        graph.edges[0].sourcePort = .bottom; graph.edges[0].targetPort = .top
        return graph
    }
    func configuration(_ mode: DirectedLayoutMode, graph: LayoutGraph) -> DirectedLayoutConfiguration {
        var configuration = DirectedLayoutConfiguration(); configuration.mode = mode; configuration.candidateCount = 1
        configuration.feedbackEdges = [5]; configuration.edgeWidths = [1, 2, 3, 1, 2, 1, 1]
        if mode != .fresh {
            for (i, node) in graph.nodes.enumerated() { configuration.previousBounds[node.id] = Rect(x: Float(i * 100), y: Float(i % 2 * 160), width: node.width, height: node.height) }
            configuration.fixedNodeIDs = [graph.nodes[0].id]
            if mode == .incremental { configuration.previousBounds.removeValue(forKey: graph.nodes[4].id); configuration.insertionOrigins[graph.nodes[4].id] = Point(x: 450, y: 350) }
        }
        return configuration
    }
    func expectNear(_ a: LayoutGraph, _ b: LayoutGraph) {
        for (x, y) in zip(a.nodes, b.nodes) { #expect((x.center - y.center).length < 1e-4); #expect(x.width == y.width && x.height == y.height) }
        for (x, y) in zip(a.edges, b.edges) {
            #expect(x.path.count == y.path.count)
            for (p, q) in zip(x.path, y.path) { #expect((p - q).length < 1e-4) }
            #expect(x.sourcePort == y.sourcePort && x.targetPort == y.targetPort)
        }
    }
    @Test(arguments: [DirectedLayoutMode.fresh, .incremental, .routesOnly])
    func cpuKeepsDirectedModesPortsAndFeedback(_ mode: DirectedLayoutMode) async throws {
        let a = graph(), b = graph(), c = configuration(mode, graph: a)
        let original = try DirectedLayoutOperation(configuration: c).apply(a)
        let operation = DirectedLayoutAsyncOperation(backend: .cpu, configuration: c)
        try await operation.applyLayoutAsync(b); expectNear(a, b)
        #expect(operation.lastDiagnostics?.crossings == original.crossings)
        #expect(operation.lastDiagnostics?.feedbackEdgeIndices == original.feedbackEdgeIndices)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"), arguments: [DirectedLayoutMode.fresh, .incremental, .routesOnly])
    func metalKeepsDirectedModesPortsAndFeedback(_ mode: DirectedLayoutMode) async throws {
        let a = graph(), b = graph(), c = configuration(mode, graph: a), executor = LayoutExecutor()
        let original = try DirectedLayoutOperation(configuration: c).apply(a)
        let operation = DirectedLayoutAsyncOperation(backend: .metal, executor: executor, configuration: c)
        try await operation.applyLayoutAsync(b); expectNear(a, b)
        #expect(operation.lastMetrics?.backend == .metal)
        #expect(operation.lastDiagnostics?.crossings == original.crossings)
        #expect(operation.lastDiagnostics?.sharedRuns == original.sharedRuns)
        #expect(operation.lastDiagnostics?.feedbackEdgeIndices == original.feedbackEdgeIndices)
        #expect(operation.lastMetrics?.metalStages.contains("directed-geometry-scoring") == true)
        if mode != .fresh { #expect(operation.lastMetrics?.metalStages.contains("hierarchy-ordering") == false) }
        #expect(await executor.statistics().submittedBatches > 0)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"))
    func freshFixedNodeConstraintsAndCacheHitsPreserveBackendAccounting() async throws {
        let a = graph(), b = graph(), cache = DirectedLayoutCache(), executor = LayoutExecutor()
        var c = configuration(.fresh, graph: a); c.fixedNodeIDs = ["n0"]
        a.nodes[0].center = Point(x: 75, y: 50); b.nodes[0].center = a.nodes[0].center
        c.previousBounds["n0"] = a.nodes[0].bounds
        try DirectedLayoutOperation(configuration: c).apply(a)
        let operation = DirectedLayoutAsyncOperation(backend: .metal, executor: executor, configuration: c, cache: cache)
        try await operation.applyLayoutAsync(b); expectNear(a, b)
        #expect(b.nodes[0].center == Point(x: 75, y: 50))
        try await operation.applyLayoutAsync(b)
        #expect(operation.lastDiagnostics?.cachedComponents == 1)
        #expect(operation.lastMetrics?.metalStages == ["directed-geometry-scoring"])
        #expect(operation.lastMetrics?.cpuStages.contains("component-packing") == false)
    }
    @Test func unavailableEmptyAndInvalidConfiguration() async throws {
        var options = MetalLayoutOptions(); options.minimumNodeCount = 0
        let executor = LayoutExecutor(options: options, metalEnabled: false), graph = graph(), before = graph.nodes.map(\.bounds)
        let explicit = DirectedLayoutAsyncOperation(backend: .metal, executor: executor)
        await #expect(throws: OrganicLayoutError.self) { try await explicit.applyLayoutAsync(graph) }
        #expect(graph.nodes.map(\.bounds) == before && explicit.lastDiagnostics == nil && explicit.lastMetrics == nil)
        let automatic = DirectedLayoutAsyncOperation(backend: .automatic, executor: executor)
        try await automatic.applyLayoutAsync(graph); #expect(automatic.lastMetrics?.fallbackReason == .metalUnavailable)
        try await explicit.applyLayoutAsync(LayoutGraph()); #expect(explicit.lastMetrics?.fallbackReason == .noWork)
        explicit.configuration.clearance = .infinity
        await #expect(throws: LayoutExecutionError.self) { try await explicit.applyLayoutAsync(graph) }
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"))
    func geometryKernelDeduplicatesCrossingsSharedRunsAndCountsOverlaps() async throws {
        let graph = LayoutGraph()
        for i in 0..<4 {
            let node = LayoutNode(id: "g\(i)", width: 5, height: 5)
            node.center = Point(x: Float(i * 20), y: 50); graph.addNode(node)
        }
        graph.nodes[1].center = graph.nodes[0].center + Point(x: 2, y: 1)
        let paths = [
            [Point(x: 0, y: 0), Point(x: 30, y: 0), Point(x: 0, y: 0)],
            [Point(x: 15, y: -10), Point(x: 15, y: 10), Point(x: 15, y: -10)],
            [Point(x: 5, y: 0), Point(x: 25, y: 0)],
            [Point(x: 2, y: 3)]
        ]
        for path in paths {
            let edge = LayoutEdge(source: graph.nodes[0], target: graph.nodes[3]); edge.path = path; graph.addEdge(edge)
        }
        let cpu = try DirectedGeometry.measure(nodes: graph.nodes, edges: graph.edges)
        let executor = LayoutExecutor()
        let gpu = try await executor.directedTestScore(DirectedExecutionSnapshot(graph))
        #expect(gpu == [cpu.missing, cpu.overlaps, cpu.crossings, cpu.shared, cpu.bends])
        #expect(cpu.crossings == 2 && cpu.shared == 1 && cpu.overlaps == 1)
        #expect(await executor.statistics().submittedBatches > 0)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"))
    func geometryEqualityKeepsDistinctDoubleCrossingsAndSubULPBodyOverlap() async throws {
        let graph = LayoutGraph(), y: Float = 1000.1, otherY = y.nextUp
        let first = LayoutNode(id: "first", width: 20, height: 10)
        first.bounds = Rect(x: y, y: 30, width: 20, height: 10); graph.addNode(first)
        let second = LayoutNode(id: "second", width: 5, height: 10)
        second.bounds = Rect(x: first.bounds.right.nextDown, y: 30, width: 5, height: 10); graph.addNode(second)
        let horizontal = LayoutEdge(source: first, target: second)
        horizontal.path = [Point(x: -20, y: y), Point(x: 20, y: y), Point(x: 20, y: otherY), Point(x: -20, y: otherY), Point(x: 20, y: otherY)]
        let vertical = LayoutEdge(source: first, target: second)
        vertical.path = [Point(x: 0, y: y - 10), Point(x: 0, y: y + 10)]
        graph.addEdge(horizontal); graph.addEdge(vertical)
        #expect(otherY != y)
        let expected = try DirectedGeometry.measure(nodes: graph.nodes, edges: graph.edges)
        #expect(expected.crossings == 2 && expected.overlaps == 1)
        let actual = try await LayoutExecutor().directedTestScore(DirectedExecutionSnapshot(graph))
        #expect(actual == [expected.missing, expected.overlaps, expected.crossings, expected.shared, expected.bends])
    }

    func longRoutes(_ segments: Int) -> LayoutGraph {
        let graph = LayoutGraph(), a = LayoutNode(id: "a", width: 1, height: 1), b = LayoutNode(id: "b", width: 1, height: 1)
        a.center = Point(x: -40, y: -40); b.center = Point(x: 40, y: 40)
        graph.addNode(a); graph.addNode(b)
        let horizontal = LayoutEdge(source: a, target: b), vertical = LayoutEdge(source: a, target: b)
        horizontal.path = (0...segments).map { Point(x: $0 % 2 == 0 ? -30 : 30, y: 0) }
        vertical.path = (0...segments).map { Point(x: 0, y: $0 % 2 == 0 ? -30 : 30) }
        graph.addEdge(horizontal); graph.addEdge(vertical)
        return graph
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"))
    func longRouteSegmentPairsKeepExactDeduplication() async throws {
        let graph = longRoutes(129), executor = LayoutExecutor()
        let expected = try DirectedGeometry.measure(nodes: graph.nodes, edges: graph.edges)
        let actual = try await executor.directedTestScore(DirectedExecutionSnapshot(graph))
        #expect(expected.crossings == 1)
        #expect(actual == [expected.missing, expected.overlaps, expected.crossings, expected.shared, expected.bends])
        let statistics = await executor.statistics()
        #expect(statistics.submittedBatches >= 2 && statistics.submittedBatches == statistics.completedBatches)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"))
    func longRouteDecisionCommandsDrainCancellation() async throws {
        let graph = longRoutes(4096), before = graph.edges.map(\.path), snapshot = try DirectedExecutionSnapshot(graph), executor = LayoutExecutor()
        let task = Task { try await executor.directedTestScore(snapshot) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await executor.statistics().submittedBatches == 0 {
            if ContinuousClock.now >= deadline { throw LayoutExecutionError.invalidInput("No long-route scoring submission") }
            await Task.yield()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(graph.edges.map(\.path) == before)
        let statistics = await executor.statistics()
        #expect(statistics.submittedBatches == statistics.completedBatches)
        #expect(statistics.submittedBatches < 1024)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"))
    func precisionFallbackPreservesTheOriginalDirectedDrawing() async throws {
        let a = graph(), b = graph(), executor = LayoutExecutor(options: {
            var options = MetalLayoutOptions(); options.minimumNodeCount = 0; return options
        }())
        var c = configuration(.routesOnly, graph: a)
        for id in c.previousBounds.keys { c.previousBounds[id]!.x += 1e12 }
        let before = b.nodes.map(\.bounds)
        let explicit = DirectedLayoutAsyncOperation(backend: .metal, executor: executor, configuration: c)
        await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(b) }
        #expect(b.nodes.map(\.bounds) == before)
        let automatic = DirectedLayoutAsyncOperation(backend: .automatic, executor: executor, configuration: c)
        try await automatic.applyLayoutAsync(b)
        try DirectedLayoutOperation(configuration: c).apply(a); expectNear(a, b)
        #expect(automatic.lastMetrics?.fallbackReason == .precisionLimit)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"), arguments: [false, true])
    func cancellationAndStaleBoundsAfterActualSubmission(_ cancel: Bool) async throws {
        let graph = graph(), original = graph.nodes.map(\.bounds), executor = LayoutExecutor()
        let operation = DirectedLayoutAsyncOperation(backend: .metal, executor: executor, configuration: configuration(.fresh, graph: graph))
        let task = Task { try await operation.applyLayoutAsync(graph) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await executor.statistics().submittedBatches == 0 {
            if ContinuousClock.now >= deadline { throw LayoutExecutionError.invalidInput("No directed GPU submission") }
            await Task.yield()
        }
        if cancel { task.cancel() } else { graph.edges[0].targetPort = .left }
        if cancel { await #expect(throws: CancellationError.self) { try await task.value } }
        else { await #expect(throws: LayoutExecutionError.staleGraph) { try await task.value } }
        #expect(graph.nodes.map(\.bounds) == original && operation.lastMetrics == nil && operation.lastDiagnostics == nil)
        let stats = await executor.statistics(); #expect(stats.submittedBatches == stats.completedBatches)
    }
}

extension LayoutExecutor {
    func directedTestScore(_ snapshot: DirectedExecutionSnapshot) async throws -> [Int] {
        let graph = snapshot.makeGraph()
        if metal == nil { metal = try MetalForceSolver() }
        let output = try await metal!.directedGeometryAsync(nodes: graph.nodes, edges: graph.edges, tolerance: options.maximumCoordinateError)
        return [output.score.missing, output.score.overlaps, output.score.crossings, output.score.shared, output.score.bends]
    }
}
