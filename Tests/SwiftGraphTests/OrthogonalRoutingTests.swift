import Foundation
import Testing
@testable import SwiftGraph

private func node(_ id: String, _ r: Rect, group: Bool = false, parent: LayoutNode? = nil) -> LayoutNode {
    let n = LayoutNode(id: id, width: r.width, height: r.height); n.bounds = r; n.isGroup = group
    if let parent { n.parent = parent; parent.children.append(n) }
    return n
}
private func graph(_ nodes: [LayoutNode], edges: [(Int, Int)]) -> LayoutGraph {
    let g = LayoutGraph()
    for n in nodes { g.addNode(n) }
    for (s, t) in edges { g.addEdge(LayoutEdge(source: nodes[s], target: nodes[t])) }
    return g
}
private func orthogonal(_ path: [Point]) -> Bool { zip(path, path.dropFirst()).allSatisfy { abs($0.x - $1.x) < 1e-6 || abs($0.y - $1.y) < 1e-6 } }
private func clear(_ path: [Point], of nodes: [LayoutNode]) -> Bool {
    !zip(path, path.dropFirst()).contains { a, b in nodes.contains { $0.bounds.inflated(by: -1e-6).intersectsLine(a, b) } }
}
private func onBoundary(_ p: Point, _ r: Rect) -> Bool { r.inflated(by: 1e-6).contains(p) && !r.inflated(by: -1e-6).contains(p) }

