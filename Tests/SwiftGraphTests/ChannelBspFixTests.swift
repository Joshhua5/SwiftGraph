import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

/// Route quality measured on a routed graph, shared by the fixture invariants and the regression tests.
struct RouteAudit {
    var fallbacks: [LayoutEdge], diagonal: [Int] = [], leafHits: [(edge: Int, node: String)] = [], offBoundary: [(edge: Int, end: String)] = []
    var minClearance = Float.infinity, crossings = 0, bends = 0
    init(_ graph: LayoutGraph, _ router: any EdgeRouter) {
        switch router {
        case let r as ChannelEdgeRouter: fallbacks = r.unroutableEdges
        case let r as BspEdgeRouter: fallbacks = r.unroutableEdges
        case let r as PolylineEdgeRouter: fallbacks = r.unroutableEdges
        default: fallbacks = []
        }
        let leaves = graph.nodes.filter { !$0.isGroup }
        // Reported fallback edges are drawn as a last resort and exempt from the per-route checks.
        for (i, edge) in graph.edges.enumerated() where edge.source !== edge.target && edge.path.count >= 2 && !fallbacks.contains(where: { $0 === edge }) {
            let segments = Array(zip(edge.path, edge.path.dropFirst()))
            if segments.contains(where: { abs($0.x - $1.x) > 1e-4 && abs($0.y - $1.y) > 1e-4 }) { diagonal.append(i) }
            for leaf in leaves where leaf !== edge.source && leaf !== edge.target && !isAncestor(edge.source, of: leaf) && !isAncestor(edge.target, of: leaf) {
                if segments.contains(where: { leaf.bounds.inflated(by: -1e-4).intersectsLine($0.0, $0.1) }) { leafHits.append((i, leaf.id)) }
                minClearance = min(minClearance, segments.map { Self.distance(leaf.bounds, $0.0, $0.1) }.min()!)
            }
            for (node, point) in [(edge.source, edge.path[0]), (edge.target, edge.path[edge.path.count - 1])] where !node.isGroup {
                if node.bounds.inflated(by: -1e-4).contains(point) || !node.bounds.inflated(by: 1e-4).contains(point) { offBoundary.append((i, node.id)) }
            }
            bends += (1..<(edge.path.count - 1)).filter { abs(Self.cross(edge.path[$0] - edge.path[$0 - 1], edge.path[$0 + 1] - edge.path[$0])) > 1e-4 }.count
        }
        let routed = graph.edges.indices.filter { graph.edges[$0].source !== graph.edges[$0].target && graph.edges[$0].path.count >= 2 }
        for (n, i) in routed.enumerated() { for j in routed[(n + 1)...] {
            for (a, b) in zip(graph.edges[i].path, graph.edges[i].path.dropFirst()) { for (c, d) in zip(graph.edges[j].path, graph.edges[j].path.dropFirst()) where Self.crosses(a, b, c, d) { crossings += 1 } }
        } }
    }
    private static func cross(_ a: Point, _ b: Point) -> Float { a.x * b.y - a.y * b.x }
    private static func crosses(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        let u = b - a, v = d - c, denominator = cross(u, v)
        guard abs(denominator) > 1e-6 else { return false }
        let t = cross(c - a, v) / denominator, s = cross(c - a, u) / denominator
        return t > 1e-5 && t < 1 - 1e-5 && s > 1e-5 && s < 1 - 1e-5
    }
    /// Gap between a rectangle and a segment: zero when they touch, else the nearest of the segment ends and rectangle corners.
    static func distance(_ r: Rect, _ a: Point, _ b: Point) -> Float {
        if r.intersectsLine(a, b) { return 0 }
        func toSegment(_ p: Point) -> Float {
            let u = b - a, l = u.x * u.x + u.y * u.y, t = l == 0 ? 0 : min(max(((p.x - a.x) * u.x + (p.y - a.y) * u.y) / l, 0), 1)
            return (p - (a + u * t)).length
        }
        func toRect(_ p: Point) -> Float { Point(x: max(r.left - p.x, 0, p.x - r.right), y: max(r.top - p.y, 0, p.y - r.bottom)).length }
        return ([toRect(a), toRect(b)] + [Point(x: r.left, y: r.top), Point(x: r.right, y: r.top), Point(x: r.left, y: r.bottom), Point(x: r.right, y: r.bottom)].map(toSegment)).min()!
    }
}

@Suite struct ChannelBspFixTests {
    private func node(_ g: LayoutGraph, _ id: String, _ x: Float, _ y: Float, _ w: Float, _ h: Float) -> LayoutNode {
        let n = LayoutNode(id: id, width: w, height: h); n.x = x; n.y = y; g.addNode(n); return n
    }
    private func fixture(_ name: String) throws -> RoutingFixture { try #require(try loadRoutingFixtures().first { $0.name == name }) }

    @Test func portLinesBeyondABlockedNeighbourhoodStayCandidates() {
        // b's top entry cells are blocked by c (14 above it, less than a grid cell) for the five lines nearest a's centre,
        // so the free lines further along the side must still be offered instead of dropping the side.
        let g = LayoutGraph()
        let a = node(g, "a", 250, 0, 80, 60), b = node(g, "b", 200, 300, 200, 60); _ = node(g, "c", 240, 226, 100, 60)
        let e = LayoutEdge(source: a, target: b); g.addEdge(e)
        let router = ChannelEdgeRouter(); router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty)
        #expect(e.path.last?.y == 300, "enters b through its top side: \(e.path)")
    }

