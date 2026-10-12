import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

@Suite struct GraphQualityTests {
    private func measured(_ graph: LayoutGraph, contracts: VisualContracts = .init()) -> VisualMetrics {
        let item = VisualCase(id: "quality", family: "test", title: "Quality", contracts: contracts) { VisualDrawing(graph: graph) }
        return VisualGeometry.measure(VisualSnapshot(case: item, drawing: VisualDrawing(graph: graph)))
    }

    @Test func radialLayoutsSeparateLargeNodesAndRemainDeterministic() throws {
        for algorithm in [RadialLayoutAlgorithm(), RadialTreeLayoutAlgorithm(), RadialStarLayoutAlgorithm()] as [any LayoutAlgorithm] {
            let g = VisualGraphs.graph(35, shape: "tree")
            for (i, n) in g.nodes.enumerated() { n.width = 180 + Double(i % 4) * 120; n.height = 70 + Double(i % 3) * 50 }
            try algorithm.applyLayout(g)
            let metrics = measured(g, contracts: .init(noNodeOverlaps: true, noObstacleIntersections: true))
            #expect(metrics.failures.isEmpty)
            let bounds = g.nodes.map(\.bounds), paths = g.edges.map(\.path)
            try algorithm.applyLayout(g)
            #expect(g.nodes.map(\.bounds) == bounds)
            #expect(g.edges.map(\.path) == paths)
        }
        let zeroStep = RadialTreeLayoutAlgorithm(); zeroStep.layerDistance = 0
        let g = VisualGraphs.graph(60, shape: "tree")
        try zeroStep.applyLayout(g)
        #expect(measured(g).values["nodeOverlaps"] == 0)
    }

