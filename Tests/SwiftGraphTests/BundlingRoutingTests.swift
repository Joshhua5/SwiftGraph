import Foundation
import Testing
@testable import SwiftGraph

private func node(_ g: LayoutGraph, _ id: String, _ x: Double, _ y: Double, _ w: Double = 40, _ h: Double = 30) -> LayoutNode {
    let n = LayoutNode(id: id, width: w, height: h); n.center = Point(x: x, y: y); g.addNode(n); return n
}
private func edge(_ g: LayoutGraph, _ a: LayoutNode, _ b: LayoutNode) -> LayoutEdge {
    let e = LayoutEdge(source: a, target: b); g.addEdge(e); return e
}
private func onOutline(_ p: Point, _ r: Rect) -> Bool { r.inflated(by: 1e-6).contains(p) && !r.inflated(by: -1e-6).contains(p) }
private func clear(_ e: LayoutEdge, _ g: LayoutGraph) -> Bool { ObstaclePolyline.clear(e.path, ObstaclePolyline.obstacles(e, g)) }

struct BundlingRoutingTests {
    @Test func layeredEdgesUseFacesAndNeverCoincide() throws {
        let g = LayoutGraph(), a = node(g, "a", 0, 0), b = node(g, "b", 0, 0)
        let forward = edge(g, a, b), duplicate = edge(g, a, b), back = edge(g, b, a)
        try HierarchicalLayoutAlgorithm().applyLayout(g)
        for e in g.edges {
            #expect(onOutline(e.path.first!, e.source.bounds)); #expect(onOutline(e.path.last!, e.target.bounds))
        }
        #expect(forward.path.first!.y == a.bounds.bottom && forward.path.last!.y == b.bounds.top)
        #expect(back.path.first!.y == b.bounds.top && back.path.last!.y == a.bounds.bottom)
        let starts = Set(g.edges.map { $0.source === a ? $0.path.first! : $0.path.last! })
        #expect(starts.count == 3); #expect(duplicate.path != forward.path)
    }

    @Test func layeredEdgesBeyondTheVirtualNodeCapDetourAroundNodes() throws {
        let g = LayoutGraph(), nodes = (0..<70).map { node(g, "n\($0)", 0, 0) }
        for pair in zip(nodes, nodes.dropFirst()) { _ = edge(g, pair.0, pair.1) }
        let long = edge(g, nodes[0], nodes[69])
        try HierarchicalLayoutAlgorithm().applyLayout(g)
        #expect(long.path.count > 2); #expect(clear(long, g))
    }

