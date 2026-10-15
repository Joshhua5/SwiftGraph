import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

@Suite struct PortsRoutingTests {
    private func node(_ g: LayoutGraph, _ id: String, _ r: Rect) -> LayoutNode {
        let n = LayoutNode(id: id, width: r.width, height: r.height); n.bounds = r; g.addNode(n); return n
    }
    @discardableResult private func edge(_ g: LayoutGraph, _ a: LayoutNode, _ b: LayoutNode, _ path: [Point]) -> LayoutEdge {
        let e = LayoutEdge(source: a, target: b); e.path = path; g.addEdge(e); return e
    }
    private func onBoundary(_ p: Point, _ r: Rect, tolerance: Float = 1e-4) -> Bool {
        r.inflated(by: tolerance).contains(p) && !r.inflated(by: -tolerance).contains(p)
    }

    // MARK: A1 / E4

    @Test(arguments: LayoutPatternType.allCases)
    func presetsEndWithEndpointsOnNodeBoundaries(_ pattern: LayoutPatternType) async throws {
        let g = VisualGraphs.graph(shape: "cyclic")
        try await LayoutBuilder.create(g).applyPattern(pattern).applyAsync()
        for e in g.edges where e.source !== e.target {
            #expect(e.path.count >= 2, "\(pattern) \(e.source.id)->\(e.target.id)")
            guard let first = e.path.first, let last = e.path.last else { continue }
            // Channel ports sit one unit outside the node.
            #expect(!e.source.bounds.inflated(by: -1e-4).contains(first) && e.source.bounds.inflated(by: 1.5).contains(first), "\(pattern) source of \(e.source.id)->\(e.target.id)")
            #expect(!e.target.bounds.inflated(by: -1e-4).contains(last) && e.target.bounds.inflated(by: 1.5).contains(last), "\(pattern) target of \(e.source.id)->\(e.target.id)")
        }
    }

    @Test func backendPresetsMatchCPUPresetsAfterClippingAndDistribution() async throws {
        for pattern in [LayoutPatternType.standardHierarchical, .enterpriseArchitecture, .callGraph, .organizationChart] {
            let a = VisualGraphs.graph(shape: "dag"), b = VisualGraphs.graph(shape: "dag")
            try await LayoutBuilder.create(a).applyPattern(pattern).applyAsync()
            try await LayoutBuilder.create(b).applyPattern(pattern, backend: .cpu).applyAsync()
            #expect(a.edges.map(\.path) == b.edges.map(\.path), "\(pattern)")
        }
    }

    @Test func clipperUsesLastExitFromSourceAndFirstEntryToTarget() {
        let g = LayoutGraph()
        let a = node(g, "a", Rect(width: 100, height: 100)), b = node(g, "b", Rect(x: 300, y: 0, width: 100, height: 100))
        // Leaves a, comes back through it, then crosses b's body before ending in its centre.
        let e = edge(g, a, b, [Point(x: 50, y: 50), Point(x: 50, y: 150), Point(x: 50, y: 20), Point(x: 150, y: 20), Point(x: 150, y: 150),
                               Point(x: 350, y: 150), Point(x: 350, y: 50), Point(x: 350, y: 20), Point(x: 500, y: 20), Point(x: 350, y: 50)])
        EdgeEndpointClipper.clipToNodeBounds(g)
        #expect(e.path.first == Point(x: 100, y: 20))
        #expect(e.path.last == Point(x: 350, y: 100))
        #expect(e.path.count >= 2)
        let again = e.path; EdgeEndpointClipper.clipToNodeBounds(g); #expect(e.path == again)
    }

    @Test func clipperNeverLeavesFewerThanTwoPoints() {
        let g = LayoutGraph()
        let a = node(g, "a", Rect(width: 100, height: 100)), b = node(g, "b", Rect(x: 50, y: 50, width: 100, height: 100))
        let inside = edge(g, a, b, [Point(x: 60, y: 60), Point(x: 70, y: 70)])
        let touching = edge(g, a, b, [Point(x: 50, y: 50), Point(x: 100, y: 50)])
        EdgeEndpointClipper.clipToNodeBounds(g)
        #expect(inside.path.count >= 2 && touching.path.count >= 2)
    }

