import Foundation
import Testing
@testable import SwiftGraph

private struct Lcg: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s ^ (s >> 29) }
}
private func crosses(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
    func x(_ p: Point, _ q: Point) -> Double { p.x * q.y - p.y * q.x }
    let u = b - a, v = d - c, den = x(u, v)
    guard abs(den) > 1e-12 else { return false }
    let t = x(c - a, v) / den, s = x(c - a, u) / den
    return t > 1e-9 && t < 1 - 1e-9 && s > 1e-9 && s < 1 - 1e-9
}
private func segments(_ e: LayoutEdge) -> [(Point, Point)] { Array(zip(e.path, e.path.dropFirst())) }
/// Crossings between edges that join the same two nodes (duplicates and reciprocals).
private func pairCrossings(_ g: LayoutGraph) -> Int {
    let es = g.edges.filter { $0.source !== $0.target && $0.path.count >= 2 }
    var total = 0
    for i in es.indices { for j in (i + 1)..<max(i + 1, es.count) {
        let a = es[i], b = es[j]
        guard (a.source === b.source && a.target === b.target) || (a.source === b.target && a.target === b.source) else { continue }
        for (p, q) in segments(a) { for (r, s) in segments(b) where crosses(p, q, r, s) { total += 1 } }
    } }
    return total
}
/// Edge/node pairs where a route cuts through a node that is not one of its own ends.
private func nodeHits(_ g: LayoutGraph) -> Int {
    g.edges.filter { $0.path.count >= 2 }.reduce(0) { n, e in
        n + g.nodes.filter { node in node !== e.source && node !== e.target && !node.isGroup && segments(e).contains { s in node.bounds.inflated(by: -0.5).intersectsLine(s.0, s.1) } }.count
    }
}
/// Ends of non-loop edges that do not sit on their own node's outline (1.5 units of slack).
private func looseEnds(_ g: LayoutGraph) -> Int {
    var n = 0
    for e in g.edges where e.source !== e.target && e.path.count >= 2 {
        for (p, node) in [(e.path[0], e.source), (e.path[e.path.count - 1], e.target)] {
            let b = node.bounds, d = min(abs(p.x - b.left), abs(p.x - b.right), abs(p.y - b.top), abs(p.y - b.bottom))
            if !(b.inflated(by: 1.5).contains(p) && d <= 1.5) { n += 1 }
        }
    }
    return n
}
/// Nodes on a jittered grid, random edges, and some triplicated and reciprocal pairs.
private func spread(_ rng: inout Lcg, nodes count: Int, edges m: Int, duplicates: Int, reciprocals: Int) -> LayoutGraph {
    let g = LayoutGraph(), cols = Int(Double(count).squareRoot().rounded(.up))
    var nodes: [LayoutNode] = []
    for i in 0..<count {
        let n = LayoutNode(id: "n\(i)", width: Double(Int.random(in: 36...70, using: &rng)), height: Double(Int.random(in: 24...40, using: &rng)))
        n.x = Double(i % cols) * 150 + Double(Int.random(in: 0..<40, using: &rng)); n.y = Double(i / cols) * 120 + Double(Int.random(in: 0..<30, using: &rng))
        nodes.append(n); g.addNode(n)
    }
    func pick() -> (Int, Int) { var a = 0, b = 0; repeat { a = Int.random(in: 0..<count, using: &rng); b = Int.random(in: 0..<count, using: &rng) } while a == b; return (a, b) }
    for _ in 0..<m { let (a, b) = pick(); g.addEdge(LayoutEdge(source: nodes[a], target: nodes[b])) }
    for _ in 0..<duplicates { let (a, b) = pick(); for _ in 0..<3 { g.addEdge(LayoutEdge(source: nodes[a], target: nodes[b])) } }
    for _ in 0..<reciprocals { let (a, b) = pick(); g.addEdge(LayoutEdge(source: nodes[a], target: nodes[b])); g.addEdge(LayoutEdge(source: nodes[b], target: nodes[a])) }
    return g
}
private func twelveEdges() -> LayoutGraph {
    let g = LayoutGraph(); var ns: [LayoutNode] = []
    for (i, q) in [(0.0, 0.0), (300, 10), (150, 250), (-20, 300), (320, 320), (160, -200)].enumerated() {
        let n = LayoutNode(id: "n\(i)", width: 60, height: 36); n.x = q.0; n.y = q.1; ns.append(n); g.addNode(n)
    }
    for (a, b) in [(0, 1), (0, 1), (0, 1), (1, 0), (2, 3), (2, 3), (3, 2), (4, 5), (5, 4), (0, 2), (1, 4), (3, 5)] { g.addEdge(LayoutEdge(source: ns[a], target: ns[b])) }
    return g
}

