import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

@Suite struct OrganicQualityTests {
    @Test func legacyGeometryRemainsExact() async throws {
        for fixture in try OrganicLegacyFixture.load() {
            let g = VisualGraphs.graph(fixture.count, shape: fixture.shape)
            let a = OrganicLayoutAlgorithm(quality: .legacy); a.iterations = Double(fixture.iterations)
            try a.applyLayout(g)
            for (actual, expected) in zip(g.nodes.map(\.bounds), fixture.bounds) {
                #expect(abs(actual.x - expected.x) < 1e-7 && abs(actual.y - expected.y) < 1e-7)
                #expect(actual.size == expected.size)
            }
            let other = VisualGraphs.graph(fixture.count, shape: fixture.shape)
            var c = OrganicLayoutConfiguration(quality: .legacy); c.iterations = fixture.iterations
            try await OrganicLayoutOperation(backend: .cpu, configuration: c).applyLayoutAsync(other)
            #expect(g.nodes.map(\.bounds) == other.nodes.map(\.bounds))
            #expect(a.lastDiagnostics == nil)
        }
    }

    @Test(arguments: [0, 1, 12, 63, 64, 65])
    func qualityIsDeterministicAndPreservesGraph(_ count: Int) async throws {
        let g = VisualGraphs.graph(count, shape: "dense"), other = VisualGraphs.graph(count, shape: "dense")
        for graph in [g, other] { for n in graph.nodes { n.x = 0; n.y = 0; n.data = n.id } }
        let original = g.nodes.map(\.bounds.size), parents = g.nodes.map(\.parent)
        let paths = g.edges.map(\.path)
        let a = OrganicLayoutAlgorithm(); a.iterations = 12
        try a.applyLayout(g)
        var c = OrganicLayoutConfiguration(); c.iterations = 12
        let op = OrganicLayoutOperation(backend: .cpu, configuration: c)
        try await op.applyLayoutAsync(other)
        #expect(g.nodes.map(\.bounds) == other.nodes.map(\.bounds))
        #expect(a.lastDiagnostics?.final == op.lastDiagnostics?.final)
        #expect(a.lastDiagnostics?.final.clearanceViolations == 0)
        #expect(g.nodes.map(\.bounds.size) == original && g.nodes.map(\.parent) == parents)
        #expect(g.nodes.allSatisfy { $0.data as? String == $0.id })
        #expect(g.edges.map(\.path) == paths)
        #expect(a.lastDiagnostics?.candidateCount == (count == 0 ? 1 : 13))
    }

    @Test func pinsSubsetAndImpossibleConflictsAreExplicit() throws {
        let g = VisualGraphs.graph(8)
        for n in g.nodes { n.center = Point(x: 1.123456789, y: -9.987654321) }
        for n in g.nodes.suffix(6) { n.metadata[GraphMetadataKeys.layoutSubset] = true }
        let before = g.nodes.map(\.bounds)
        let a = OrganicLayoutAlgorithm(); a.scope = .subset; a.initialization = .current; a.iterations = 8
        try a.applyLayout(g)
        #expect(g.nodes[0].bounds == before[0] && g.nodes[1].bounds == before[1])
        #expect(a.lastDiagnostics?.fixedConflicts == [[0, 1]])
        #expect(a.lastDiagnostics?.final.clearanceViolations == 1)
        #expect(a.lastDiagnostics?.candidateCount == 4)
        let after = g.nodes.map(\.bounds)
        a.iterations = 0; try a.applyLayout(g)
        #expect(g.nodes.map(\.bounds) == after)
        #expect(a.lastDiagnostics?.solverIterations == 0)
    }

    @Test func disconnectedComponentsRespectAnchors() throws {
        let g = VisualGraphs.graph(24, shape: "disconnected")
        g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
        let pin = g.nodes[0].bounds
        let a = OrganicLayoutAlgorithm(); a.iterations = 15
        try a.applyLayout(g)
        #expect(g.nodes[0].bounds == pin)
        #expect(a.lastDiagnostics?.final.clearanceViolations == 0)
        #expect(a.lastDiagnostics?.final.drawingArea.isFinite == true)
    }

