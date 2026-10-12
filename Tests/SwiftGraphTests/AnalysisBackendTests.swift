import Foundation
import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct AnalysisBackendTests {
    private func graph(_ variant: Int = 0) -> LayoutGraph {
        let graph = LayoutGraph()
        for i in 0..<9 {
            let node = LayoutNode(id: "n\(i)", width: 20, height: 10)
            node.center = Point(x: Double(i * 30), y: Double(i % 3 * 20))
            node.metadata["caller"] = "preserved"; graph.addNode(node)
        }
        let pairs = variant == 0 ? [(0, 1), (1, 2), (2, 0), (2, 3), (3, 3), (0, 1), (4, 5), (5, 4), (6, 6)] : [(0, 1), (1, 0), (0, 2), (2, 0), (3, 4), (4, 3), (3, 5), (5, 3), (6, 7), (7, 6), (6, 8), (8, 6)]
        for pair in pairs {
            let edge = LayoutEdge(source: graph.nodes[pair.0], target: graph.nodes[pair.1])
            edge.path = [edge.source.center, edge.target.center]; edge.labelBounds = Rect(x: 5, y: 6, width: 30, height: 10); graph.addEdge(edge)
        }
        return graph
    }
    private func ranks(_ graph: LayoutGraph) -> [Double] { graph.nodes.map { $0.metadata[GraphMetadataKeys.pageRank] as! Double } }
    private func labels(_ graph: LayoutGraph) -> [Int] { graph.nodes.map { $0.metadata[GraphMetadataKeys.cluster] as! Int } }
    private func rankOrder(_ values: [Double]) -> [Int] { values.indices.sorted { values[$0] == values[$1] ? $0 < $1 : values[$0] > values[$1] } }
    @Test(arguments: [AnalysisKind.pageRank, .clusters])
    func asyncCPUAnalysisMatchesReferenceAndOnlyCommitsMetadata(_ kind: AnalysisKind) async throws {
        let a = graph(), b = graph(), operation = AnalysisLayoutOperation(kind, backend: .cpu)
        let bounds = a.nodes.map(\.bounds), paths = a.edges.map(\.path), labelBounds = a.edges.map(\.labelBounds)
        if kind == .pageRank { try PageRankAlgorithm().applyLayout(b) } else { try LabelPropagationClusteringAlgorithm().applyLayout(b) }
        try await operation.applyLayoutAsync(a)
        if kind == .pageRank { #expect(ranks(a) == ranks(b)) } else { #expect(labels(a) == labels(b)) }
        #expect(a.nodes.map(\.bounds) == bounds && a.edges.map(\.path) == paths && a.edges.map(\.labelBounds) == labelBounds)
        #expect(a.nodes.allSatisfy { $0.metadata["caller"] as? String == "preserved" })
        #expect(operation.lastMetrics?.backend == .cpu && operation.lastMetrics?.metalStages.isEmpty == true)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: [0, 1])
    func metalPageRankPreservesDanglingSelfLinksDuplicatesMassAndHubOrdering(_ variant: Int) async throws {
        let a = graph(variant), b = graph(variant), executor = LayoutExecutor()
        let operation = AnalysisLayoutOperation(.pageRank, backend: .metal, executor: executor)
        try PageRankAlgorithm().applyLayout(a); try await operation.applyLayoutAsync(b)
        let x = ranks(a), y = ranks(b)
        for (p, q) in zip(x, y) { #expect(abs(p - q) <= operation.pageRank.maximumRankError) }
        #expect(abs(y.reduce(0, +) - 1) < 1e-10)
        #expect(rankOrder(x) == rankOrder(y))
        #expect(operation.lastMetrics?.backend == .metal && operation.lastMetrics?.metalStages.isEmpty == false)
        if variant == 1 { #expect(operation.lastMetrics?.cpuStages.contains("exact Double PageRank refinement for ambiguous rank ordering") == true) }
        let stats = await executor.statistics()
        #expect(stats.submittedBatches > 0 && stats.submittedBatches == stats.completedBatches)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: [1, 2])
    func tinyPageRankGraphsAcceptDefaultPrecisionAndKeepSelfLinks(_ count: Int) async throws {
        let a = LayoutGraph(), b = LayoutGraph()
        for graph in [a, b] {
            for i in 0..<count { graph.addNode(LayoutNode(id: String(i), width: 10, height: 10)) }
            for _ in 0..<3 { graph.addEdge(LayoutEdge(source: graph.nodes[0], target: graph.nodes[0])) }
            if count == 2 { graph.addEdge(LayoutEdge(source: graph.nodes[0], target: graph.nodes[1])) }
        }
        try PageRankAlgorithm().applyLayout(a)
        let operation = AnalysisLayoutOperation(.pageRank, backend: .metal)
        try await operation.applyLayoutAsync(b)
        for (x, y) in zip(ranks(a), ranks(b)) { #expect(abs(x - y) < 1e-10) }
        #expect(operation.lastMetrics?.backend == .metal)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: [0.0, 1e-12, 0.85, 1.0])
    func pageRankNearTiesAndDampingEndpoints(_ damping: Double) async throws {
        let a = graph(), b = graph(), reference = PageRankAlgorithm()
        reference.dampingFactor = damping; try reference.applyLayout(a)
        var configuration = PageRankConfiguration(); configuration.dampingFactor = damping
        let operation = AnalysisLayoutOperation(.pageRank, backend: .metal, pageRank: configuration)
        try await operation.applyLayoutAsync(b)
        #expect(rankOrder(ranks(a)) == rankOrder(ranks(b)))
        for (x, y) in zip(ranks(a), ranks(b)) { #expect(abs(x - y) < 1e-10) }
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: [0, 1])
    func orderedMetalClusterVotesExactlyMatchSeededInPlaceCPU(_ variant: Int) async throws {
        let a = graph(variant), b = graph(variant)
        try LabelPropagationClusteringAlgorithm().applyLayout(a)
        let operation = AnalysisLayoutOperation(.clusters, backend: .metal)
        try await operation.applyLayoutAsync(b)
        #expect(labels(a) == labels(b))
        #expect(operation.lastMetrics?.metalStages == ["ordered in-place cluster voting and label updates"])
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func orderedVotesKeepTheInPlaceChainResultRatherThanSnapshotOscillation() async throws {
        let graph = LayoutGraph()
        for i in 0..<3 { graph.addNode(LayoutNode(id: String(i), width: 10, height: 10)) }
        graph.addEdge(LayoutEdge(source: graph.nodes[0], target: graph.nodes[1]))
        graph.addEdge(LayoutEdge(source: graph.nodes[1], target: graph.nodes[2]))
        try await AnalysisLayoutOperation(.clusters, backend: .metal).applyLayoutAsync(graph)
        #expect(labels(graph) == [1, 1, 1])
    }
    @Test func emptyIsolatedAndZeroIterationInputsKeepReferenceBehavior() async throws {
        let empty = LayoutGraph(), emptyOperation = AnalysisLayoutOperation(.pageRank, backend: .metal, executor: LayoutExecutor(metalEnabled: false))
        try await emptyOperation.applyLayoutAsync(empty)
        #expect(emptyOperation.lastMetrics?.fallbackReason == .noWork)
        let g = graph(); g.edges = []
        let clusters = AnalysisLayoutOperation(.clusters, backend: .metal, executor: LayoutExecutor(metalEnabled: false))
        try await clusters.applyLayoutAsync(g)
        #expect(labels(g) == Array(g.nodes.indices) && clusters.lastMetrics?.fallbackReason == .noWork)
        let rank = AnalysisLayoutOperation(.pageRank, backend: .metal, executor: LayoutExecutor(metalEnabled: false))
        rank.pageRank.iterations = 0
        try await rank.applyLayoutAsync(g)
        #expect(ranks(g) == Array(repeating: 1 / Double(g.nodes.count), count: g.nodes.count))
        #expect(rank.lastMetrics?.fallbackReason == .noWork)
    }
    @Test(arguments: [AnalysisKind.pageRank, .clusters])
    func unavailableAutomaticAndExplicitDeviceFailure(_ kind: AnalysisKind) async throws {
        let a = graph(), b = graph(), executor = LayoutExecutor(metalEnabled: false)
        let operation = AnalysisLayoutOperation(kind, backend: .automatic, executor: executor)
        operation.pageRank.minimumMetalNodeCount = 0; operation.clusters.minimumMetalNodeCount = 0
        try await operation.applyLayoutAsync(a); try await AnalysisLayoutOperation(kind, backend: .cpu).applyLayoutAsync(b)
        if kind == .pageRank { #expect(ranks(a) == ranks(b)) } else { #expect(labels(a) == labels(b)) }
        #expect(operation.lastMetrics?.fallbackReason == .metalUnavailable)
        let explicit = AnalysisLayoutOperation(kind, backend: .metal, executor: executor)
        await #expect(throws: OrganicLayoutError.self) { try await explicit.applyLayoutAsync(graph()) }
        #expect(explicit.lastMetrics == nil)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func tightPageRankToleranceHasExplicitPrecisionFailureOrAutomaticFallback() async throws {
        let executor = LayoutExecutor(), a = graph(), b = graph()
        var configuration = PageRankConfiguration(); configuration.maximumRankError = 1e-20; configuration.minimumMetalNodeCount = 0
        let explicit = AnalysisLayoutOperation(.pageRank, backend: .metal, executor: executor, pageRank: configuration)
        await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(a) }
        #expect(a.nodes.allSatisfy { $0.metadata[GraphMetadataKeys.pageRank] == nil })
        let automatic = AnalysisLayoutOperation(.pageRank, backend: .automatic, executor: executor, pageRank: configuration)
        try await automatic.applyLayoutAsync(a); try PageRankAlgorithm().applyLayout(b)
        #expect(ranks(a) == ranks(b) && automatic.lastMetrics?.fallbackReason == .precisionLimit)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: [false, true])
    func cancelledOrStaleRankJobsDrainAndPreserveCallerMetadata(_ cancel: Bool) async throws {
        let executor = LayoutExecutor(), graph = graph(), operation = AnalysisLayoutOperation(.pageRank, backend: .metal, executor: executor)
        operation.pageRank.iterations = 2_000; operation.pageRank.maximumRankError = 1e-4
        let task = Task { try await operation.applyLayoutAsync(graph) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while await executor.statistics().submittedBatches == 0 {
            if ContinuousClock.now >= deadline { throw LayoutExecutionError.invalidInput("No analysis GPU submission") }
            try await Task.sleep(for: .milliseconds(1))
        }
        if cancel { task.cancel() } else { graph.nodes[0].metadata[GraphMetadataKeys.pageRank] = -123.0 }
        let before = graph.nodes.map { $0.metadata[GraphMetadataKeys.pageRank] as? Double }
        if cancel { await #expect(throws: CancellationError.self) { try await task.value } }
        else { await #expect(throws: LayoutExecutionError.staleGraph) { try await task.value } }
        #expect(graph.nodes.map { $0.metadata[GraphMetadataKeys.pageRank] as? Double } == before)
        #expect(operation.lastMetrics == nil)
        let stats = await executor.statistics()
        #expect(stats.submittedBatches == stats.completedBatches)
    }
    @Test func backendAnalysisBuilderWorksInAComposedPipeline() async throws {
        let graph = graph()
        try await LayoutBuilder.create(graph).analyzePageRank(backend: .cpu).analyzeClusters(backend: .cpu).applyAsync()
        #expect(ranks(graph).count == graph.nodes.count && labels(graph).count == graph.nodes.count)
    }
}