@Suite struct OrthogonalRoutingTests {
    @Test func channelPicksTheFacingSideAndLeavesPerpendicularFromTheBoundary() {
        let a = node("a", Rect(x: 0, y: 0, width: 80, height: 40)), b = node("b", Rect(x: 0, y: 300, width: 80, height: 40)), c = node("c", Rect(x: 400, y: 0, width: 80, height: 40))
        let g = graph([a, b, c], edges: [(0, 1), (0, 2)])
        let router = ChannelEdgeRouter(); router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty)
        let down = g.edges[0].path, across = g.edges[1].path
        #expect(down.first?.y == 40 && down.last?.y == 300 && down.count == 2) // straight, bottom to top
        #expect(across.first?.x == 80 && across.last?.x == 400 && across.count == 2) // straight, right to left
    }
    @Test func channelEndsAreNeverInsideEndpointsAndLeaveNoStairSteps() {
        let a = node("a", Rect(x: 3, y: 7, width: 90, height: 50)), b = node("b", Rect(x: 333, y: 211, width: 90, height: 50)), wall = node("w", Rect(x: 150, y: 0, width: 60, height: 300))
        let g = graph([a, b, wall], edges: [(0, 1), (1, 0)])
        let router = ChannelEdgeRouter(); router.routeEdges(g)
        for e in g.edges {
            #expect(onBoundary(e.path.first!, e.source.bounds)); #expect(onBoundary(e.path.last!, e.target.bounds))
            #expect(orthogonal(e.path)); #expect(clear(e.path, of: [wall]))
            // No segment shorter than a few units: ports are snapped, so no jog is needed to reach the lattice.
            #expect(zip(e.path, e.path.dropFirst()).allSatisfy { ($0 - $1).length >= 4 })
        }
    }
    @Test func channelCongestionCountsEveryTraversedCell() {
        // Two edges that must share a long corridor: the second one pays for every cell, and moves over.
        let nodes = [node("a", Rect(x: 0, y: 0, width: 40, height: 40)), node("b", Rect(x: 600, y: 0, width: 40, height: 40)), node("c", Rect(x: 0, y: 80, width: 40, height: 40)), node("d", Rect(x: 600, y: 80, width: 40, height: 40))]
        let g = graph(nodes, edges: [(0, 1), (2, 3)])
        let router = ChannelEdgeRouter(); router.routeEdges(g)
        let shared = Set(g.edges[0].path.map(\.y)).intersection(g.edges[1].path.map(\.y))
        #expect(shared.isEmpty || g.edges[0].path.count == 2 && g.edges[1].path.count == 2)
        #expect(g.edges[0].path != g.edges[1].path)
    }
    @Test func channelTreatsUnrelatedGroupsAsWallsButCrossesItsOwn() {
        let outer = node("outer", Rect(x: -20, y: -20, width: 140, height: 120), group: true)
        let a = node("a", Rect(x: 0, y: 0, width: 40, height: 40), parent: outer), b = node("b", Rect(x: 400, y: 0, width: 40, height: 40))
        let wall = node("wall", Rect(x: 200, y: -100, width: 60, height: 140), group: true), inner = node("inner", Rect(x: 210, y: -60, width: 40, height: 40), parent: wall)
        let g = graph([outer, a, b, wall, inner], edges: [(1, 2)])
        let router = ChannelEdgeRouter(); router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty)
        #expect(clear(g.edges[0].path, of: [wall]))
        #expect(onBoundary(g.edges[0].path.first!, a.bounds))
    }
    @Test func failedRoutesFallBackToBoundaryRoutesAndAreReported() {
        func walled() -> LayoutGraph {
            var nodes = [node("s", Rect(x: 0, y: 0, width: 40, height: 40)), node("t", Rect(x: 300, y: 0, width: 40, height: 40))]
            for (i, r) in [Rect(x: 270, y: -30, width: 100, height: 30), Rect(x: 270, y: 40, width: 100, height: 30), Rect(x: 270, y: -30, width: 30, height: 100), Rect(x: 340, y: -30, width: 30, height: 100)].enumerated() { nodes.append(node("r\(i)", r)) }
            return graph(nodes, edges: [(0, 1)])
        }
        for router in [ChannelEdgeRouter() as any EdgeRouter, BspEdgeRouter(), OrthogonalGroupedEdgeRouter()] {
            let g = walled(); router.routeEdges(g)
            let path = g.edges[0].path
            let reported = (router as? ChannelEdgeRouter)?.unroutableEdges ?? (router as? BspEdgeRouter)?.unroutableEdges ?? (router as? OrthogonalGroupedEdgeRouter)?.unroutableEdges ?? []
            #expect(reported.count == 1, "\(type(of: router))")
            #expect(path.count >= 2 && !g.nodes[0].bounds.inflated(by: -1).contains(path[0]), "\(type(of: router)): \(path)")
            #expect(path.first != g.nodes[0].center && path.last != g.nodes[1].center, "\(type(of: router)): never a centre-to-centre line")
        }
    }
    @Test func channelSameCellNeighboursStillRunBoundaryToBoundary() {
        let a = node("a", Rect(x: 0, y: 0, width: 30, height: 30)), b = node("b", Rect(x: 36, y: 6, width: 30, height: 30))
        let g = graph([a, b], edges: [(0, 1)])
        let router = ChannelEdgeRouter(); router.routeEdges(g)
        let path = g.edges[0].path
        #expect(path.count >= 2 && onBoundary(path.first!, a.bounds) && onBoundary(path.last!, b.bounds))
        #expect(orthogonal(path))
    }
    @Test func flowDirectionBreaksTiesBetweenSidesAndAlignedChainsRunStraight() {
        // Edges mostly run downwards: that is the flow, and the facing side of a diagonal pair follows the layout flow on a tie.
        let a = node("a", Rect(x: 0, y: 0, width: 40, height: 40)), b = node("b", Rect(x: 200, y: 200, width: 40, height: 40)), c = node("c", Rect(x: 0, y: 400, width: 40, height: 40))
        let g = graph([a, b, c], edges: [(0, 1), (1, 2), (0, 2)])
        let flow = OrthogonalPorts.flow(g)
        #expect(flow.vertical && flow.direction == Point(x: 0, y: 1))
        #expect(OrthogonalPorts.ranked(a, other: b, active: .none, candidates: [], vertical: true).first == .bottom)
        #expect(OrthogonalPorts.ranked(a, other: b, active: .none, candidates: [], vertical: false).first == .right)
        #expect(OrthogonalPorts.ranked(a, other: b, active: .left, candidates: [.top], vertical: true) == [.left])
        #expect(OrthogonalPorts.ranked(a, other: b, active: .none, candidates: [.top, .left], vertical: true) == [.left, .top])
        let straight = graph([node("p", Rect(x: 0, y: 0, width: 100, height: 40)), node("q", Rect(x: 0, y: 200, width: 100, height: 40))], edges: [(0, 1)])
        let router = BspEdgeRouter(); router.edgeSpacing = 0; router.routeEdges(straight)
        #expect(straight.edges[0].path.map(\.y) == [40, 200] && straight.edges[0].path.count == 2)
    }
    @Test func bspRoutesAroundNodesNoStraightCutSeparates() {
        // A pinwheel: no straight cut separates the four rectangles, so lanes must run round them.
        let nodes = [node("a", Rect(x: 0, y: 0, width: 160, height: 40)), node("b", Rect(x: 120, y: 60, width: 40, height: 160)), node("c", Rect(x: 0, y: 180, width: 120, height: 40)), node("d", Rect(x: 0, y: 60, width: 40, height: 100))]
        let g = graph(nodes, edges: [(0, 2), (3, 1)])
        let calculator = BspGridCalculator(); calculator.buildTree(g)
        #expect(calculator.getAllGridSegments().count > 8)
        let router = BspEdgeRouter(); router.edgeSpacing = 0; router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty)
        for e in g.edges { #expect(clear(e.path, of: nodes.filter { $0 !== e.source && $0 !== e.target }), "\(e.path)") }
    }
    @Test func groupedNudgingKeepsNodesInTheirGroupAndOffOtherRoutes() {
        let group = node("g", Rect(x: 0, y: 0, width: 240, height: 120), group: true)
        let a = node("a", Rect(x: 10, y: 10, width: 40, height: 40), parent: group), b = node("b", Rect(x: 190, y: 10, width: 40, height: 40), parent: group)
        let wall = node("wall", Rect(x: 100, y: 40, width: 40, height: 60), parent: group)
        let g = graph([group, a, b, wall], edges: [(1, 2), (1, 2)])
        let router = OrthogonalGroupedEdgeRouter(); router.routeEdges(g)
        for n in [a, b, wall] { #expect(group.bounds.inflated(by: 1e-6).contains(Point(x: n.x, y: n.y)) && group.bounds.inflated(by: 1e-6).contains(Point(x: n.bounds.right, y: n.bounds.bottom)), "\(n.id) stayed in its group") }
        for e in g.edges { #expect(clear(e.path, of: [wall]), "\(e.path)") }
    }
    @Test func groupedRootFrameIsClearOfTheOutermostNodes() {
        let a = node("a", Rect(x: 0, y: 0, width: 40, height: 40)), b = node("b", Rect(x: 200, y: 0, width: 40, height: 40))
        let g = graph([a, b], edges: [(0, 1)])
        let router = OrthogonalGroupedEdgeRouter(); router.obstacleMargin = 12; router.routeEdges(g)
        #expect(g.root.bounds.left <= -12 && g.root.bounds.right >= 252 && g.root.bounds.top <= -12 && g.root.bounds.bottom >= 52)
    }
    @Test func groupedPortsChooseSidesAndRoutesAreDeterministic() {
        let a = node("a", Rect(x: 0, y: 0, width: 40, height: 40)), b = node("b", Rect(x: 200, y: 0, width: 40, height: 40))
        let g = graph([a, b], edges: [(0, 1)])
        g.edges[0].sourcePort = .top; g.edges[0].targetPort = .top
        let router = OrthogonalGroupedEdgeRouter(); router.routeEdges(g)
        let e = g.edges[0]
        #expect(e.path.first?.y == 0 && e.path.last?.y == 0 && e.path.count >= 4, "\(e.path)")
        let first = e.path; router.routeEdges(g); #expect(e.path == first)
    }
}