    @Test func removeOverlapsKeepsEdgesAttachedToMovedNodes() throws {
        let g = LayoutGraph(), a = node(g, "a", 0, 0, 60, 40), b = node(g, "b", 10, 5, 60, 40), c = node(g, "c", 300, 0)
        let e = edge(g, a, c), f = edge(g, b, c)
        for x in g.edges { x.path = [x.source.center, x.target.center] }
        try RemoveOverlapsLayoutAlgorithm().applyLayout(g)
        #expect(!a.bounds.intersects(b.bounds))
        for x in [e, f] { #expect((x.path.first! - x.source.center).length < 1e-9); #expect((x.path.last! - x.target.center).length < 1e-9) }
    }

    @Test func parallelRouterKeepsSingleEdgeRoutesAndAvoidsNodes() {
        let g = LayoutGraph(), a = node(g, "a", 0, 0), b = node(g, "b", 400, 0), wall = node(g, "w", 200, 0, 40, 200)
        let single = edge(g, node(g, "c", 0, 300), node(g, "d", 400, 300)), kept = [Point(x: 0, y: 300), Point(x: 200, y: 340), Point(x: 400, y: 300)]
        single.path = kept
        let lanes = (0..<3).map { _ in edge(g, a, b) }
        ParallelEdgeRouter().routeEdges(g)
        #expect(single.path == kept)
        #expect(lanes.allSatisfy { clear($0, g) }); #expect(Set(lanes.map(\.path)).count == 3)
        _ = wall
    }

    @Test func octilinearSiblingsDoNotShareADiagonal() {
        let g = LayoutGraph(), hub = node(g, "h", 0, 0), a = node(g, "a", 100, 300), b = node(g, "b", 300, 300)
        let e = edge(g, hub, a), f = edge(g, hub, b)
        OctilinearEdgeRouter().routeEdges(g)
        func diagonal(_ x: LayoutEdge) -> [Point] { x.path.dropFirst().isEmpty ? [] : Array(zip(x.path, x.path.dropFirst()).filter { abs($0.0.x - $0.1.x) > 1e-9 && abs($0.0.y - $0.1.y) > 1e-9 }.map { $0.1 }) }
        #expect(diagonal(e).isEmpty || diagonal(f).isEmpty || diagonal(e) != diagonal(f))
        #expect(Set(e.path.dropFirst().dropLast()).isDisjoint(with: Set(f.path.dropFirst().dropLast())))
    }

    @Test func busTrunkRunsBesideTheNodesAndLeavesAreChecked() {
        let g = LayoutGraph(), hub = node(g, "hub", 0, 0)
        let leaves = (0..<4).map { node(g, "l\($0)", 400, Double($0) * 100 - 150) }
        let blockers = (1..<3).map { node(g, "m\($0)", 0, Double($0) * 100) }
        let edges = leaves.map { edge(g, hub, $0) }
        BusEdgeRouter().routeEdges(g)
        #expect(edges.allSatisfy { clear($0, g) })
        // One lane for the single column of leaves, shared by every leaf.
        let lanes = Set(edges.flatMap { $0.path.dropFirst().dropLast().map(\.x) })
        #expect(lanes.count == 1)
        _ = blockers
    }

    @Test func bundlingStraightensUnbundledEdgesAndSeparatesMultiEdges() {
        let g = LayoutGraph(), a = node(g, "a", 0, 0), b = node(g, "b", 400, 0), c = node(g, "c", 0, 900), d = node(g, "d", 400, 900)
        let lone = edge(g, c, d), forward = edge(g, a, b), duplicate = edge(g, a, b), back = edge(g, b, a)
        EdgeBundlingRouter().routeEdges(g)
        #expect(lone.path == [c.center, d.center])
        #expect(forward.path != duplicate.path && forward.path != back.path.reversed() && duplicate.path != back.path.reversed())
        for e in [forward, duplicate, back] { #expect(e.path.first == e.source.center); #expect(e.path.last == e.target.center) }
    }

    @Test func bundlingKeepsExistingRoutesAroundNodes() {
        let g = LayoutGraph(), a = node(g, "a", 0, 0), b = node(g, "b", 600, 0), wall = node(g, "w", 300, 0, 40, 300)
        let e = edge(g, a, b)
        PolylineEdgeRouter().routeEdges(g)
        #expect(e.path.count > 2)
        EdgeBundlingRouter().routeEdges(g)
        #expect(clear(e, g)); _ = wall
    }

    @Test func labelPlacementKeepsMeasuredSizesAndAvoidsOtherEdges() {
        let g = LayoutGraph(), a = node(g, "a", 0, 0), b = node(g, "b", 400, 0), c = node(g, "c", 200, -200), d = node(g, "d", 200, 200)
        let labelled = edge(g, a, b), cross = edge(g, c, d)
        for e in g.edges { e.path = [e.source.center, e.target.center] }
        labelled.data = "measured"; labelled.labelBounds = Rect(width: 90, height: 24)
        LabelPlacementAlgorithm().applyLabelPlacement(g)
        #expect(labelled.labelBounds.size == Size(width: 90, height: 24))
        #expect(!labelled.labelBounds.intersectsLine(cross.path[0], cross.path[1]))
        let provided = LabelPlacementAlgorithm(); provided.sizeProvider = { _, _ in Size(width: 70, height: 16) }
        provided.applyLabelPlacement(g)
        #expect(labelled.labelBounds.size == Size(width: 70, height: 16))
    }

    @Test func labelLayoutLeavesUnlabelledEdgesAlone() {
        let g = LayoutGraph(), a = node(g, "a", 0, 0), b = node(g, "b", 300, 0), c = node(g, "c", 150, 200)
        let labelled = edge(g, a, b), bare = edge(g, a, c)
        for e in g.edges { e.path = [e.source.center, e.target.center] }
        labelled.labelBounds = Rect(width: 60, height: 20)
        LabelLayoutAlgorithm().applyLabelLayout(g)
        #expect(labelled.labelBounds.size == Size(width: 60, height: 20)); #expect(bare.labelBounds == Rect())
    }
}
