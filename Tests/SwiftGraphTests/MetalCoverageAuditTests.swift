import Foundation
import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct MetalCoverageAuditTests {
    private func graph(_ count: Int = 4) -> LayoutGraph {
        let graph = LayoutGraph()
        for i in 0..<count {
            let node = LayoutNode(id: String(i), width: 20, height: 16)
            node.center = Point(x: Float(i % 8) * 47.5 + 12, y: Float(i / 8) * 42.25 + Float(i % 3) * 5 + 10)
            graph.addNode(node)
        }
        for i in 1..<count { graph.addEdge(LayoutEdge(source: graph.nodes[i - 1], target: graph.nodes[i])) }
        return graph
    }
    private func legacyConfiguration(_ budget: Float) -> OrganicLayoutConfiguration {
        var configuration = OrganicLayoutConfiguration(quality: .legacy)
        configuration.iterationBudget = budget; configuration.initialTemperature = 20
        configuration.repulsionForce = 2_000; configuration.attractionForce = 0.05
        return configuration
    }
    @Test func fractionalBudgetAndIntegerCountShareOneAuthoritativeSetting() {
        var c = OrganicLayoutConfiguration(quality: .legacy)
        c.iterationBudget = 2.5
        #expect(c.iterations == 3 && c.iterationBudget == 2.5)
        c.iterations = 7
        #expect(c.iterations == 7 && c.iterationBudget == 7)
        c.iterationBudget = 0.1
        #expect(c.iterations == 1)
    }
    @Test func fractionalLegacyCPUCoolingMatchesOriginalDoubleBudget() async throws {
        let expected = graph(), actual = graph(), rounded = graph()
        let reference = OrganicLayoutAlgorithm(quality: .legacy)
        reference.iterations = 2.5; reference.initialTemperature = 20
        try reference.applyLayout(expected)
        reference.iterations = 3; try reference.applyLayout(rounded)
        let operation = OrganicLayoutOperation(backend: .cpu, configuration: legacyConfiguration(2.5))
        try await operation.applyLayoutAsync(actual)
        #expect(expected.nodes.map(\.center) == actual.nodes.map(\.center))
        #expect(zip(actual.nodes, rounded.nodes).contains { ($0.center - $1.center).length > 0.1 })
        #expect(operation.lastMetrics?.iterations == 3)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: [4, 64])
    func fractionalLegacyMetalCoolingCoversExactAndBarnesHutBranches(_ count: Int) async throws {
        let expected = graph(count), actual = graph(count), executor = LayoutExecutor()
        let reference = OrganicLayoutAlgorithm(quality: .legacy)
        reference.iterations = 2.5; reference.initialTemperature = 20
        try reference.applyLayout(expected)
        let operation = OrganicLayoutOperation(backend: .metal, executor: executor, configuration: legacyConfiguration(2.5))
        try await operation.applyLayoutAsync(actual)
        for (x, y) in zip(expected.nodes, actual.nodes) { #expect((x.center - y.center).length < 0.01) }
        #expect(operation.lastMetrics?.backend == .metal && operation.lastMetrics?.iterations == 3)
        let statistics = await executor.statistics()
        #expect(statistics.submittedBatches > 0 && statistics.submittedBatches == statistics.completedBatches)
    }
    @Test func qualityModeRetainsRoundedCPUReferenceBudget() async throws {
        let expected = graph(), actual = graph(), reference = OrganicLayoutAlgorithm()
        reference.iterations = 2.5; try reference.applyLayout(expected)
        var c = OrganicLayoutConfiguration(); c.iterationBudget = 2.5
        let operation = OrganicLayoutOperation(backend: .cpu, configuration: c)
        try await operation.applyLayoutAsync(actual)
        #expect(expected.nodes.map(\.bounds) == actual.nodes.map(\.bounds))
        #expect(operation.lastMetrics?.iterations == 3)
    }
    @Test(arguments: [Float.nan, .infinity, -0.5])
    func invalidFractionalBudgetsRejectBeforeMutation(_ budget: Float) async throws {
        let graph = graph(), before = graph.nodes.map(\.bounds)
        let operation = OrganicLayoutOperation(backend: .cpu, configuration: legacyConfiguration(budget))
        await #expect(throws: LayoutExecutionError.self) { try await operation.applyLayoutAsync(graph) }
        #expect(graph.nodes.map(\.bounds) == before && operation.lastMetrics == nil)
    }
    @Test(arguments: [LayoutBackend.cpu, .automatic])
    func unusedSparsePartitionAssignmentsRemainValidCPUInputs(_ backend: LayoutBackend) async throws {
        let expected = graph(), actual = graph(), reference = PartitionGridLayoutAlgorithm()
        reference.cellAssignment = ["0": (0, 0), "unused": (1_000_001, 0)]
        reference.defaultColumnWidth = 72; reference.defaultRowHeight = 31; reference.cellPadding = 4
        try reference.applyLayout(expected)
        let operation = BasicLayoutOperation(style: .partitionGrid, backend: backend)
        operation.configuration.cellAssignment = ["0": GridCell(row: 0, column: 0), "unused": GridCell(row: 1_000_001, column: 0)]
        operation.configuration.defaultColumnWidth = 72; operation.configuration.defaultRowHeight = 31; operation.configuration.cellPadding = 4
        try await operation.applyLayoutAsync(actual)
        #expect(actual.nodes.map(\.bounds) == expected.nodes.map(\.bounds))
        #expect(actual.edges.map(\.path) == expected.edges.map(\.path))
    }
    @Test func hierarchyRetainsLegacyClampAndFiniteNegativeSpacing() async throws {
        for backend in [LayoutBackend.cpu, .automatic] + (LayoutExecutor.isMetalAvailable ? [.metal] : []) {
            let expected = graph(), actual = graph(), reference = HierarchicalLayoutAlgorithm()
            reference.maxNodesPerRank = 0; reference.layerSeparation = -2; reference.nodeSeparation = -1
            try reference.applyLayout(expected)
            var c = HierarchicalLayoutConfiguration()
            c.maxNodesPerRank = 0; c.layerSeparation = -2; c.nodeSeparation = -1
            let operation = HierarchicalLayoutOperation(backend: backend, configuration: c)
            try await operation.applyLayoutAsync(actual)
            for (x, y) in zip(actual.nodes, expected.nodes) { #expect((x.center - y.center).length < 0.001) }
        }
    }
    @Test func directedRetainsLegacyFiniteConfigurationDomain() async throws {
        for backend in [LayoutBackend.cpu, .automatic] + (LayoutExecutor.isMetalAvailable ? [.metal] : []) {
            let expected = graph(), actual = graph()
            var c = DirectedLayoutConfiguration()
            c.canvasAspectRatio = 0; c.nodeSpacing = -1; c.layerSpacing = -1
            c.componentSpacing = -1; c.portSpacing = -1; c.clearance = -1; c.edgeWidths = [-1]
            try DirectedLayoutOperation(configuration: c).apply(expected)
            let operation = DirectedLayoutAsyncOperation(backend: backend, configuration: c)
            try await operation.applyLayoutAsync(actual)
            for (x, y) in zip(actual.nodes, expected.nodes) { #expect((x.center - y.center).length < 0.001) }
            #expect(actual.edges.map(\.path) == expected.edges.map(\.path))
        }
    }
    @Test func routingValidatesOnlyConsumedConfiguration() throws {
        var c = RoutingConfiguration(.endpointClipping)
        c.padding = .nan; c.gridSize = 0; c.bendPenalty = .nan; c.curveIterations = -1; c.labelIterations = -1
        try c.validate()
        c = RoutingConfiguration(.channel)
        c.gridSize = 2_000_000; c.bendPenalty = 2_000_000; c.congestionPenalty = 2_000_000
        try c.validate()
        c = RoutingConfiguration(.labelLayout); c.labelIterations = 1_000_001; try c.validate()
        var rank = PageRankConfiguration(); rank.iterations = 1_000_001; try rank.validate()
    }
    @Test func routingLargeAbsoluteCoordinatesRetainCPUAndAutomatic() async throws {
        for backend in [LayoutBackend.cpu, .automatic] {
            let expected = graph(2), actual = graph(2)
            for g in [expected, actual] {
                for (i, node) in g.nodes.enumerated() {
                    node.bounds = Rect(x: 1e12 + Float(i) * 100_000_000, y: 1e12, width: 10_000_000, height: 10_000_000)
                }
                g.edges[0].path = [g.nodes[0].center, g.nodes[1].center]
            }
            EdgeEndpointClipper.clipToNodeBounds(expected)
            let operation = RoutingLayoutOperation(.endpointClipping, backend: backend) { $0.minimumMetalEdgeCount = 0 }
            try await operation.applyLayoutAsync(actual)
            #expect(actual.nodes.map(\.bounds) == expected.nodes.map(\.bounds))
            #expect(actual.edges.map(\.path) == expected.edges.map(\.path))
        }
    }
    @Test func largeChannelConfigurationMatchesCPUReference() async throws {
        for backend in [LayoutBackend.cpu, .automatic] + (LayoutExecutor.isMetalAvailable ? [.metal] : []) {
            let expected = graph(), actual = graph(), reference = ChannelEdgeRouter()
            reference.gridSize = 2_000_000; reference.bendPenalty = 2_000_000; reference.congestionPenalty = 2_000_000
            reference.routeEdges(expected)
            let operation = RoutingLayoutOperation(.channel, backend: backend) {
                $0.gridSize = 2_000_000; $0.bendPenalty = 2_000_000; $0.congestionPenalty = 2_000_000
            }
            try await operation.applyLayoutAsync(actual)
            #expect(actual.edges.map(\.path) == expected.edges.map(\.path))
        }
    }
    @Test func compositionReportsCallerSuppliedCPUCore() async throws {
        let operation = ComponentLayoutOperation(TreeLayoutAlgorithm(), backend: .metal)
        try await operation.applyLayoutAsync(graph())
        #expect(operation.lastExecutionMetrics.contains { $0.backend == .cpu && $0.cpuStages.contains("caller-supplied CPU core layout") })
    }

}