    @Test func channelCrossingsStayLowOnSeededRandomGraphs() {
        var seed: UInt64 = 12345
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        var crossings = 0
        for round in 0..<8 {
            let g = LayoutGraph()
            var nodes: [LayoutNode] = []
            for i in 0..<15 {
                let w = Float(60 + next() % 60), h = Float(30 + next() % 30)
                nodes.append(node(g, "n\(i)", Float(i % 5) * 190 + Float(next() % 50), Float(i / 5) * 150 + Float(next() % 50), w, h))
            }
            for _ in 0..<(18 + round) {
                let s = next() % nodes.count, t = next() % nodes.count
                if s != t { g.addEdge(LayoutEdge(source: nodes[s], target: nodes[t])) }
            }
            let router = ChannelEdgeRouter(); router.routeEdges(g)
            let audit = RouteAudit(g, router)
            #expect(audit.leafHits.isEmpty && audit.fallbacks.isEmpty && audit.diagonal.isEmpty && audit.offBoundary.isEmpty, "round \(round)")
            crossings += audit.crossings
        }
        #expect(crossings <= 270, "\(crossings) crossings") // 299 with five nearest lines and no crossing term, 259 now
    }

    @Test func channelLongDetoursAreNotReportedAsUnroutable() {
        // A wide scene with a long divider leaves a perfectly routable corridor, but its broad equal-cost
        // frontier exceeds a fixed 100,000-pop budget. This must exhaust the finite graph, not a search quota.
        let g = LayoutGraph()
        let a = node(g, "source", 0, 0, 120, 40), b = node(g, "target", 5000, 3000, 120, 40)
        _ = node(g, "divider", 2500, -1000, 80, 6000)
        let edge = LayoutEdge(source: a, target: b); edge.sourcePort = .right; edge.targetPort = .left; g.addEdge(edge)
        let bounds = g.nodes.map(\.bounds)
        let router = ChannelEdgeRouter(); router.gridSize = 8; router.routeEdges(g)
        let audit = RouteAudit(g, router)
        #expect(audit.fallbacks.isEmpty && audit.leafHits.isEmpty && audit.diagonal.isEmpty && audit.offBoundary.isEmpty)
        #expect(g.nodes.map(\.bounds) == bounds)
        let first = edge.path; router.routeEdges(g); #expect(edge.path == first)
    }