private struct Counts: Equatable { var pairCrossings: Int, nodeHits: Int, looseEnds: Int }
private func counts(_ g: LayoutGraph) -> Counts { Counts(pairCrossings: pairCrossings(g), nodeHits: nodeHits(g), looseEnds: looseEnds(g)) }
/// Routes `g` through polyline (or straight centre lines), bundling, clipping and port distribution; counts after each stage.
private func pipeline(_ g: LayoutGraph, polyline: Bool) -> (start: Counts, bundled: Counts, clipped: Counts, distributed: Counts) {
    if polyline { PolylineEdgeRouter().routeEdges(g) } else { for e in g.edges { e.path = [e.source.center, e.target.center] } }
    let start = counts(g)
    EdgeBundlingRouter().routeEdges(g); let bundled = counts(g)
    EdgeEndpointClipper.clipToNodeBounds(g); let clipped = counts(g)
    PortDistributor().routeEdges(g)
    return (start, bundled, clipped, counts(g))
}
private func layered(seed: UInt64) async throws -> LayoutGraph {
    var rng = Lcg(s: seed)
    let g = spread(&rng, nodes: 40, edges: 100, duplicates: 4, reciprocals: 6)
    try await LayoutBuilder.create(g).useOrgChart { $0.siblingDistance = 40; $0.layerDistance = 80 }.applyAsync()
    for e in g.edges { e.path = [] }
    return g
}
private func axisAligned(_ path: [Point]) -> Bool { zip(path, path.dropFirst()).allSatisfy { abs($0.x - $1.x) < 1e-9 || abs($0.y - $1.y) < 1e-9 } }
private func node(_ g: LayoutGraph, _ id: String, _ x: Double, _ y: Double, _ w: Double = 40, _ h: Double = 30) -> LayoutNode {
    let n = LayoutNode(id: id, width: w, height: h); n.center = Point(x: x, y: y); g.addNode(n); return n
}

struct MultiEdgeFixTests {
    @Test func laneOrderFollowsTheRoutesLanesAlreadyHave() {
        // Polyline lanes lie in the opposite order to edge index; fanning by index used to cross them.
        let r = pipeline(twelveEdges(), polyline: true)
        #expect(r.start.pairCrossings == 0)
        #expect(r.bundled.pairCrossings == 0); #expect(r.clipped.pairCrossings == 0); #expect(r.distributed.pairCrossings == 0)
        #expect(r.distributed.nodeHits == 0); #expect(r.distributed.looseEnds == 0)
    }

    @Test func straightMultiEdgesStayUncrossedThroughBundlingAndDistribution() {
        let r = pipeline(twelveEdges(), polyline: false)
        #expect(r.bundled.pairCrossings == 0); #expect(r.clipped.pairCrossings == 0); #expect(r.distributed.pairCrossings == 0)
        #expect(r.distributed.nodeHits <= r.start.nodeHits); #expect(r.distributed.looseEnds == 0)
    }

    @Test(arguments: [1, 2, 3, 4] as [UInt64]) func layeredMultiEdgeGraphsGainNoCrossingsOrNodeHits(seed: UInt64) async throws {
        for polyline in [true, false] {
            let r = pipeline(try await layered(seed: seed), polyline: polyline)
            #expect(r.bundled.pairCrossings <= r.start.pairCrossings, "seed \(seed) polyline \(polyline): \(r)")
            #expect(r.distributed.pairCrossings <= r.start.pairCrossings, "seed \(seed) polyline \(polyline): \(r)")
            #expect(r.distributed.nodeHits <= r.start.nodeHits, "seed \(seed) polyline \(polyline): \(r)")
            #expect(r.distributed.looseEnds == 0, "seed \(seed) polyline \(polyline): \(r)")
        }
    }