    @Test func obstacleAwarePolylineRepairsMultipleObstaclesAndDiagnosesFailures() {
        let g = LayoutGraph()
        for (id, bounds) in [("s", Rect(x: 0, y: 0, width: 40, height: 40)),
                             ("t", Rect(x: 500, y: 0, width: 40, height: 40)),
                             ("a", Rect(x: 130, y: -20, width: 100, height: 80)),
                             ("b", Rect(x: 300, y: -80, width: 120, height: 120))] {
            let n = LayoutNode(id: id, width: bounds.width, height: bounds.height); n.bounds = bounds; g.addNode(n)
        }
        let edge = LayoutEdge(source: g.nodes[0], target: g.nodes[1]); g.addEdge(edge)
        let loop = LayoutEdge(source: g.nodes[0], target: g.nodes[0]); g.addEdge(loop)
        SelfLoopRouter().routeEdges(g); let loopPath = loop.path
        let router = PolylineEdgeRouter()
        #expect(!router.avoidAllObstacles)
        router.avoidAllObstacles = true; router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty)
        #expect(measured(g).values["edgeNodeIntersections"] == 0)
        #expect(loop.path == loopPath)
        let first = edge.path; router.routeEdges(g); #expect(edge.path == first)
        let group = LayoutNode(id: "ancestor", width: 700, height: 400); group.isGroup = true
        group.x = -100; group.y = -100; g.nodes[0].parent = group; group.children = [g.nodes[0]]; g.addNode(group)
        router.routeEdges(g); #expect(edge.path == first)
        g.nodes[2].bounds = Rect(x: -10, y: -10, width: 100, height: 100)
        router.routeEdges(g)
        #expect(edge.path.isEmpty && router.unroutableEdges == [edge])
        router.avoidAllObstacles = false; router.routeEdges(g)
        #expect(!edge.path.isEmpty && router.unroutableEdges.isEmpty)
    }

    @Test func cancelledObstacleRoutingPreservesInput() async {
        let result = await Task { () -> Bool in
            let g = VisualGraphs.obstacle(), paths = g.edges.map(\.path)
            let router = PolylineEdgeRouter(); router.avoidAllObstacles = true
            withUnsafeCurrentTask { $0?.cancel() }
            router.routeEdges(g)
            return g.edges.map(\.path) == paths
        }.value
        #expect(result)
    }

    @Test func subgraphMovesRigidlyAndPreservesUntouchedGeometry() throws {
        let legacy = VisualGraphs.graph(), current = VisualGraphs.graph()
        VisualGraphs.finish(legacy, route: true); VisualGraphs.finish(current, route: true)
        let untouched = current.nodes.dropFirst(6).map(\.bounds)
        let unrelated = current.edges.filter { Int($0.source.id.dropFirst())! >= 6 && Int($0.target.id.dropFirst())! >= 6 }
        let oldPaths = unrelated.map(\.path)
        let old = SubgraphLayoutAlgorithm(CircularLayoutAlgorithm()); old.selectedNodeIds = Set((0..<6).map { "n\($0)" }); old.avoidUnselectedNodes = false
        try old.applyLayout(legacy)
        let new = SubgraphLayoutAlgorithm(CircularLayoutAlgorithm()); new.selectedNodeIds = old.selectedNodeIds
        try new.applyLayout(current)
        #expect(current.nodes.dropFirst(6).map(\.bounds) == untouched)
        #expect(unrelated.map(\.path) == oldPaths)
        let delta = current.nodes[0].center - legacy.nodes[0].center
        #expect(delta.length > 0)
        for i in 0..<6 { #expect((current.nodes[i].center - legacy.nodes[i].center - delta).length < 1e-8) }
        #expect(measured(current).values["nodeOverlaps"] == 0)
        #expect(measured(legacy).values["nodeOverlaps"]! > 0)
    }

    @Test func labelCollisionsAreMeasuredAndReportedWithoutGeometryChanges() throws {
        let g = VisualGraphs.graph(3); VisualGraphs.finish(g, route: true)
        for edge in g.edges { edge.data = "label"; edge.labelBounds = Rect(x: 0, y: 500, width: 80, height: 20) }
        let item = VisualCase(id: "labels", family: "test", title: "Labels", contracts: .init(noLabelOverlaps: true)) { VisualDrawing(graph: g) }
        let snapshot = VisualSnapshot(case: item, drawing: VisualDrawing(graph: g)), metrics = VisualGeometry.measure(snapshot)
        #expect(metrics.values["labelLabelOverlaps"] == 1)
        #expect(metrics.failures.contains { $0.kind == "label-label-overlap" && $0.elements == ["e0", "e1"] })
        let row = VisualResult(id: "labels", family: "test", title: "Labels", status: "unchanged", metrics: metrics)
        let manifest = VisualManifest(kind: "test", command: [], environment: [:], cases: [row])
        #expect(VisualGallery.report(manifest).contains("label-label-overlap: 1"))
        #expect(VisualGallery.html(manifest).contains("Current findings: label-label-overlap: 1"))
        var clear = snapshot; clear.edges[1].labelBounds.x += 200
        #expect(VisualComparison.compare(clear, snapshot).qualityFlags.contains("labelLabelOverlaps"))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.contracts)) as? [String: Any])
        json.removeValue(forKey: "noLabelOverlaps")
        let oldContract = try JSONDecoder().decode(VisualContracts.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!oldContract.noLabelOverlaps)
    }

    @Test func labelsOnBentRoutesKeepSizesAndAvoidEachOther() throws {
        let g = VisualGraphs.graph(6)
        try HierarchicalLayoutAlgorithm().applyLayout(g); VisualGraphs.finish(g)
        for e in g.edges { e.data = "label"; e.labelBounds = Rect(width: 104, height: 22) }
        LabelLayoutAlgorithm().applyLabelLayout(g)
        #expect(measured(g, contracts: .init(noLabelOverlaps: true)).failures.isEmpty)
        #expect(g.edges.allSatisfy { $0.labelBounds.size == Size(width: 104, height: 22) })
        let positions = g.edges.map(\.labelBounds)
        LabelLayoutAlgorithm().applyLabelLayout(g)
        #expect(g.edges.map(\.labelBounds) == positions)
        // A label larger than the available route space must remain measurable, not be shrunk or hidden.
        let crowded = VisualGraphs.graph(2)
        crowded.edges[0].data = "huge"; crowded.edges[0].path = [Point(x: 0, y: 0), Point(x: 1, y: 0)]
        crowded.edges[0].labelBounds = Rect(width: 500, height: 500)
        crowded.nodes[0].bounds = Rect(x: -5000, y: -5000, width: 10000, height: 10000)
        LabelLayoutAlgorithm().applyLabelLayout(crowded)
        #expect(crowded.edges[0].labelBounds.size == Size(width: 500, height: 500))
        #expect(crowded.edges[0].labelBounds.x.isFinite)
        #expect(!measured(crowded, contracts: .init(noLabelOverlaps: true)).failures.isEmpty)
    }
}