    @Test func channelSparseScenesKeepBoundedSearchStorage() {
        // There are millions of possible cells, but only two tiny nodes. Dense arrays must not scale with empty area.
        let g = LayoutGraph(), a = node(g, "a", 0, 0, 40, 40), b = node(g, "b", 100000, 100000, 40, 40)
        let edge = LayoutEdge(source: a, target: b); g.addEdge(edge)
        let router = ChannelEdgeRouter(); router.gridSize = 20; router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty)
        #expect(edge.path.count >= 2 && edge.path.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(RouteAudit(g, router).diagonal.isEmpty)
    }

    @Test(arguments: [0, 2]) func channelExtremeSpansDoNotMaterializeEveryTraversedCell(_ congestion: Int) {
        let g = LayoutGraph(), a = node(g, "a", 0, 0, 40, 40), b = node(g, "b", 1e10, 0, 40, 40)
        let edge = LayoutEdge(source: a, target: b); g.addEdge(edge)
        let bounds = g.nodes.map(\.bounds), router = ChannelEdgeRouter(); router.congestionPenalty = congestion
        router.routeEdges(g)
        if congestion == 0 { #expect(router.unroutableEdges.isEmpty) }
        else { #expect(router.unroutableEdges.count == 1 && router.unroutableEdges.first === edge) }
        #expect(edge.path.count >= 2 && edge.path.count <= 8)
        #expect(edge.path.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(g.nodes.map(\.bounds) == bounds)
        #expect(!zip(edge.path, edge.path.dropFirst()).contains { abs($0.x - $1.x) > 1e-4 && abs($0.y - $1.y) > 1e-4 })
        let first = edge.path; router.routeEdges(g); #expect(edge.path == first)
    }

    @Test func channelHugeObstacleDoesNotRasterizeItsInterior() {
        let g = LayoutGraph(), a = node(g, "a", 0, 0, 40, 40), b = node(g, "b", 400, 0, 40, 40)
        _ = node(g, "huge", 1000, 1000, 1000000, 1000000)
        let edge = LayoutEdge(source: a, target: b); g.addEdge(edge)
        let router = ChannelEdgeRouter(); router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty && RouteAudit(g, router).leafHits.isEmpty)
    }

    @Test func channelZeroCongestionRoutesAroundGroupsDeterministically() {
        let g = LayoutGraph()
        let a = node(g, "a", 0, 0, 80, 40), b = node(g, "b", 800, 0, 80, 40)
        let wall = node(g, "foreign-group", 300, -100, 180, 200); wall.isGroup = true
        for _ in 0..<12 { g.addEdge(LayoutEdge(source: a, target: b)) }
        let bounds = g.nodes.map(\.bounds), router = ChannelEdgeRouter(); router.congestionPenalty = 0; router.gridSize = 8
        router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty)
        let audit = RouteAudit(g, router)
        #expect(audit.diagonal.isEmpty && audit.offBoundary.isEmpty)
        #expect(g.edges.allSatisfy { edge in !zip(edge.path, edge.path.dropFirst()).contains { wall.bounds.inflated(by: -1e-4).intersectsLine($0, $1) } })
        #expect(g.nodes.map(\.bounds) == bounds)
        let first = g.edges.map(\.path); router.routeEdges(g); #expect(g.edges.map(\.path) == first)
    }

    @Test func channelCancelledSearchLeavesExistingRoutesUntouched() {
        let g = LayoutGraph(), a = node(g, "a", 0, 0, 40, 40), b = node(g, "b", 400, 0, 40, 40)
        let edge = LayoutEdge(source: a, target: b); edge.path = [a.center, b.center]; g.addEdge(edge)
        let path = edge.path, cancellation = RoutingCancellation(); cancellation.cancel()
        let router = ChannelEdgeRouter()
        RoutingCompute.$cancellation.withValue(cancellation) { router.routeEdges(g) }
        #expect(edge.path == path && router.unroutableEdges.isEmpty)
    }

    @Test func edgeSpacingDefaultsAgree() {
        #expect(BspEdgeRouter().edgeSpacing == 10)
        for kind in [RoutingKind.bsp, .channel, .orthogonalGrouped, .polyline, .edgeSeparation] { #expect(RoutingConfiguration(kind).edgeSpacing == 10, "\(kind)") }
        #expect(RoutingConfiguration(.orthogonalGrouped).bundleSpacing == 10)
        #expect(RoutingConfiguration(.parallelEdges).edgeSpacing == 20)
    }

    @Test func bspDuplicateEdgesTakeLanesTenApart() {
        let g = LayoutGraph()
        let a = node(g, "a", 0, 0, 60, 60), b = node(g, "b", 400, 0, 60, 60)
        for _ in 0..<2 { g.addEdge(LayoutEdge(source: a, target: b)) }
        BspEdgeRouter().routeEdges(g)
        // The lane is the height of the edge's longest horizontal run.
        func lane(_ e: LayoutEdge) -> Float {
            let runs = zip(e.path, e.path.dropFirst()).filter { abs($0.y - $1.y) < 1e-4 }
            return runs.max { abs($0.0.x - $0.1.x) < abs($1.0.x - $1.1.x) }?.0.y ?? .nan
        }
        #expect(abs(lane(g.edges[0]) - lane(g.edges[1])) >= 10 - 1e-4, "\(g.edges.map(\.path))")
    }

    @Test(arguments: ["bsp-corridors-3", "bsp-corridors-5", "bsp-corridors-10", "bsp-off-grid-wall"])
    func bspSeparationKeepsRoutesRectilinear(_ name: String) throws {
        let f = try fixture(name), graph = f.graph(), router = f.makeRouter()
        router.routeEdges(graph)
        #expect(RouteAudit(graph, router).diagonal.isEmpty)
    }

    @Test func networkSimplexStopsWhenCancelled() {
        // A seeded DAG whose tight-tree ranking (total length 56) the simplex pivots shorten to 48.
        var seed: UInt64 = 19
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        var edges: [(Int, Int)] = []
        for _ in 0..<26 { let a = next() % 14, b = next() % 14; if a < b { edges.append((a, b)) } else if b < a { edges.append((b, a)) } }
        func total(_ r: [Int]) -> Int { edges.reduce(0) { $0 + r[$1.1] - r[$1.0] } }
        let optimal = DirectedLayering.ranks(count: 14, edges: edges)
        let cancellation = RoutingCancellation(); cancellation.cancel()
        let ranks = RoutingCompute.$cancellation.withValue(cancellation) { DirectedLayering.ranks(count: 14, edges: edges) }
        #expect(edges.allSatisfy { ranks[$0.1] - ranks[$0.0] >= 1 }, "still a feasible ranking")
        #expect(total(optimal) == 48 && total(ranks) == 56, "optimal \(total(optimal)), cancelled \(total(ranks))")
    }

    @Test func visibilityGraphConstructionStopsWhenCancelled() {
        let segments = [(start: Point(x: 0, y: 0), end: Point(x: 100, y: 0)), (start: Point(x: 100, y: 0), end: Point(x: 100, y: 100))]
        let cancellation = RoutingCancellation(); cancellation.cancel()
        let cancelled = RoutingCompute.$cancellation.withValue(cancellation) { BspVisibilityGraph(segments) }
        #expect(cancelled.path(from: [.zero], to: [Point(x: 100, y: 100)], bendPenalty: 0) == nil)
        #expect(BspVisibilityGraph(segments).path(from: [.zero], to: [Point(x: 100, y: 100)], bendPenalty: 0) != nil)
    }
}

