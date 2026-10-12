import Foundation
import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct RadialBackendTests {
    func graph(_ count: Int, kind: String = "tree") -> LayoutGraph {
        let graph = LayoutGraph()
        for i in 0..<count {
            let node = LayoutNode(id: String(i), width: 9 + Double(i % 7) * 3, height: 7 + Double(i % 5) * 4)
            node.center = Point(x: Double(i * 73), y: Double(i % 3 * 59))
            graph.addNode(node)
        }
        if kind != "isolated" && count > 1 {
            for i in 1..<count {
                if kind == "forest" && i % 7 == 0 { continue }
                let parent = kind == "star" ? 0 : (i - 1) / 2
                graph.addEdge(LayoutEdge(source: graph.nodes[parent], target: graph.nodes[i]))
            }
        }
        if count > 4 && kind == "cyclic" {
            graph.addEdge(LayoutEdge(source: graph.nodes[4], target: graph.nodes[0]))
            graph.addEdge(LayoutEdge(source: graph.nodes[0], target: graph.nodes[1]))
        }
        if count > 1 && kind != "isolated" {
            let edge = LayoutEdge(source: graph.nodes[1], target: graph.nodes[1])
            edge.path = [Point(x: 1, y: 2), Point(x: 3, y: 4)]; graph.addEdge(edge)
        }
        return graph
    }
    func original(_ graph: LayoutGraph, _ style: RadialLayoutStyle, spacing: Double = 100) throws {
        switch style {
        case .radial: let a = RadialLayoutAlgorithm(); a.layerSeparation = spacing; try a.applyLayout(graph)
        case .star: let a = RadialStarLayoutAlgorithm(); a.radius = spacing; try a.applyLayout(graph)
        case .tree: let a = RadialTreeLayoutAlgorithm(); a.layerDistance = spacing; try a.applyLayout(graph)
        }
    }
    func options(_ tolerance: Double = 0.01) -> MetalLayoutOptions {
        var options = MetalLayoutOptions(); options.minimumRadialPairCount = 0
        options.maximumCoordinateError = tolerance; return options
    }

    @Test(arguments: RadialLayoutStyle.allCases, ["tree", "forest", "cyclic", "isolated"])
    func cpuMatchesExistingFormats(_ style: RadialLayoutStyle, _ kind: String) async throws {
        let a = graph(23, kind: kind), b = graph(23, kind: kind)
        for g in [a, b] {
            g.nodes[4].isGroup = true
            g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
            g.nodes[5].metadata[GraphMetadataKeys.layoutSubset] = true
        }
        try original(a, style, spacing: 37)
        let operation = RadialLayoutOperation(style: style, backend: .cpu, configuration: .init(spacing: 37))
        try await operation.applyLayoutAsync(b)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
        #expect(operation.lastMetrics?.backend == .cpu)
        #expect(b.nodes[0].metadata[GraphMetadataKeys.fixed] as? Bool == true)
    }

    @Test(arguments: RadialLayoutStyle.allCases, [0, 1, 2])
    func emptySingletonAndNoPairWork(_ style: RadialLayoutStyle, _ count: Int) async throws {
        let a = graph(count), b = graph(count)
        try original(a, style)
        let op = RadialLayoutOperation(style: style, backend: .metal, executor: LayoutExecutor(metalEnabled: false), configuration: .init())
        try await op.applyLayoutAsync(b)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
        #expect(op.lastMetrics?.fallbackReason == .noWork)
    }

    @Test func thresholdUnavailableInvalidAndGroupOnlyInputs() async throws {
        let g = graph(17), before = g.nodes.map(\.bounds)
        let executor = LayoutExecutor(options: options(), metalEnabled: false)
        let explicit = RadialLayoutOperation(backend: .metal, executor: executor)
        await #expect(throws: OrganicLayoutError.self) { try await explicit.applyLayoutAsync(g) }
        #expect(g.nodes.map(\.bounds) == before && explicit.lastMetrics == nil)
        let automatic = RadialLayoutOperation(backend: .automatic, executor: executor)
        try await automatic.applyLayoutAsync(g)
        #expect(automatic.lastMetrics?.fallbackReason == .metalUnavailable)
        let small = RadialLayoutOperation(backend: .automatic)
        try await small.applyLayoutAsync(g)
        #expect(small.lastMetrics?.fallbackReason == .belowThreshold)
        explicit.configuration.spacing = .nan
        await #expect(throws: LayoutExecutionError.self) { try await explicit.applyLayoutAsync(g) }
        explicit.configuration.spacing = -1
        await #expect(throws: LayoutExecutionError.self) { try await explicit.applyLayoutAsync(g) }
        let group = graph(3)
        for node in group.nodes { node.isGroup = true }
        let paths = group.edges.map(\.path), bounds = group.nodes.map(\.bounds)
        try await automatic.applyLayoutAsync(group)
        #expect(group.nodes.map(\.bounds) == bounds && group.edges.map(\.path) == paths)
        #expect(automatic.lastMetrics?.fallbackReason == .noWork)
        var invalid = options(); invalid.minimumRadialPairCount = -1
        let badOptions = RadialLayoutOperation(backend: .cpu, executor: LayoutExecutor(options: invalid))
        await #expect(throws: LayoutExecutionError.self) { try await badOptions.applyLayoutAsync(g) }
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"),
          arguments: RadialLayoutStyle.allCases, [17, 127, 128, 129])
    func metalMatchesExistingGeometryAndRoutes(_ style: RadialLayoutStyle, _ count: Int) async throws {
        let a = graph(count, kind: "star"), b = graph(count, kind: "star")
        try original(a, style)
        let op = RadialLayoutOperation(style: style, backend: .metal, configuration: .init())
        try await op.applyLayoutAsync(b)
        #expect(op.lastMetrics?.backend == .metal && op.lastMetrics?.gpuSeconds != nil)
        for (left, right) in zip(a.nodes, b.nodes) { #expect((left.center - right.center).length < 0.01) }
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
        for i in b.nodes.indices {
            for j in (i + 1)..<b.nodes.count { #expect(!b.nodes[i].bounds.intersects(b.nodes[j].bounds)) }
        }
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func automaticPrecisionFallbackAndSharedResources() async throws {
        let executor = LayoutExecutor(options: options())
        let op = RadialLayoutOperation(style: .star, backend: .automatic, executor: executor)
        let a = graph(65), b = graph(65)
        try await op.applyLayoutAsync(a)
        let explicit = RadialLayoutOperation(style: .star, backend: .metal, executor: executor)
        try await explicit.applyLayoutAsync(b)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(op.lastMetrics?.backend == .metal)
        let stats = await executor.statistics()
        #expect(stats.pipelineBuilds == 2 && stats.bufferReuses >= 4)
        let huge = graph(9, kind: "isolated"), reference = graph(9, kind: "isolated")
        huge.nodes[1].width = 1e9; reference.nodes[1].width = 1e9
        let before = huge.nodes.map(\.bounds)
        await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(huge) }
        #expect(huge.nodes.map(\.bounds) == before && explicit.lastMetrics == nil)
        try await op.applyLayoutAsync(huge)
        try original(reference, .star, spacing: 200)
        #expect(op.lastMetrics?.fallbackReason == .precisionLimit)
        #expect(huge.nodes.map(\.bounds) == reference.nodes.map(\.bounds))
        #expect(await executor.statistics().submittedBatches == stats.submittedBatches)
        await executor.releaseCachedBuffers()
        #expect(await executor.statistics().cachedBufferBytes == 0)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func concurrentFormatsKeepGroupsAndPorts() async throws {
        let executor = LayoutExecutor(options: options())
        let graphs = RadialLayoutStyle.allCases.map { _ in graph(31, kind: "cyclic") }
        let references = RadialLayoutStyle.allCases.map { _ in graph(31, kind: "cyclic") }
        for g in graphs + references {
            g.nodes[3].isGroup = true
            g.edges[0].sourcePort = .right; g.edges[0].targetPort = .left
        }
        var tasks: [Task<Void, Error>] = []
        for (index, style) in RadialLayoutStyle.allCases.enumerated() {
            try original(references[index], style)
            tasks.append(Task {
                try await RadialLayoutOperation(style: style, backend: .metal, executor: executor, configuration: .init())
                    .applyLayoutAsync(graphs[index])
            })
        }
        for task in tasks { try await task.value }
        for (a, b) in zip(graphs, references) {
            for (left, right) in zip(a.nodes, b.nodes) { #expect((left.center - right.center).length < 0.01) }
            #expect(a.edges.map(\.path) == b.edges.map(\.path))
            #expect(a.edges[0].sourcePort == .right && a.edges[0].targetPort == .left)
        }
        let stats = await executor.statistics()
        #expect(stats.submittedBatches == stats.completedBatches && stats.pipelineBuilds == 2)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func irregularSectorsCircularSeamAndCollapsedAngles() async throws {
        var seed: UInt64 = 7
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1
            return Double(seed >> 11) / Double(UInt64.max >> 11)
        }
        var rings: [RadialRing] = []
        for count in [2, 17, 127, 128, 129, 513] {
            var angles = (0..<count).map { i in (Double(i) + random() * 0.1) * 2 * .pi / Double(count) }
            angles.swapAt(0, count - 1)
            rings.append(RadialRing(indices: Array(0..<count), angles: angles,
                diameters: (0..<count).map { _ in 5 + random() * 30 }, depth: 1))
        }
        rings.append(RadialRing(indices: [0, 1, 2], angles: [1, 1, 1], diameters: [10, 20, 30], depth: 50))
        for i in rings.indices { rings[i].normalizeCollapsedAngles() }
        let state = try RadialClearanceState(rings, tolerance: 0.01)
        // Executor isolation is tested through operations; this direct kernel test
        // probes nonuniform sectors that are difficult to express as small trees.
        let solver = try MetalForceSolver(), result = try await solver.radialClearanceAsync(state)
        var offset = 0
        for ring in rings {
            var actual = 0.0
            for i in ring.indices.indices {
                let j = Int(result.partners[offset + i]) - offset
                if j != i { actual = max(actual, ring.clearance(i, j)) }
            }
            #expect(abs(actual - (try ring.cpuClearance())) < 0.01)
            offset += ring.indices.count
        }
        let narrow = RadialRing(indices: [0, 1], angles: [0, 2 * .pi - 1e-10], diameters: [10, 10], depth: 1)
        #expect(throws: LayoutExecutionError.precisionLimit) { try RadialClearanceState([narrow], tolerance: 0.01) }
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"), arguments: [false, true])
    func cancellationAndStaleEditsDoNotPublish(_ cancel: Bool) async throws {
        let g = graph(4096, kind: "isolated"), original = g.nodes.map(\.bounds)
        let executor = LayoutExecutor(options: options(1))
        let operation = RadialLayoutOperation(style: .star, backend: .metal, executor: executor)
        let task = Task { try await operation.applyLayoutAsync(g) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while await executor.statistics().submittedBatches == 0 {
            if ContinuousClock.now >= deadline { throw LayoutExecutionError.invalidInput("No radial GPU submission") }
            await Task.yield()
        }
        if cancel { task.cancel() } else { g.nodes[0].name = "edited during layout" }
        if cancel { await #expect(throws: CancellationError.self) { try await task.value } }
        else { await #expect(throws: LayoutExecutionError.staleGraph) { try await task.value } }
        #expect(g.nodes.map(\.bounds) == original && operation.lastMetrics == nil)
        if !cancel { #expect(g.nodes[0].name == "edited during layout") }
        let stats = await executor.statistics()
        #expect(stats.submittedBatches == stats.completedBatches)
    }

    @Test func builderAndMindMapPreserveCPUBehavior() async throws {
        let a = graph(17), b = graph(17)
        try await LayoutBuilder(graph: a).applyMindMap().applyAsync()
        let builder = LayoutBuilder(graph: b).applyPattern(.mindMap, backend: .cpu)
        try await builder.applyAsync()
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
        #expect(builder.lastExecutionMetrics.count == 3)
        #expect(builder.lastExecutionMetrics.allSatisfy { $0.requestedBackend == .cpu })
        let component = ComponentLayoutOperation(RadialLayoutOperation(style: .tree, backend: .cpu))
        try await component.applyLayoutAsync(graph(21, kind: "forest"))
        #expect(!component.lastExecutionMetrics.isEmpty)
    }
}
