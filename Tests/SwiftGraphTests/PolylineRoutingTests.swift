import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

@Suite struct PolylineRoutingTests {
    private func measured(_ graph: LayoutGraph) -> VisualMetrics {
        let item = VisualCase(id: "polyline", family: "test", title: "Polyline", contracts: .init()) { VisualDrawing(graph: graph) }
        return VisualGeometry.measure(VisualSnapshot(case: item, drawing: VisualDrawing(graph: graph)))
    }
    private func nodes(_ specs: [(String, Rect)]) -> LayoutGraph {
        let g = LayoutGraph()
        for (id, bounds) in specs { let n = LayoutNode(id: id, width: bounds.width, height: bounds.height); n.bounds = bounds; g.addNode(n) }
        return g
    }
    @discardableResult private func edge(_ g: LayoutGraph, _ s: Int, _ t: Int, _ path: [Point] = []) -> LayoutEdge {
        let e = LayoutEdge(source: g.nodes[s], target: g.nodes[t]); e.path = path; g.addEdge(e); return e
    }
    private func box(_ p: Point, _ size: Float = 10) -> Rect { Rect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size) }
    private func length(_ path: [Point]) -> Float { zip(path, path.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length } }

    @Test func defaultSpacingIsTen() {
        #expect(PolylineEdgeRouter().edgeSpacing == 10 && EdgeSeparator().spacing == 10)
        #expect(RoutingConfiguration(.polyline).edgeSpacing == 10 && RoutingConfiguration(.edgeSeparation).edgeSpacing == 10)
    }

    // MARK: B2 repair

    @Test func repairNeverLeavesAnEmptyPathAndReportsFailures() {
        // The target sits inside a closed ring of walls.
        let g = nodes([("s", Rect(x: 0, y: 0, width: 40, height: 40)), ("t", Rect(x: 400, y: 0, width: 40, height: 40)),
                       ("n", Rect(x: 380, y: -40, width: 80, height: 30)), ("s2", Rect(x: 380, y: 50, width: 80, height: 30)),
                       ("w", Rect(x: 370, y: -40, width: 20, height: 120)), ("e", Rect(x: 450, y: -40, width: 20, height: 120))])
        let blocked = edge(g, 0, 1)
        let failed = ObstaclePolyline.repair(g)
        #expect(blocked.path == [g.nodes[0].center, g.nodes[1].center])
        #expect(failed == [blocked])
        // A failed edge with an existing route keeps it rather than losing it.
        let keep = [Point(x: 20, y: 20), Point(x: 100, y: 300), Point(x: 420, y: 20)]
        blocked.path = keep
        #expect(ObstaclePolyline.repair(g) == [blocked] && blocked.path == keep)
    }

    @Test func repairHonoursPaddingAndSeparatesDetouredEdges() {
        let g = nodes([("s", Rect(x: 0, y: 40, width: 40, height: 40)), ("t", Rect(x: 400, y: 40, width: 40, height: 40)),
                       ("wall", Rect(x: 190, y: -100, width: 20, height: 260))])
        let edges = (0..<3).map { _ in edge(g, 0, 1, [g.nodes[0].center, g.nodes[1].center]) }
        #expect(ObstaclePolyline.repair(g, padding: 30).isEmpty)
        let wall = g.nodes[2].bounds
        for e in edges {
            #expect(e.path.count > 2)
            #expect(zip(e.path, e.path.dropFirst()).allSatisfy { !wall.inflated(by: 14).intersectsLine($0, $1) })
        }
        #expect(measured(g).values["sharedSegments"] == 0 && measured(g).values["nearParallelRuns"] == 0)
    }

    // MARK: B4 clearance

    @Test func straightLinesNeedClearanceButNotFullPadding() {
        func routed(gap: Float) -> LayoutEdge {
            let g = nodes([("s", Rect(x: 0, y: 0, width: 40, height: 40)), ("t", Rect(x: 400, y: 0, width: 40, height: 40)),
                           ("a", Rect(x: 180, y: 20 + gap, width: 60, height: 60))])
            let e = edge(g, 0, 1); PolylineEdgeRouter().routeEdges(g); return e
        }
        // 8 clear of the line: acceptable (half the 10 padding is 5).
        #expect(routed(gap: 8).path.count == 2)
        // 3 clear of the line: a straight line used to pass; now it detours and keeps padding.
        let tight = routed(gap: 3)
        #expect(tight.path.count > 2)
        let a = Rect(x: 180, y: 23, width: 60, height: 60)
        #expect(zip(tight.path, tight.path.dropFirst()).allSatisfy { !a.inflated(by: 9.9).intersectsLine($0, $1) })
    }

    @Test func narrowCorridorsRetryWithSmallerPadding() {
        // Two walls 14 apart: padded by 10 they overlap and seal the corridor.
        let g = nodes([("s", Rect(x: 0, y: 30, width: 40, height: 40)), ("t", Rect(x: 400, y: 230, width: 40, height: 40)),
                       ("top", Rect(x: 190, y: -1000, width: 60, height: 1143)), ("bottom", Rect(x: 190, y: 157, width: 60, height: 1000))])
        let e = edge(g, 0, 1)
        let router = PolylineEdgeRouter(); router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty && e.path.count > 2)
        #expect(measured(g).values["edgeNodeIntersections"] == 0)
    }

    @Test func endpointCentreInsideAnotherNodeStillRoutes() {
        // A group's centre lies inside a child; the edge should leave rather than fail outright.
        let g = nodes([("group", Rect(x: 0, y: 0, width: 200, height: 200)), ("child", Rect(x: 60, y: 60, width: 100, height: 100)),
                       ("t", Rect(x: 500, y: 80, width: 40, height: 40)), ("wall", Rect(x: 300, y: 0, width: 20, height: 200))])
        g.nodes[0].isGroup = true
        let e = edge(g, 0, 2)
        let router = PolylineEdgeRouter(); router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty && e.path.count > 2)
        #expect(e.path.last == g.nodes[2].center)
    }

    // MARK: E2 search

    @Test func windowedSearchMatchesTheFullSearch() {
        var seed: UInt64 = 7
        func next() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Double(seed >> 33) / Double(1 << 31)) }
        let g = LayoutGraph()
        for i in 0..<60 {
            let n = LayoutNode(id: "n\(i)", width: 20 + next() * 40, height: 20 + next() * 40)
            n.x = Float(i % 10) * 110 + next() * 40; n.y = Float(i / 10) * 110 + next() * 40; g.addNode(n)
        }
        for _ in 0..<80 { edge(g, Int(next() * 60) % 60, Int(next() * 60) % 60) }
        let scene = ObstaclePolyline.Scene(g.nodes)
        var checked = 0
        for e in g.edges where e.source !== e.target {
            guard let found = scene.route(e, padding: 10), found.gap == 10 else { continue }
            let full = ObstaclePolyline.search(e.source.center, e.target.center, ObstaclePolyline.obstacles(e, g), padding: 10)
            #expect(full != nil && abs(length(found.path) - length(full!)) < 1e-3)
            checked += 1
        }
        #expect(checked > 40)
    }

    @Test func routingIsDeterministicAndKeepsEveryEdgeClearOnADenseGraph() {
        func run() -> [[Point]] {
            let g = VisualGraphs.graph(120, shape: "dense")
            for (i, n) in g.nodes.enumerated() { n.x = Float(i % 12) * 200; n.y = Float(i / 12) * 130 }
            let router = PolylineEdgeRouter(); router.routeEdges(g)
            #expect(measured(g).values["edgeNodeIntersections"] == 0 || !router.unroutableEdges.isEmpty)
            return g.edges.map(\.path)
        }
        #expect(run() == run())
    }

    // MARK: D1 costs

    @Test func detoursAvoidCrossingRoutesAlreadyLaid() {
        func routed(crossing: Float) -> [Point] {
            let g = nodes([("p", box(Point(x: 300, y: -200))), ("q", box(Point(x: 300, y: -20))),
                           ("a", Rect(x: -20, y: -20, width: 40, height: 40)), ("b", Rect(x: 380, y: -20, width: 40, height: 40)),
                           ("wall", Rect(x: 190, y: -100, width: 20, height: 210))])
            edge(g, 0, 1); let e = edge(g, 2, 3)
            let router = PolylineEdgeRouter(); router.crossingPenalty = crossing; router.edgeSpacing = 0; router.routeEdges(g)
            return e.path
        }
        // The upper way round is a little shorter, but crosses the vertical route.
        #expect(routed(crossing: 0).contains { $0.y < -100 })
        #expect(routed(crossing: 40).contains { $0.y > 100 })
    }

    @Test func edgesFromDifferentDirectionsDoNotBendAtTheSamePaddedCorner() {
        let g = nodes([("a", Rect(x: -20, y: -20, width: 40, height: 40)), ("b", Rect(x: 380, y: -20, width: 40, height: 40)),
                       ("c", Rect(x: -20, y: -80, width: 40, height: 40)), ("d", Rect(x: 380, y: -80, width: 40, height: 40)),
                       ("wall", Rect(x: 190, y: -100, width: 20, height: 210))])
        let first = edge(g, 0, 1), second = edge(g, 2, 3)
        let router = PolylineEdgeRouter(); router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty)
        let shared = Set(first.path.dropFirst().dropLast()).intersection(second.path.dropFirst().dropLast())
        #expect(shared.isEmpty)
        #expect(measured(g).values["edgeNodeIntersections"] == 0)
    }

    // MARK: C3 separator

    @Test func lanesFollowTheCrossingFreeOrder() {
        // e1 < e2 < e3 along a shared trunk, with e3 overlapping only e2. A first-fit lane for e3 would sit above e2.
        let ends = [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 50, y: 100), Point(x: 250, y: 0), Point(x: 200, y: 100), Point(x: 300, y: 100)]
        let g = nodes(ends.enumerated().map { ("n\($0.offset)", box($0.element, 40)) })
        let e1 = edge(g, 0, 1, [ends[0], Point(x: 0, y: 50), Point(x: 100, y: 50), ends[1]])
        let e2 = edge(g, 2, 3, [ends[2], Point(x: 50, y: 50), Point(x: 250, y: 50), ends[3]])
        let e3 = edge(g, 4, 5, [ends[4], Point(x: 200, y: 50), Point(x: 300, y: 50), ends[5]])
        let separator = EdgeSeparator(); separator.routeEdges(g)
        let m = measured(g)
        #expect(m.values["crossings"] == 0 && m.values["sharedSegments"] == 0)
        func trunk(_ e: LayoutEdge) -> Float { e.path[1].y }
        #expect(trunk(e1) < trunk(e2) && trunk(e2) < trunk(e3))
        #expect(separator.unseparatedEdges.isEmpty)
    }

    @Test func nearCollinearRunsAreSeparated() {
        let g = nodes([("a", box(Point(x: 0, y: 0), 40)), ("b", box(Point(x: 300, y: 0), 40)), ("c", box(Point(x: 0, y: 3), 40)), ("d", box(Point(x: 300, y: 4), 40))])
        let first = edge(g, 0, 1, [Point(x: 0, y: 0), Point(x: 300, y: 0)]), second = edge(g, 2, 3, [Point(x: 0, y: 3), Point(x: 300, y: 4)])
        EdgeSeparator().routeEdges(g)
        let gap = abs(second.path[0].y - first.path[0].y), far = abs(second.path[1].y - first.path[1].y)
        #expect(gap > 9 && far > 9)
        #expect(measured(g).values["nearParallelRuns"] == 0)
    }

    @Test func eachStretchOfAnEdgeIsSeparatedFromItsOwnPartner() {
        // `long` shares its y = 40 run with one edge and its y = 140 run with another; both runs separate and it stays orthogonal.
        let g = nodes([("n0", box(Point(x: 0, y: 0), 40)), ("n5", box(Point(x: 500, y: 0), 40)), ("n1", box(Point(x: -50, y: 40), 40)),
                       ("n2", box(Point(x: 150, y: 40), 40)), ("n3", box(Point(x: 250, y: 140), 40)), ("n4", box(Point(x: 450, y: 140), 40))])
        let long = edge(g, 0, 1, [Point(x: 0, y: 0), Point(x: 0, y: 40), Point(x: 200, y: 40), Point(x: 200, y: 140), Point(x: 500, y: 140), Point(x: 500, y: 0)])
        edge(g, 2, 3, [Point(x: -50, y: 40), Point(x: 150, y: 40)])
        edge(g, 4, 5, [Point(x: 250, y: 140), Point(x: 450, y: 140)])
        EdgeSeparator().routeEdges(g)
        #expect(measured(g).values["sharedSegments"] == 0)
        #expect(long.path.count == 6 && long.path[1].y != 40 && long.path[3].y != 140)
        #expect(zip(long.path, long.path.dropFirst()).allSatisfy { abs($0.x - $1.x) < 1e-4 || abs($0.y - $1.y) < 1e-4 })
    }

    @Test func lanesTakeTheOpenSideAndKeepClearanceFromNodes() {
        func lanes(walls: [Rect]) -> (ys: [Float], separator: EdgeSeparator, graph: LayoutGraph) {
            let g = nodes([("s", box(Point(x: 0, y: 0), 40)), ("t", box(Point(x: 400, y: 0), 40))] + walls.enumerated().map { ("wall\($0.offset)", $0.element) })
            let a = edge(g, 0, 1, [Point(x: 0, y: 0), Point(x: 400, y: 0)]), b = edge(g, 0, 1, [Point(x: 0, y: 0), Point(x: 400, y: 0)])
            let separator = EdgeSeparator(); separator.routeEdges(g)
            return ([a.path[0].y, b.path[0].y].sorted(), separator, g)
        }
        // A wall 8 above the trunk: both lanes move to the open side, a full spacing from it where they fit.
        let one = lanes(walls: [Rect(x: 100, y: -108, width: 200, height: 100)])
        #expect(abs(one.ys[1] - one.ys[0] - 10) < 1e-4 && one.ys[0] >= -1e-4 && one.separator.unseparatedEdges.isEmpty)
        // Walls 8 either side: lanes tighten, but keep half a spacing from both.
        let both = lanes(walls: [Rect(x: 100, y: -108, width: 200, height: 100), Rect(x: 100, y: 8, width: 200, height: 100)])
        #expect(abs(both.ys[1] - both.ys[0] - 6) < 1e-4 && both.ys.allSatisfy { 8 - abs($0) >= 5 - 1e-4 })
        #expect(both.separator.unseparatedEdges.isEmpty)
    }

    @Test func edgesThatCannotBeSeparatedAreReported() {
        let g = nodes([("s", Rect(x: -20, y: -20, width: 40, height: 40)), ("t", Rect(x: 380, y: -20, width: 40, height: 40)),
                       ("top", Rect(x: 100, y: -100, width: 200, height: 98)), ("bottom", Rect(x: 100, y: 2, width: 200, height: 98)),
                       ("x", Rect(x: 0, y: 300, width: 40, height: 40))])
        let s = g.nodes[0].center, t = g.nodes[1].center
        let first = edge(g, 0, 1, [s, t]), second = edge(g, 0, 1, [s, t]), alone = edge(g, 0, 4, [s, g.nodes[4].center])
        let separator = EdgeSeparator(); separator.routeEdges(g)
        #expect(separator.unseparatedEdges == [first, second] && !separator.unseparatedEdges.contains(alone))
    }
}
