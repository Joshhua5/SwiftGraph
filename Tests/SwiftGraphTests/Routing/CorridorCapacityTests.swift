import Foundation
import Testing

@testable import SwiftGraph

/// Corridor capacity during the BSP and grouped searches, and track assignment after them (review C-1, C-7).
@Suite struct CorridorCapacityTests {
    // MARK: - Fixtures

    /// An 8 × 8 grid of 80 × 32 nodes with 40 pt column gaps and 48 pt row gaps, and `edges` deterministic random edges.
    static func denseGrid(edges: Int, seed: UInt64 = 7) -> LayoutGraph {
        let graph = LayoutGraph()
        for row in 0..<8 {
            for column in 0..<8 {
                let node = LayoutNode(id: "\(row)-\(column)", width: 80, height: 32)
                node.center = Point(x: Float(column) * 120, y: Float(row) * 80)
                graph.addNode(node)
            }
        }
        var state = seed
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33)
        }
        while graph.edges.count < edges {
            let a = next() % graph.nodes.count
            let b = next() % graph.nodes.count
            if a != b { graph.addEdge(LayoutEdge(source: graph.nodes[a], target: graph.nodes[b])) }
        }
        return graph
    }

    /// Parallel stretches of different edges that overlap along their line by more than a point: how many coincide
    /// and the closest distinct pair.
    static func lanes(_ graph: LayoutGraph) -> (merged: Int, closest: Float) {
        var segments: [(edge: Int, vertical: Bool, at: Float, low: Float, high: Float)] = []
        for (e, edge) in graph.edges.enumerated() where edge.source !== edge.target {
            for (a, b) in zip(edge.path, edge.path.dropFirst()) {
                if abs(a.x - b.x) < 1e-3, abs(a.y - b.y) > 1e-3 {
                    segments.append((e, true, a.x, min(a.y, b.y), max(a.y, b.y)))
                } else if abs(a.y - b.y) < 1e-3, abs(a.x - b.x) > 1e-3 {
                    segments.append((e, false, a.y, min(a.x, b.x), max(a.x, b.x)))
                }
            }
        }
        segments.sort { $0.at < $1.at }
        var merged = 0
        var closest = Float.infinity
        for i in segments.indices {
            for t in segments[(i + 1)...] {
                let s = segments[i]
                guard t.at - s.at < 10 else { break }
                guard s.edge != t.edge, s.vertical == t.vertical, min(s.high, t.high) - max(s.low, t.low) > 1 else {
                    continue
                }
                if t.at - s.at < 0.5 { merged += 1 } else { closest = min(closest, t.at - s.at) }
            }
        }
        return (merged, closest)
    }

    static func properCrossings(_ p: [Point], _ q: [Point]) -> Int {
        func side(_ a: Point, _ b: Point, _ c: Point) -> Float { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        var count = 0
        for (a, b) in zip(p, p.dropFirst()) {
            for (c, d) in zip(q, q.dropFirst())
            where side(a, b, c) * side(a, b, d) < -1e-5 && side(c, d, a) * side(c, d, b) < -1e-5 {
                count += 1
            }
        }
        return count
    }

    // MARK: - Track allocation

    @Test func armsHeadingTheSameWayNestTheShorterRunInside() throws {
        // Both runs turn back towards the low tracks at each end. The short run's arms land inside the long run, so
        // it must take the lower track for its arms to stay clear of the long run.
        let allocation = try TrackAllocation.solve(
            [
                TrackSegment(id: 0, source: 0, target: 100, sourceSide: .low, targetSide: .low),
                TrackSegment(id: 1, source: 30, target: 70, sourceSide: .low, targetSide: .low),
            ],
            clearance: 10
        )
        #expect(allocation.count == 2)
        #expect(allocation.slots[1] == 0 && allocation.slots[0] == 1)
    }

    @Test func runEndingInANodeHasNoArmAtThatEnd() throws {
        // Run 0 ends in a node at 50 (no arm); run 1 leaves towards the high side at 50, inside run 0's extent.
        // Only the order with run 1 above run 0 keeps that arm from crossing run 0.
        let allocation = try TrackAllocation.solve(
            [
                TrackSegment(id: 0, source: 0, target: 100, sourceSide: nil, targetSide: nil),
                TrackSegment(id: 1, source: 50, target: 200, sourceSide: .high, targetSide: .high),
            ],
            clearance: 10
        )
        #expect(allocation.slots[0] == 0 && allocation.slots[1] == 1)
    }

    // MARK: - Dense corridors

    /// Before corridor capacity, the 100-edge grid left BSP lanes 2.5 pt apart (25 pairs under 3 pt) and grouped
    /// lanes 0.86 pt apart with 15 stretches still merged.
    @Test(arguments: ["bsp", "grouped"])
    func denseCorridorsKeepLanesApart(_ name: String) {
        let graph = Self.denseGrid(edges: 100)
        let router: any EdgeRouter = name == "bsp" ? BspEdgeRouter() : OrthogonalGroupedEdgeRouter()
        router.routeEdges(graph)
        let lanes = Self.lanes(graph)
        #expect(lanes.merged <= 1, "\(name): \(lanes.merged) merged stretches")
        #expect(lanes.closest >= 3, "\(name): lanes \(lanes.closest) pt apart")
        #expect(router.report.unroutable.isEmpty)
        let audit = RouteAudit(graph, router)
        #expect(audit.leafHits.isEmpty, "\(name): \(audit.leafHits)")
        #expect(audit.diagonal.isEmpty)
    }

    @Test func aFullGapSendsLaterEdgesToTheNeighbouringGap() {
        // Three 400 pt wide blocks leave two 40 pt gaps, at y 0...40 and 240...280. Twelve edges from left to right
        // all prefer the upper gap, which holds three tracks. With capacity, some take the lower gap.
        let graph = LayoutGraph()
        func node(_ id: String, _ x: Float, _ y: Float, _ width: Float, _ height: Float) -> LayoutNode {
            let n = LayoutNode(id: id, width: width, height: height)
            n.center = Point(x: x, y: y)
            graph.addNode(n)
            return n
        }
        _ = node("top", 300, -100, 400, 200)
        _ = node("middle", 300, 140, 400, 200)
        _ = node("bottom", 300, 380, 400, 200)
        let sources = (0..<12).map { node("s\($0)", -40, Float($0) * 18 - 80, 40, 12) }
        let targets = (0..<12).map { node("t\($0)", 640, Float($0) * 18 - 80, 40, 12) }
        for (s, t) in zip(sources, targets) {
            let edge = LayoutEdge(source: s, target: t)
            edge.sourcePort = .right
            edge.targetPort = .left
            graph.addEdge(edge)
        }
        let router = BspEdgeRouter()
        router.routeEdges(graph)
        let crossingX: Float = 300
        func through(_ edge: LayoutEdge) -> Float? {
            for (a, b) in zip(edge.path, edge.path.dropFirst()) where min(a.x, b.x) < crossingX && max(a.x, b.x) > crossingX {
                return a.y
            }
            return nil
        }
        let ys = graph.edges.compactMap(through)
        #expect(ys.count == 12)
        #expect(ys.contains { $0 > 100 }, "every edge squeezed through the upper gap: \(ys.sorted())")
        let upper = ys.filter { $0 < 100 }.sorted()
        #expect(zip(upper, upper.dropFirst()).allSatisfy { $1 - $0 >= 3 }, "\(upper)")
    }

    // MARK: - Crossings with unrelated edges (C-7)

    /// Tracks are assigned to the merged routes of the dense grid. An edge's crossings with the edges it shares no
    /// stretch with must not rise, whereas lanes within a shared corridor may reorder.
    @Test(arguments: [60, 100])
    func tracksAddNoCrossingsWithUnrelatedEdges(_ count: Int) {
        let graph = Self.denseGrid(edges: count)
        let router = BspEdgeRouter()
        router.edgeSpacing = 0
        router.routeEdges(graph)
        let merged = graph.edges.map(\.path)
        let tracks = CorridorTracks(spacing: 10, clearance: 10, walls: CorridorWalls(graph.nodes, reach: 160))
        _ = tracks.assign(graph.edges, scene: ObstaclePolyline.Scene(graph.nodes))
        func near(_ p: [Point], _ q: [Point]) -> Bool {
            for (a, b) in zip(p, p.dropFirst()) {
                for (c, d) in zip(q, q.dropFirst()) {
                    let vertical = abs(a.x - b.x) < 1e-3
                    guard vertical == (abs(c.x - d.x) < 1e-3) else { continue }
                    let (at, other) = vertical ? (a.x, c.x) : (a.y, c.y)
                    let (l1, h1) = vertical ? (min(a.y, b.y), max(a.y, b.y)) : (min(a.x, b.x), max(a.x, b.x))
                    let (l2, h2) = vertical ? (min(c.y, d.y), max(c.y, d.y)) : (min(c.x, d.x), max(c.x, d.x))
                    if abs(at - other) < 50,min(h1, h2) - max(l1, l2) > -10 { return true }
                }
            }
            return false
        }
        var risen: [Int] = []
        for e in graph.edges.indices {
            var before = 0
            var after = 0
            for f in graph.edges.indices where f != e && !near(merged[e], merged[f]) {
                before += Self.properCrossings(merged[e], merged[f])
                after += Self.properCrossings(graph.edges[e].path, graph.edges[f].path)
            }
            if after > before { risen.append(e) }
        }
        #expect(risen.isEmpty, "edges crossing more unrelated edges: \(risen)")
    }
}