    @Test(arguments: [1, 2, 3] as [UInt64]) func scatteredMultiEdgeGraphsGainNoCrossingsOrNodeHits(seed: UInt64) {
        for polyline in [true, false] {
            var rng = Lcg(s: seed)
            let r = pipeline(spread(&rng, nodes: 40, edges: 100, duplicates: 4, reciprocals: 6), polyline: polyline)
            #expect(r.bundled.pairCrossings <= r.start.pairCrossings, "seed \(seed) polyline \(polyline): \(r)")
            #expect(r.distributed.pairCrossings <= r.start.pairCrossings, "seed \(seed) polyline \(polyline): \(r)")
            #expect(r.distributed.nodeHits <= r.start.nodeHits, "seed \(seed) polyline \(polyline): \(r)")
            #expect(r.distributed.looseEnds == 0, "seed \(seed) polyline \(polyline): \(r)")
        }
    }

    @Test(arguments: LayoutPatternType.allCases) func presetsOnMultiEdgeGraphsKeepEndsOnFacesAndDistributionAddsNothing(pattern: LayoutPatternType) async throws {
        var rng = Lcg(s: 7)
        let g = spread(&rng, nodes: 80, edges: 170, duplicates: 4, reciprocals: 10)
        try await LayoutBuilder.create(g).applyPattern(pattern).applyAsync()
        let before = counts(g)
        #expect(before.looseEnds == 0, "\(pattern)")
        // Distributing a finished drawing again must not make it worse.
        PortDistributor().routeEdges(g)
        let after = counts(g)
        #expect(after.pairCrossings <= before.pairCrossings && after.nodeHits <= before.nodeHits && after.looseEnds == 0, "\(pattern) \(before) \(after)")
    }

    @Test func distributionKeepsLanesThatAreAlreadySeparated() {
        // Four lanes 8 apart on a 36 wide face: spreading them evenly would squeeze them to 7.2.
        let g = LayoutGraph(), top = node(g, "t", 0, 0, 36, 30), bottom = node(g, "b", 0, 200, 36, 30)
        let xs = [-12.0, -4, 4, 12]
        let edges = xs.map { x -> LayoutEdge in
            let e = LayoutEdge(source: top, target: bottom); g.addEdge(e); e.path = [Point(x: x, y: 15), Point(x: x, y: 185)]; return e
        }
        PortDistributor().routeEdges(g)
        let ends = edges.map { $0.path[0].x }
        #expect(ends == xs, "\(ends)")
    }

    @Test func distributionLeavesCrowdedFacesAlone() {
        // Six coincident ends on a 30 wide face cannot be 4.3 apart inside the margins, so nothing is crammed.
        let g = LayoutGraph(), top = node(g, "t", 0, 0, 30, 30), bottom = node(g, "b", 0, 200, 30, 30)
        let edges = (0..<6).map { _ -> LayoutEdge in
            let e = LayoutEdge(source: top, target: bottom); g.addEdge(e); e.path = [Point(x: 0, y: 15), Point(x: 0, y: 185)]; return e
        }
        PortDistributor().routeEdges(g)
        #expect(edges.allSatisfy { $0.path[0].x == 0 })
    }

    @Test func distributionSpreadsCoincidentEndsEvenlyAndInOrder() {
        let g = LayoutGraph(), top = node(g, "t", 0, 0, 100, 30), a = node(g, "a", -80, 200), b = node(g, "b", 0, 200), c = node(g, "c", 80, 200)
        let edges = [c, a, b].map { target -> LayoutEdge in
            let e = LayoutEdge(source: top, target: target); g.addEdge(e); e.path = [Point(x: 0, y: 15), target.center - Point(x: 0, y: 15)]; return e
        }
        PortDistributor().routeEdges(g)
        let x = Dictionary(uniqueKeysWithValues: edges.map { ($0.target.id, $0.path[0].x) })
        #expect(x["a"]! < x["b"]! && x["b"]! < x["c"]!)
        #expect(abs(x["b"]! - x["a"]! - 25) < 1e-9 && abs(x["c"]! - x["b"]! - 25) < 1e-9)
    }

