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
        router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty)
        #expect(measured(g).values["edgeNodeIntersections"] == 0)
        #expect(loop.path == loopPath)
        let first = edge.path; router.routeEdges(g); #expect(edge.path == first)
        let group = LayoutNode(id: "ancestor", width: 700, height: 400); group.isGroup = true
        group.x = -100; group.y = -100; g.nodes[0].parent = group; group.children = [g.nodes[0]]; g.addNode(group)
        router.routeEdges(g); #expect(edge.path == first)
        g.nodes[2].bounds = Rect(x: -10, y: -10, width: 100, height: 100)
        router.routeEdges(g)
        // An impossible route is diagnosed but still drawn as a straight line.
        #expect(edge.path == [g.nodes[0].center, g.nodes[1].center] && router.unroutableEdges == [edge])
    }

    @Test func cancelledObstacleRoutingPreservesInput() async {
        let result = await Task { () -> Bool in
            let g = VisualGraphs.obstacle(), paths = g.edges.map(\.path)
            let router = PolylineEdgeRouter()
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

    @Test func barycenterWithSingleAnchorKeepsNodesApart() throws {
        let g = VisualGraphs.graph()
        g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
        let anchor = g.nodes[0].bounds
        try BarycenterLayoutAlgorithm().applyLayout(g)
        #expect(measured(g).values["nodeOverlaps"] == 0)
        #expect(g.nodes[0].bounds == anchor)
    }

    @Test func overlapRemovalPreservesOrthogonalOrder() throws {
        let g = VisualGraphs.graph()
        for n in g.nodes { n.x *= 0.2; n.y *= 0.2 }
        let before = g.nodes.map(\.center)
        try RemoveOverlapsLayoutAlgorithm().applyLayout(g)
        #expect(measured(g).values["nodeOverlaps"] == 0)
        let after = g.nodes.map(\.center)
        for i in g.nodes.indices { for j in g.nodes.indices where before[i].x < before[j].x { #expect(after[i].x < after[j].x) } }
        for i in g.nodes.indices { for j in g.nodes.indices where before[i].y < before[j].y { #expect(after[i].y < after[j].y) } }
    }

    @Test func overlapRemovalKeepsStackedNodesStacked() throws {
        let g = LayoutGraph()
        for (id, bounds) in [("a", Rect(x: 0, y: 0, width: 100, height: 40)), ("b", Rect(x: 0, y: 30, width: 100, height: 40))] {
            let n = LayoutNode(id: id, width: bounds.width, height: bounds.height); n.bounds = bounds; g.addNode(n)
        }
        try RemoveOverlapsLayoutAlgorithm().applyLayout(g)
        // Stacked nodes stay stacked: a 20pt vertical move beats a 110pt horizontal one.
        #expect(g.nodes[0].x == g.nodes[1].x)
        #expect(g.nodes[1].y - g.nodes[0].bounds.bottom >= 10 - 1e-9)
        #expect(abs(g.nodes[0].y) + abs(g.nodes[1].y - 30) <= 20 + 1e-9)
    }

    @Test func clearAreaDoesNotPushNodesOntoOtherNodes() throws {
        let g = LayoutGraph()
        for (id, bounds) in [("above", Rect(x: 100, y: -80, width: 105, height: 40)), ("inside", Rect(x: 100, y: 70, width: 105, height: 40))] {
            let n = LayoutNode(id: id, width: bounds.width, height: bounds.height); n.bounds = bounds; g.addNode(n)
        }
        let area = Rect(x: 0, y: 0, width: 400, height: 300)
        try ClearAreaLayoutAlgorithm(area).applyLayout(g)
        #expect(!g.nodes[1].bounds.intersects(area))
        #expect(!g.nodes[1].bounds.intersects(g.nodes[0].bounds))
        #expect(g.nodes[0].bounds == Rect(x: 100, y: -80, width: 105, height: 40))
    }

    private func nodes(_ specs: [(String, Rect)]) -> LayoutGraph {
        let g = LayoutGraph()
        for (id, bounds) in specs { let n = LayoutNode(id: id, width: bounds.width, height: bounds.height); n.bounds = bounds; g.addNode(n) }
        return g
    }
    private func edge(_ g: LayoutGraph, _ s: Int, _ t: Int, _ path: [Point]) -> LayoutEdge {
        let e = LayoutEdge(source: g.nodes[s], target: g.nodes[t]); e.path = path; g.addEdge(e); return e
    }

    @Test func separatorSpreadsDuplicateAndReciprocalEdgesIntoLanes() {
        let g = nodes([("a", Rect(x: 0, y: 0, width: 60, height: 40)), ("b", Rect(x: 300, y: 0, width: 60, height: 40))])
        let a = g.nodes[0].center, b = g.nodes[1].center
        let edges = [edge(g, 0, 1, [a, b]), edge(g, 0, 1, [a, b]), edge(g, 1, 0, [b, a])]
        let loop = edge(g, 0, 0, [Point(x: 10, y: 0), Point(x: 30, y: -30), Point(x: 50, y: 0)])
        EdgeSeparator().routeEdges(g)
        #expect(measured(g).values["sharedSegments"] == 0)
        let ys = edges.map { $0.path[0].y }.sorted()
        #expect(ys.count == 3 && abs(ys[1] - ys[0] - 10) < 1e-9 && abs(ys[2] - ys[1] - 10) < 1e-9 && abs(ys[1] - a.y) < 1e-9)
        #expect(edges.allSatisfy { $0.path.count == 2 && abs($0.path[0].y - $0.path[1].y) < 1e-9 })
        #expect(loop.path == [Point(x: 10, y: 0), Point(x: 30, y: -30), Point(x: 50, y: 0)])
    }

    @Test func separatorKeepsOrthogonalRoutesOrthogonalAndUncrossed() {
        // Two routes share a horizontal trunk: one arrives from above and leaves upward, the other below and downward.
        let g = nodes([("s1", Rect(x: -20, y: -20, width: 40, height: 40)), ("s2", Rect(x: -20, y: 80, width: 40, height: 40)),
                       ("up", Rect(x: 280, y: -220, width: 40, height: 40)), ("down", Rect(x: 280, y: 180, width: 40, height: 40))])
        let up = edge(g, 0, 2, [Point(x: 0, y: 0), Point(x: 0, y: 50), Point(x: 300, y: 50), Point(x: 300, y: -200)])
        let down = edge(g, 1, 3, [Point(x: 0, y: 100), Point(x: 0, y: 50), Point(x: 300, y: 50), Point(x: 300, y: 200)])
        EdgeSeparator().routeEdges(g)
        let metrics = measured(g, contracts: .init(orthogonal: true))
        #expect(metrics.failures.isEmpty)
        #expect(metrics.values["sharedSegments"] == 0 && metrics.values["crossings"] == 0)
        // The edge leaving upward takes the upper lane.
        #expect(up.path[1].y < down.path[1].y)
    }

    @Test func separatorNeverPushesRoutesIntoNodesAndLeavesUnsharedPathsAlone() {
        // The shared corridor is only 4pt wide; lanes 10pt apart would cut a wall, so the routes stay put.
        let g = nodes([("s", Rect(x: -20, y: -20, width: 40, height: 40)), ("t", Rect(x: 380, y: -20, width: 40, height: 40)),
                       ("top", Rect(x: 100, y: -100, width: 200, height: 98)), ("bottom", Rect(x: 100, y: 2, width: 200, height: 98)),
                       ("x", Rect(x: 0, y: 300, width: 40, height: 40))])
        let s = g.nodes[0].center, t = g.nodes[1].center
        let first = edge(g, 0, 1, [s, t]), second = edge(g, 0, 1, [s, t])
        let alone = edge(g, 0, 4, [s, g.nodes[4].center])
        EdgeSeparator().routeEdges(g)
        #expect(measured(g).values["edgeNodeIntersections"] == 0)
        #expect(alone.path == [s, g.nodes[4].center])
        #expect(first.path == [s, t] && second.path == [s, t])
    }

    @Test func bspRoutesKeepClearanceFromTheOutermostNodes() {
        // The wall defines the drawing's bottom edge; the legacy frame ran the route along it.
        let g = nodes([("a", Rect(x: 0, y: 100, width: 40, height: 30)), ("wall", Rect(x: 150, y: 0, width: 60, height: 300)),
                       ("b", Rect(x: 400, y: 200, width: 60, height: 30))])
        let e = edge(g, 0, 2, [])
        let router = BspEdgeRouter(); router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty)
        let wall = g.nodes[1].bounds.inflated(by: 10)
        #expect(!zip(e.path, e.path.dropFirst()).contains { wall.intersectsLine($0, $1) })
        #expect(measured(g, contracts: .init(noObstacleIntersections: true, orthogonal: true)).failures.isEmpty)
    }

    @Test func bspAttachesAtSidesAndStraightensAlignedNeighbours() {
        let g = nodes([("top", Rect(x: 0, y: 0, width: 120, height: 40)), ("bottom", Rect(x: 10, y: 140, width: 80, height: 40)),
                       ("right", Rect(x: 300, y: 60, width: 60, height: 40))])
        let down = edge(g, 0, 1, []), across = edge(g, 1, 2, [])
        BspEdgeRouter().routeEdges(g)
        // Overlapping x-ranges allow one straight vertical line instead of a jog.
        #expect(down.path.count == 2 && down.path[0].x == down.path[1].x)
        #expect(down.path[0].y == 40 && down.path[1].y == 140)
        // Ends sit on a side, away from the corners, and the L-shaped route needs only one bend.
        func onSide(_ p: Point, _ r: Rect) -> Bool {
            ((p.x == r.left || p.x == r.right) && p.y > r.top && p.y < r.bottom) || ((p.y == r.top || p.y == r.bottom) && p.x > r.left && p.x < r.right)
        }
        #expect(onSide(across.path[0], g.nodes[1].bounds) && onSide(across.path[across.path.count - 1], g.nodes[2].bounds))
        #expect(across.path.count == 3)
        #expect(measured(g, contracts: .init(noObstacleIntersections: true, orthogonal: true)).failures.isEmpty)
    }

    private func isOrthogonal(_ path: [Point]) -> Bool { zip(path, path.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y } }

    @Test func selfLoopsAreCompactOrthogonalCornerLoops() {
        let g = nodes([("n", Rect(x: 0, y: 0, width: 80, height: 32))])
        let loop = edge(g, 0, 0, [])
        SelfLoopRouter().routeEdges(g)
        let r = g.nodes[0].bounds, path = loop.path
        #expect(path.count == 5 && isOrthogonal(path))
        // Both ends sit on the node's boundary, on adjacent sides, and the loop stays within 16pt of the node.
        func onBoundary(_ p: Point) -> Bool { (p.x == r.left || p.x == r.right) != (p.y == r.top || p.y == r.bottom) }
        #expect(onBoundary(path[0]) && onBoundary(path[4]))
        #expect(path.allSatisfy { r.inflated(by: 16 + 1e-9).contains($0) })
    }

    @Test func selfLoopsPickClearCornersAwayFromAttachedEdges() {
        // A neighbour sits above-right; an edge leaves towards the bottom-right.
        let g = nodes([("n", Rect(x: 0, y: 0, width: 80, height: 32)), ("above", Rect(x: 60, y: -60, width: 80, height: 50)),
                       ("below", Rect(x: 200, y: 200, width: 40, height: 30))])
        let out = edge(g, 0, 2, [g.nodes[0].center, g.nodes[2].center])
        let first = edge(g, 0, 0, []), second = edge(g, 0, 0, [])
        SelfLoopRouter().routeEdges(g)
        let metrics = measured(g)
        #expect(metrics.values["edgeNodeIntersections"] == 0 && metrics.values["crossings"] == 0 && metrics.values["sharedSegments"] == 0)
        // Neither loop takes the blocked top-right corner nor the bottom-right corner the edge leaves through.
        let c = g.nodes[0].center
        for loop in [first, second] {
            let far = loop.path.max { ($0 - c).length < ($1 - c).length }!
            #expect(far.x < c.x)
        }
        #expect(first.path != second.path && out.path.count == 2)
    }

    @Test func verticalStackOrdersNumberedIdsNumerically() throws {
        let g = VisualGraphs.graph()
        try VerticalStackLayoutAlgorithm().applyLayout(g)
        #expect(g.nodes.sorted { $0.y < $1.y }.map(\.id) == (0..<12).map { "n\($0)" })
    }
}