    @Test func invalidConfigurationAndCancellationDoNotWrite() async throws {
        let g = VisualGraphs.graph(), before = g.nodes.map(\.bounds)
        let a = OrganicLayoutAlgorithm(); a.repulsionForce = .infinity
        #expect(throws: LayoutExecutionError.self) { try a.applyLayout(g) }
        #expect(g.nodes.map(\.bounds) == before)
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try OrganicLayoutAlgorithm().applyLayout(g); return false }
            catch is CancellationError { return g.nodes.map(\.bounds) == before }
        }
        #expect(try await task.value)
    }

    @Test func cancellationDuringSearchLeavesInputUntouched() async throws {
        let task = Task.detached { () throws -> Bool in
            let g = VisualGraphs.graph(512, shape: "dense"), before = g.nodes.map(\.bounds)
            let a = OrganicLayoutAlgorithm(); a.iterations = 10_000
            do { try a.applyLayout(g); return false }
            catch is CancellationError { return g.nodes.map(\.bounds) == before && a.lastDiagnostics == nil }
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        #expect(try await task.value)
    }

    @Test func sizeNormalizationIsPinAware() throws {
        let g = VisualGraphs.graph(8, shape: "chain")
        let c = OrganicLayoutConfiguration(), snapshot = try GraphCheckpoint(g).snapshot
        var search = try OrganicQualitySearch(snapshot, c)
        let huge = g.nodes.map { $0.center * 100 }
        try search.consider(huge)
        #expect(search.diagnostics.final.clearanceViolations == 0)
        #expect(search.diagnostics.final.drawingArea < 1_000_000)
        #expect(search.diagnostics.final.edgeLength < 10_000)
    }

    @Test func qualityMetricsSeparatePlacementFromRouting() async throws {
        let item = try #require(VisualCatalogue.organicQualityCases().first { $0.id == "organic-quality-chain" })
        let drawing = try await item.run(), snapshot = VisualSnapshot(case: item, drawing: drawing)
        let metrics = VisualGeometry.measure(snapshot)
        #expect(metrics.failures.isEmpty)
        #expect(metrics.values["reported.placement.edgeLength"] != nil)
        #expect(metrics.values["medianEdgeLength", default: 0] > 0)
        #expect(metrics.values["p95EdgeLength", default: 0] >= metrics.values["medianEdgeLength", default: 0])
        #expect(metrics.values["nodeAreaUtilization", default: 0] > 0)
    }

    @Test(arguments: [64, 256])
    func defaultQualityMeetsLargeGraphAcceptance(_ count: Int) async throws {
        let item = try #require(VisualCatalogue.organicQualityCases().first { $0.id == "organic-quality-\(count)" })
        let result = try await item.run()
        let current = VisualGeometry.measure(VisualSnapshot(case: item, drawing: result))
        let legacy = VisualGraphs.graph(count, shape: "dense"), a = OrganicLayoutAlgorithm(quality: .legacy)
        a.iterations = 40; try a.applyLayout(legacy); VisualGraphs.finish(legacy, route: true)
        let previous = VisualGeometry.measure(VisualSnapshot(case: item, drawing: VisualDrawing(graph: legacy)))
        let c = current.values, p = previous.values
        #expect(current.failures.isEmpty)
        #expect(c["routeLength", default: .infinity] <= p["routeLength", default: 0] * 0.5)
        #expect(c["crossings", default: .infinity] <= p["crossings", default: 0] * 0.8)
        #expect(c["drawingWidth", default: .infinity] * c["drawingHeight", default: .infinity] <= p["drawingWidth", default: 0] * p["drawingHeight", default: 0] * 0.85)
        #expect(c["edgeNodeIntersections", default: .infinity] <= p["edgeNodeIntersections", default: 0])
        #expect(c["reported.selectedCandidate", default: 0] > 0)
    }

    @Test func selfLoopsAvoidNeighborsAndStayVisibleWhenBlocked() {
        let g = VisualGraphs.graph(2)
        g.edges = []
        g.nodes[0].bounds = Rect(x: 0, y: 100, width: 80, height: 32)
        g.nodes[1].bounds = Rect(x: 0, y: 20, width: 100, height: 60)
        let loop = LayoutEdge(source: g.nodes[0], target: g.nodes[0]); g.addEdge(loop)
        let router = SelfLoopRouter(); router.routeEdges(g)
        #expect(ObstaclePolyline.clear(loop.path, [g.nodes[1].bounds]) && router.unroutableEdges.isEmpty)
        // Fully enclosed by a neighbour: the loop is still drawn, and reported.
        g.nodes[1].bounds = g.nodes[0].bounds.inflated(by: 100)
        router.routeEdges(g)
        #expect(loop.path.count == 5 && router.unroutableEdges == [loop])
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func metalDefaultQualityCatalogueIsRepeatableAndClear() async throws {
        for item in VisualCatalogue.organicQualityCases(metal: true) {
            let first = try await item.run(), second = try await item.run()
            let a = VisualSnapshot(case: item, drawing: first), b = VisualSnapshot(case: item, drawing: second)
            try VisualStorage.validate(a)
            #expect(a == b, "\(item.id): nondeterministic output")
            #expect(VisualGeometry.measure(a).failures.isEmpty, "\(item.id): \(VisualGeometry.measure(a).failures)")
            #expect(first.reportedMetrics["candidates"] == 13)
            #expect(first.reportedMetrics["solverIterations"] == 7_200)
        }
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func metalQualityPreservesPinsAndClearance() async throws {
        let g = VisualGraphs.graph(64, shape: "dense")
        g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
        let pin = g.nodes[0].bounds
        var c = OrganicLayoutConfiguration(); c.iterations = 20
        let op = OrganicLayoutOperation(backend: .metal, configuration: c)
        try await op.applyLayoutAsync(g)
        #expect(g.nodes[0].bounds == pin)
        #expect(op.lastMetrics?.backend == .metal)
        #expect(op.lastDiagnostics?.candidateCount == 13)
        #expect(op.lastDiagnostics?.final.clearanceViolations == 0)
    }
}