    @Test func clipperAbsorbsSamplesThatHugTheBoundary() {
        let g = LayoutGraph()
        let a = node(g, "a", Rect(width: 100, height: 100)), b = node(g, "b", Rect(x: 400, y: 0, width: 100, height: 100))
        let e = edge(g, a, b, [Point(x: 50, y: 50), Point(x: 101, y: 50.2), Point(x: 250, y: 51), Point(x: 450, y: 50)])
        EdgeEndpointClipper.clipToNodeBounds(g)
        #expect(zip(e.path, e.path.dropFirst()).allSatisfy { ($1 - $0).length >= 4 })
    }

    @Test func enterpriseArchitectureFinishesRoutesInsideItsContainerPass() async throws {
        let graph = VisualGraphs.graph()
        try await LayoutBuilder.create(graph).applyEnterpriseArchitecture().applyAsync()
        #expect(graph.edges.allSatisfy { $0.path.count >= 2 })
        #expect(graph.edges.filter { $0.source !== $0.target }.allSatisfy {
            ObstaclePolyline.clear($0.path, ObstaclePolyline.obstacles($0, graph))
        })
    }

    // MARK: B1

    @Test func roundedCornersKeepTheSharpCornerWhenTheArcWouldHitANode() {
        let g = LayoutGraph()
        let a = node(g, "a", Rect(x: -40, y: -10, width: 40, height: 20)), b = node(g, "b", Rect(x: 100, y: 190, width: 40, height: 20))
        // The second corner sits 3 units from a blocker; the first has room.
        _ = node(g, "wall", Rect(x: 107, y: 70, width: 60, height: 12))
        let e = edge(g, a, b, [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 80), Point(x: 120, y: 200)])
        let router = CurveFittingEdgeRouter(); router.routeEdges(g)
        #expect(ObstaclePolyline.clear(e.path, ObstaclePolyline.obstacles(e, g)))
        #expect(e.path.first == Point(x: 0, y: 0) && e.path.last == Point(x: 120, y: 200))
        // The first leg still leaves along the original direction.
        #expect(e.path[1].y == 0)
    }

    @Test func roundedCornersNeverTakeMoreThanHalfASegment() {
        let g = LayoutGraph()
        let a = node(g, "a", Rect(x: -20, y: -20, width: 20, height: 20)), b = node(g, "b", Rect(x: 20, y: 20, width: 20, height: 20))
        let e = edge(g, a, b, [Point(x: 0, y: 0), Point(x: 12, y: 0), Point(x: 12, y: 14), Point(x: 30, y: 14)])
        let router = CurveFittingEdgeRouter(); router.radius = 50; router.routeEdges(g)
        // Corners at (12,0) and (12,14) share a 14-unit leg and the first leg is 12 long: nothing leaves the hull.
        for p in e.path { #expect(p.x >= -1e-4 && p.x <= 30 + 1e-4 && p.y >= -1e-4 && p.y <= 14 + 1e-4) }
        #expect(e.path.first == Point(x: 0, y: 0) && e.path.last == Point(x: 30, y: 14))
        #expect(e.path[1].y == 0 && e.path[e.path.count - 2].y == 14)
    }

    // MARK: Self-loops

    @Test func selfLoopsKeepClearanceFromNeighboursAndNestedLoopsDoNotShareLegs() {
        let g = LayoutGraph()
        let n = node(g, "n", Rect(x: 0, y: 0, width: 24, height: 24))
        let loops = (0..<9).map { _ in LayoutEdge(source: n, target: n) }
        for l in loops { g.addEdge(l) }
        SelfLoopRouter().routeEdges(g)
        for l in loops { #expect(l.path.count == 5) }
        // No two loops run along the same line over a stretch.
        for (i, a) in loops.enumerated() { for b in loops[(i + 1)...] {
            for (p, q) in zip(a.path, a.path.dropFirst()) { for (c, d) in zip(b.path, b.path.dropFirst()) {
                let vertical = p.x == q.x && c.x == d.x && p.x == c.x, horizontal = p.y == q.y && c.y == d.y && p.y == c.y
                if vertical { #expect(min(max(p.y, q.y), max(c.y, d.y)) - max(min(p.y, q.y), min(c.y, d.y)) <= 1e-4) }
                if horizontal { #expect(min(max(p.x, q.x), max(c.x, d.x)) - max(min(p.x, q.x), min(c.x, d.x)) <= 1e-4) }
            } }
        } }
    }

    @Test func selfLoopsTreatPaddingAsClearance() {
        let g = LayoutGraph()
        let n = node(g, "n", Rect(x: 0, y: 0, width: 80, height: 32))
        // A neighbour whose gap is smaller than the loop's reach plus padding blocks the top corners.
        _ = node(g, "above", Rect(x: -20, y: -38, width: 120, height: 30))
        let loop = edge(g, n, n, []), router = SelfLoopRouter()
        router.routeEdges(g)
        let top = loop.path.map(\.y).min()!
        #expect(top >= 32 - 1e-4 || router.unroutableEdges.isEmpty)
        #expect(ObstaclePolyline.clear(loop.path, [Rect(x: -20, y: -38, width: 120, height: 30).inflated(by: router.padding)]))
    }

    @Test func selfLoopsAvoidRunningAlongAnExistingRoute() {
        let g = LayoutGraph()
        let n = node(g, "n", Rect(x: 0, y: 0, width: 80, height: 32)), m = node(g, "m", Rect(x: 300, y: -200, width: 40, height: 30))
        // A route that already leaves the top-right corner along the leg the first loop would use.
        edge(g, n, m, [Point(x: 72, y: 0), Point(x: 72, y: -100), Point(x: 300, y: -100)])
        let loop = edge(g, n, n, [])
        SelfLoopRouter().routeEdges(g)
        let legs = zip(loop.path, loop.path.dropFirst()).filter { $0.x == $1.x && $0.x == 72 && max($0.y, $1.y) <= 0 }
        #expect(legs.isEmpty)
    }

    // MARK: A2

    private func sideTargets(_ g: LayoutGraph, count: Int, bendFirst: Bool = false) -> (LayoutNode, [LayoutEdge]) {
        let hub = node(g, "hub", Rect(x: 100, y: 200, width: 120, height: 40))
        var edges: [LayoutEdge] = []
        for i in 0..<count {
            let x = Float(i) * 160
            let t = node(g, "t\(i)", Rect(x: x, y: 0, width: 40, height: 40))
            // Every edge leaves the hub top at its centre x=160 and fans out to its target.
            let path = bendFirst ? [Point(x: 160, y: 200), Point(x: 160, y: 120 - Float(i) * 4), Point(x: x + 20, y: 120 - Float(i) * 4), Point(x: x + 20, y: 40)]
                                 : [Point(x: 160, y: 200), Point(x: x + 20, y: 40)]
            edges.append(edge(g, hub, t, path))
        }
        return (hub, edges)
    }

    @Test func portDistributionSpreadsPolylineEndpointsInNeighbourOrder() {
        let g = LayoutGraph(), (hub, edges) = sideTargets(g, count: 4)
        PortDistributor().routeEdges(g)
        let xs = edges.map { $0.path[0].x }
        #expect(xs == xs.sorted() && Set(xs).count == 4)
        #expect(edges.allSatisfy { $0.path[0].y == 200 })
        let pitch = hub.bounds.width / 5
        for (i, x) in xs.enumerated() { #expect(abs(x - (hub.bounds.left + pitch * Float(i + 1))) < 1e-4) }
        #expect(xs.allSatisfy { $0 >= hub.bounds.left + 6 && $0 <= hub.bounds.right - 6 })
        let before = edges.map(\.path); PortDistributor().routeEdges(g); #expect(edges.map(\.path) == before)
    }

    @Test func portDistributionKeepsOrthogonalRoutesOrthogonalByLeggingTheFirstLeg() {
        let g = LayoutGraph(), (_, edges) = sideTargets(g, count: 3, bendFirst: true)
        PortDistributor().routeEdges(g)
        for e in edges {
            #expect(zip(e.path, e.path.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y })
            #expect(e.path[0].y == 200 && e.path[0].x == e.path[1].x)
        }
        #expect(Set(edges.map { $0.path[0].x }).count == 3)
    }

    @Test func portDistributionAddsAJogOnlyForASingleStraightLeg() {
        let g = LayoutGraph()
        let a = node(g, "a", Rect(x: 0, y: 0, width: 100, height: 40)), b = node(g, "b", Rect(x: 0, y: 200, width: 100, height: 40))
        let e1 = edge(g, a, b, [Point(x: 50, y: 40), Point(x: 50, y: 200)]), e2 = edge(g, a, b, [Point(x: 50, y: 40), Point(x: 50, y: 200)])
        // A bent route elsewhere makes this an orthogonal drawing.
        let c = node(g, "c", Rect(x: 300, y: 0, width: 40, height: 40))
        edge(g, c, b, [Point(x: 320, y: 40), Point(x: 320, y: 120), Point(x: 90, y: 120), Point(x: 90, y: 200)])
        PortDistributor().routeEdges(g)
        for e in [e1, e2] {
            #expect(zip(e.path, e.path.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y })
            #expect(e.path.first!.y == 40 && e.path.last!.y == 200)
        }
        #expect(e1.path.first!.x != e2.path.first!.x && e1.path.last!.x != e2.path.last!.x)
        // Distinct jog heights, so the horizontal runs do not coincide.
        let jogs = [e1, e2].map { e in e.path.first { p in p.y != 40 && p.y != 200 }!.y }
        #expect(jogs[0] != jogs[1])
    }

    @Test func portDistributionKeepsConstrainedPortsOnTheirSideAndSkipsBlockedMoves() {
        let g = LayoutGraph(), (hub, edges) = sideTargets(g, count: 3)
        edges[0].sourcePort = .top
        PortDistributor().routeEdges(g)
        #expect(hub.bounds.top == edges[0].path[0].y)
        // A port constrained to another side is never moved onto the top side.
        let h = LayoutGraph(), (_, others) = sideTargets(h, count: 3)
        others[1].sourcePort = .left
        let before = others[1].path
        PortDistributor().routeEdges(h)
        #expect(others[1].path == before)
        // A neighbour right above the node blocks a tilted first leg: that edge stays put.
        let k = LayoutGraph()
        let n = node(k, "n", Rect(x: 0, y: 100, width: 100, height: 40)), m = node(k, "m", Rect(x: 400, y: 0, width: 40, height: 40))
        let wall = node(k, "wall", Rect(x: 20, y: 70, width: 120, height: 25))
        let e1 = edge(k, n, m, [Point(x: 50, y: 100), Point(x: 420, y: 40)]), e2 = edge(k, n, m, [Point(x: 50, y: 100), Point(x: 420, y: 40)])
        let originals = [e1.path, e2.path]
        PortDistributor().routeEdges(k)
        for (e, original) in zip([e1, e2], originals) {
            #expect(ObstaclePolyline.clear(e.path, [wall.bounds]) || e.path == original)
        }
    }

    @Test func portDistributionLeavesUnclippedAndSelfLoopEndpointsAlone() {
        let g = LayoutGraph(), (_, edges) = sideTargets(g, count: 2)
        edges[0].path[0] = Point(x: 160, y: 220)
        let before = edges[0].path
        let n = node(g, "loop", Rect(x: 500, y: 0, width: 40, height: 40)), loop = edge(g, n, n, [])
        SelfLoopRouter().routeEdges(g); let loopPath = loop.path
        PortDistributor().routeEdges(g)
        #expect(edges[0].path == before && loop.path == loopPath)
    }

    @Test func portDistributionIsAvailableOnBuildersAndKeepsCornersClear() async throws {
        let g = LayoutGraph()
        let a = node(g, "a", Rect(width: 40, height: 40)), b = node(g, "b", Rect(x: 100, y: 100, width: 40, height: 40))
        let e = edge(g, a, b, [Point(x: 20, y: 20), Point(x: 120, y: 120)])
        try await LayoutBuilder.create(g).clipEdgeEndpoints().distributePorts().applyAsync()
        #expect(onBoundary(e.path[0], a.bounds) && onBoundary(e.path.last!, b.bounds))
        let corners = [a.bounds.left, a.bounds.right], p = e.path[0]
        #expect(!(corners.contains(p.x) && [a.bounds.top, a.bounds.bottom].contains(p.y)))
        try await LayoutBuilder.create(g).distributePorts(backend: .cpu).applyAsync()
    }
}