    @Test func removeOverlapsKeepsOrthogonalRoutesOrthogonal() throws {
        let g = LayoutGraph(), a = node(g, "a", 0, 0, 80, 40), b = node(g, "b", 10, 5, 80, 40), c = node(g, "c", 300, 200, 40, 30)
        let e = LayoutEdge(source: a, target: c); g.addEdge(e)
        e.path = [Point(x: 40, y: 0), Point(x: 170, y: 0), Point(x: 170, y: 200), Point(x: 280, y: 200)]
        let f = LayoutEdge(source: b, target: c); g.addEdge(f)
        f.path = [Point(x: 50, y: 5), Point(x: 50, y: 120), Point(x: 280, y: 120)]
        try RemoveOverlapsLayoutAlgorithm().applyLayout(g)
        #expect(!a.bounds.intersects(b.bounds))
        for x in [e, f] { #expect(axisAligned(x.path), "\(x.path)") }
    }

    @Test func movedNodesTranslateRectilinearLegsRigidly() {
        let g = LayoutGraph(), a = node(g, "a", 0, 0, 80, 40), b = node(g, "b", 240, 100, 80, 40)
        let e = LayoutEdge(source: a, target: b); g.addEdge(e)
        e.path = [Point(x: 40, y: 0), Point(x: 120, y: 0), Point(x: 120, y: 100), Point(x: 200, y: 100)]
        let old = g.nodes.map(\.bounds)
        a.x += 30; a.y += 20; b.y += 20
        followMovedNodes(g, from: old)
        #expect(axisAligned(e.path), "\(e.path)")
        #expect(e.path.first! == Point(x: 70, y: 20)); #expect(e.path.last! == Point(x: 200, y: 120))
        // A rigid move of both ends is a pure translation.
        let h = LayoutGraph(), c = node(h, "c", 0, 0), d = node(h, "d", 200, 100)
        let f = LayoutEdge(source: c, target: d); h.addEdge(f)
        f.path = [Point(x: 20, y: 0), Point(x: 110, y: 0), Point(x: 110, y: 100), Point(x: 180, y: 100)]
        let before = h.nodes.map(\.bounds)
        c.x += 7; c.y -= 3; d.x += 7; d.y -= 3
        followMovedNodes(h, from: before)
        #expect(f.path == [Point(x: 27, y: -3), Point(x: 117, y: -3), Point(x: 117, y: 97), Point(x: 187, y: 97)])
    }

    @Test func movedNodesGiveALoneStraightLegAJogInsteadOfTiltingIt() {
        let g = LayoutGraph(), a = node(g, "a", 0, 0), b = node(g, "b", 300, 0), other = node(g, "o", 0, 200), p = node(g, "p", 300, 200)
        let straight = LayoutEdge(source: a, target: b); g.addEdge(straight)
        straight.path = [Point(x: 20, y: 0), Point(x: 280, y: 0)]
        let bent = LayoutEdge(source: other, target: p); g.addEdge(bent)
        bent.path = [Point(x: 20, y: 200), Point(x: 160, y: 200), Point(x: 160, y: 230), Point(x: 280, y: 230)]
        let old = g.nodes.map(\.bounds)
        b.y += 60
        followMovedNodes(g, from: old)
        #expect(axisAligned(straight.path), "\(straight.path)"); #expect(straight.path.first! == Point(x: 20, y: 0))
        #expect(straight.path.last! == Point(x: 280, y: 60))
        #expect(axisAligned(bent.path), "\(bent.path)")
    }

    @Test func movedNodesRerouteBlockedRectilinearRoutesRectilinearly() {
        let g = LayoutGraph(), a = node(g, "a", 0, 0), b = node(g, "b", 300, 100), wall = node(g, "w", 600, 600, 20, 40)
        let e = LayoutEdge(source: a, target: b); g.addEdge(e)
        e.path = [Point(x: 20, y: 0), Point(x: 160, y: 0), Point(x: 160, y: 100), Point(x: 280, y: 100)]
        let old = g.nodes.map(\.bounds)
        wall.center = Point(x: 160, y: 50)   // lands across the route's vertical leg
        followMovedNodes(g, from: old)
        #expect(axisAligned(e.path), "\(e.path)")
        #expect(ObstaclePolyline.clear(e.path, [wall.bounds]))
        #expect(e.path.first! == Point(x: 20, y: 0) && e.path.last! == Point(x: 280, y: 100))
    }

    @Test func bundlerStopsBuildingCompatibilityWhenCancelled() {
        let edges = (0..<40).map { i in BundlingEdge(source: -1, target: -1, from: Point(x: 0, y: Double(i)), to: Point(x: 200, y: Double(i)), path: []) }
        let free = EdgeBundler(BundlingSettings(), nodes: [], solid: [], edges: edges)
        #expect(!free.compatible.isEmpty)
        let cancellation = RoutingCancellation(); cancellation.cancel()
        let stopped = RoutingCompute.$cancellation.withValue(cancellation) { EdgeBundler(BundlingSettings(), nodes: [], solid: [], edges: edges) }
        #expect(stopped.compatible.isEmpty)
    }
}
