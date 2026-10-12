import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct MetalPresetTests {
    private func fixture() -> LayoutGraph {
        let graph = LayoutGraph()
        for i in 0..<8 {
            let node = LayoutNode(id: "p\(i)", width: 24 + Double(i), height: 18)
            node.center = Point(x: Double(i % 4) * 120, y: Double(i / 4) * 150)
            graph.addNode(node)
        }
        for (source, target) in [(0, 1), (0, 2), (1, 3), (2, 3), (3, 4), (4, 5), (6, 7), (1, 1)] {
            graph.addEdge(LayoutEdge(source: graph.nodes[source], target: graph.nodes[target]))
        }
        return graph
    }

    @Test(arguments: LayoutPatternType.allCases)
    func cpuPresetMatchesExistingPattern(_ pattern: LayoutPatternType) async throws {
        let expected = fixture(), actual = fixture()
        try await LayoutBuilder.create(expected).applyPattern(pattern).applyAsync()
        let builder = LayoutBuilder.create(actual).applyPattern(pattern, backend: .cpu)
        try await builder.applyAsync()
        #expect(actual.nodes.map(\.bounds) == expected.nodes.map(\.bounds))
        #expect(actual.edges.map(\.path) == expected.edges.map(\.path))
        #expect(actual.nodes.map { $0.metadata[GraphMetadataKeys.pageRank] as? Double }
                == expected.nodes.map { $0.metadata[GraphMetadataKeys.pageRank] as? Double })
        #expect(actual.nodes.map { $0.metadata[GraphMetadataKeys.cluster] as? Int }
                == expected.nodes.map { $0.metadata[GraphMetadataKeys.cluster] as? Int })
        #expect(!builder.lastExecutionMetrics.isEmpty)
        #expect(builder.lastExecutionMetrics.allSatisfy { $0.requestedBackend == .cpu })
    }

    @Test(arguments: LayoutPatternType.allCases)
    func everyPresetForwardsMetalThroughItsStages(_ pattern: LayoutPatternType) async throws {
        let executor = LayoutExecutor()
        guard LayoutExecutor.isMetalAvailable else { return }
        let graph = fixture(), identities = graph.nodes
        let builder = LayoutBuilder.create(graph).applyPattern(pattern, backend: .metal, executor: executor)
        try await builder.applyAsync()
        #expect(graph.nodes == identities)
        #expect(graph.nodes.allSatisfy { [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) })
        #expect(graph.edges.allSatisfy { $0.path.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
        #expect(!builder.lastExecutionMetrics.isEmpty)
        #expect(builder.lastExecutionMetrics.allSatisfy { $0.requestedBackend == .metal })
        #expect(builder.lastExecutionMetrics.contains { !$0.metalStages.isEmpty })
        let statistics = await executor.statistics()
        #expect(statistics.submittedBatches > 0)
        #expect(statistics.submittedBatches == statistics.completedBatches)
    }

    @Test(arguments: [false, true])
    func analysisCompositionMatchesCPU(_ cluster: Bool) async throws {
        let expected = fixture(), actual = fixture()
        let reference = LayoutBuilder.create(expected)
        let builder = LayoutBuilder.create(actual)
        if cluster {
            reference.applyClusterBased(HierarchicalLayoutAlgorithm())
            builder.applyClusterBased(HierarchicalLayoutOperation(backend: .cpu), backend: .cpu)
        } else {
            reference.applyImportanceBased(HierarchicalLayoutAlgorithm())
            builder.applyImportanceBased(HierarchicalLayoutOperation(backend: .cpu), backend: .cpu)
        }
        try await reference.applyAsync(); try await builder.applyAsync()
        #expect(actual.nodes.map(\.bounds) == expected.nodes.map(\.bounds))
        #expect(actual.edges.map(\.path) == expected.edges.map(\.path))
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func sharedExecutorKeepsDifferentKernelFamiliesIsolated() async throws {
        let executor = LayoutExecutor()
        let graphs = (0..<5).map { _ in fixture() }
        let expected = (0..<5).map { _ in fixture() }
        try CircularLayoutAlgorithm().applyLayout(expected[0])
        try TreeLayoutAlgorithm().applyLayout(expected[1])
        try HierarchicalLayoutAlgorithm().applyLayout(expected[2])
        try LabelPropagationClusteringAlgorithm().applyLayout(expected[3])
        PolylineEdgeRouter().routeEdges(expected[4])
        let operations: [any LayoutExecutionReporting] = [
            BasicLayoutOperation(style: .circular, backend: .metal, executor: executor),
            TreeLayoutOperation(style: .tree, backend: .metal, executor: executor),
            HierarchicalLayoutOperation(backend: .metal, executor: executor),
            AnalysisLayoutOperation(.clusters, backend: .metal, executor: executor),
            RoutingLayoutOperation(.polyline, backend: .metal, executor: executor)
        ]
        let tasks = zip(operations, graphs).map { operation, graph in
            Task { try await operation.applyLayoutAsync(graph) }
        }
        for task in tasks { try await task.value }
        for (actual, reference) in zip(graphs, expected) {
            for (a, b) in zip(actual.nodes, reference.nodes) {
                #expect((a.center - b.center).length < 0.01)
                #expect(a.metadata[GraphMetadataKeys.cluster] as? Int == b.metadata[GraphMetadataKeys.cluster] as? Int)
            }
            for (a, b) in zip(actual.edges, reference.edges) {
                #expect(a.path.count == b.path.count)
                for (x, y) in zip(a.path, b.path) { #expect((x - y).length < 0.01) }
            }
        }
        #expect(operations.allSatisfy { $0.lastExecutionMetrics.contains { !$0.metalStages.isEmpty } })
        let stats = await executor.statistics()
        #expect(stats.submittedBatches > 0 && stats.submittedBatches == stats.completedBatches)
        await executor.releaseCachedBuffers()
        #expect(await executor.statistics().cachedBufferBytes == 0)
    }

}
