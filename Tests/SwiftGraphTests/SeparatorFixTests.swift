import Foundation
import Testing
@testable import SwiftGraph

@Suite struct SeparatorFixTests {
    private struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s ^ (s >> 29) }
    }
    private static func crosses(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        func x(_ p: Point, _ q: Point) -> Double { p.x * q.y - p.y * q.x }
        let u = b - a, v = d - c, den = x(u, v)
        guard abs(den) > 1e-9 * u.length * v.length else { return false }
        let t = x(c - a, v) / den, s = x(c - a, u) / den
        return t > 1e-9 && t < 1 - 1e-9 && s > 1e-9 && s < 1 - 1e-9
    }
    private static func crossings(_ p: [Point], _ q: [Point]) -> Int {
        zip(p, p.dropFirst()).reduce(0) { n, a in n + zip(q, q.dropFirst()).filter { crosses(a.0, a.1, $0, $1) }.count }
    }
    private static func selfCrossings(_ path: [Point]) -> Int {
        let segments = Array(zip(path, path.dropFirst()))
        var n = 0
        for i in segments.indices { for j in (i + 2)..<max(i + 2, segments.count) where crosses(segments[i].0, segments[i].1, segments[j].0, segments[j].1) { n += 1 } }
        return n
    }
    /// Vertices that turn back on themselves by more than 150 degrees.
    private static func reversals(_ path: [Point]) -> Int {
        (1..<max(1, path.count - 1)).filter { k in
            let u = path[k] - path[k - 1], v = path[k + 1] - path[k]
            return u.x * v.x + u.y * v.y < -0.866 * u.length * v.length
        }.count
    }
    private static func distance(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let u = b - a, l2 = u.x * u.x + u.y * u.y
        let t = l2 > 1e-12 ? min(1, max(0, ((p - a).x * u.x + (p - a).y * u.y) / l2)) : 0
        return (p - (a + u * t)).length
    }

    struct Report {
        var selfCrossingEdges = 0, newSelfCrossing = 0, reversals = 0, newReversals = 0
        var pairCrossings = 0, newPairCrossings = 0, maxDisplacement = 0.0, newNodeHits = 0, widestGroup = 0, unseparated = 0
    }

    /// Routes a seeded random graph with reciprocal pairs, separates it, and compares every edge with its raw route.
    private static func stress(_ n: Int, _ m: Int, seed: UInt64, orgChart: Bool) async throws -> Report {
        var rng = RNG(s: seed)
        let g = LayoutGraph()
        let nodes = (0..<n).map { i in LayoutNode(id: "n\(i)", width: Double(Int.random(in: 30...120, using: &rng)), height: Double(Int.random(in: 20...60, using: &rng))) }
        nodes.forEach(g.addNode)
        for _ in 0..<m { g.addEdge(LayoutEdge(source: nodes[Int.random(in: 0..<n, using: &rng)], target: nodes[Int.random(in: 0..<n, using: &rng)])) }
        for _ in 0..<(m / 10) {
            let a = nodes[Int.random(in: 0..<n, using: &rng)], b = nodes[Int.random(in: 0..<n, using: &rng)]
            g.addEdge(LayoutEdge(source: a, target: b)); g.addEdge(LayoutEdge(source: b, target: a))
        }
        if orgChart { try await LayoutBuilder.create(g).useOrgChart { $0.siblingDistance = 40; $0.layerDistance = 80 }.applyAsync() }
        else {
            let cols = Int(Double(n).squareRoot().rounded(.up))
            for (i, node) in nodes.enumerated() { node.x = Double(i % cols) * 150 + Double(Int.random(in: 0..<40, using: &rng)); node.y = Double(i / cols) * 110 + Double(Int.random(in: 0..<40, using: &rng)) }
        }
        let router = PolylineEdgeRouter(); router.edgeSpacing = 0; router.routeEdges(g)
        let raw = g.edges.map(\.path)
        let separator = EdgeSeparator(); separator.spacing = 10; separator.routeEdges(g)
        var r = Report(); r.widestGroup = separator.widestGroup; r.unseparated = separator.unseparatedEdges.count
        func hits(_ e: LayoutEdge, _ path: [Point]) -> Set<Int> {
            Set(g.nodes.indices.filter { j in
                let node = g.nodes[j]
                return node !== e.source && node !== e.target && !node.isGroup && zip(path, path.dropFirst()).contains { node.bounds.inflated(by: -1).intersectsLine($0, $1) }
            })
        }
        for (i, e) in g.edges.enumerated() where e.path.count >= 2 && raw[i].count >= 2 && e.source !== e.target {
            let s0 = selfCrossings(raw[i]), s1 = selfCrossings(e.path)
            if s1 > 0 { r.selfCrossingEdges += 1 }
            if s1 > 0 && s0 == 0 { r.newSelfCrossing += 1 }
            let u0 = reversals(raw[i]), u1 = reversals(e.path)
            r.reversals += u1; r.newReversals += max(0, u1 - u0)
            for p in e.path { r.maxDisplacement = max(r.maxDisplacement, zip(raw[i], raw[i].dropFirst()).map { distance(p, $0, $1) }.min()!) }
            r.newNodeHits += hits(e, e.path).subtracting(hits(e, raw[i])).count
        }
        var byPair: [Set<String>: [Int]] = [:]
        for (i, e) in g.edges.enumerated() where e.source !== e.target && e.path.count >= 2 { byPair[Set([e.source.id, e.target.id]), default: []].append(i) }
        for list in byPair.values where list.count > 1 {
            for a in list.indices { for b in list.indices where b > a {
                let after = crossings(g.edges[list[a]].path, g.edges[list[b]].path), before = crossings(raw[list[a]], raw[list[b]])
                r.pairCrossings += after; r.newPairCrossings += max(0, after - before)
            } }
        }
        return r
    }

    private func graph(_ paths: [[Point]]) -> LayoutGraph {
        let g = LayoutGraph()
        var nodes: [Point: LayoutNode] = [:]
        func node(_ p: Point) -> LayoutNode {
            if let n = nodes[p] { return n }
            let n = LayoutNode(id: "n\(nodes.count)", width: 4, height: 4); n.bounds = Rect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)
            nodes[p] = n; g.addNode(n); return n
        }
        for path in paths { let e = LayoutEdge(source: node(path[0]), target: node(path[path.count - 1])); e.path = path; g.addEdge(e) }
        return g
    }

    @Test func shortBendNextToSharedRunDoesNotSpike() {
        // The first run is shared and moves a lane; the second is a short, shallow continuation that stays put.
        // The unclamped mitre of the two shifted lines lands past the end of the short run and doubles back.
        for sign in [1.0, -1.0] { for swapped in [false, true] {
            var paths = [[Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 110, y: 3 * sign)], [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 50)]]
            if swapped { paths.reverse() }
            let g = graph(paths), before = g.edges.map(\.path)
            let separator = EdgeSeparator(); separator.routeEdges(g)
            for (e, old) in zip(g.edges, before) {
                #expect(Self.reversals(e.path) <= Self.reversals(old) && Self.selfCrossings(e.path) == 0, "sign \(sign) swapped \(swapped): \(e.path)")
                #expect(e.path.allSatisfy { p in zip(old, old.dropFirst()).map { Self.distance(p, $0, $1) }.min()! <= 10 }, "sign \(sign) swapped \(swapped): \(e.path)")
            }
        } }
    }

    @Test func runsApartAlongALineShareALane() {
        // Two short edges in line with a long one: only the long one needs its own lane.
        let g = graph([[Point(x: 0, y: 0), Point(x: 100, y: 0)], [Point(x: 200, y: 0), Point(x: 300, y: 0)], [Point(x: 0, y: 0.5), Point(x: 300, y: 0.5)]])
        let separator = EdgeSeparator(); separator.routeEdges(g)
        let ys = g.edges.map { $0.path[0].y }
        #expect(separator.widestGroup == 2 && separator.unseparatedEdges.isEmpty)
        #expect(abs(ys[0] - ys[1]) < 1e-9 && abs(ys[0] - ys[2]) >= 1, "\(ys)")
    }

    @Test(arguments: [(40, 120, true, 2), (40, 120, false, 2), (80, 300, true, 1), (80, 300, false, 1)])
    func separationNeverCorruptsRoutes(_ n: Int, _ m: Int, _ orgChart: Bool, _ seeds: Int) async throws {
        for seed in 1...seeds {
            let r = try await Self.stress(n, m, seed: UInt64(seed), orgChart: orgChart)
            let label = "\(n)/\(m) \(orgChart ? "org" : "grid") seed \(seed): \(r)"
            #expect(r.newSelfCrossing == 0 && r.newReversals == 0 && r.newPairCrossings == 0 && r.newNodeHits == 0, "\(label)")
            #expect(r.maxDisplacement <= Double(r.widestGroup) * 10, "\(label)")
        }
    }
}
