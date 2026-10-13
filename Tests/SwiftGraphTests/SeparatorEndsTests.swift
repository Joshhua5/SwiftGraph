import Foundation
import Testing
@testable import SwiftGraph

/// Lane shifts must keep rectilinear routes rectilinear, keep lane ends on their node faces clear of the corners, and not be
/// rejected by the separator's own post-check for reasons the separator caused.
@Suite struct SeparatorEndsTests {
    private static func node(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LayoutNode {
        let n = LayoutNode(id: id, width: w, height: h); n.bounds = Rect(x: x, y: y, width: w, height: h); return n
    }
    private static func edge(_ a: LayoutNode, _ b: LayoutNode, _ path: [(Double, Double)]) -> LayoutEdge {
        let e = LayoutEdge(source: a, target: b); e.path = path.map { Point(x: $0.0, y: $0.1) }; return e
    }
    private static func graph(_ nodes: [LayoutNode], _ edges: [LayoutEdge]) -> LayoutGraph {
        let g = LayoutGraph(); nodes.forEach(g.addNode); edges.forEach(g.addEdge); return g
    }
    private static func rectilinear(_ path: [Point]) -> Bool { zip(path, path.dropFirst()).allSatisfy { abs($0.x - $1.x) < 1e-6 || abs($0.y - $1.y) < 1e-6 } }
    private static func crossings(_ p: [Point], _ q: [Point]) -> Int {
        var n = 0
        for (a, b) in zip(p, p.dropFirst()) { for (c, d) in zip(q, q.dropFirst()) {
            let u = b - a, v = d - c, den = u.x * v.y - u.y * v.x
            guard abs(den) > 1e-9 else { continue }
            let t = ((c - a).x * v.y - (c - a).y * v.x) / den, s = ((c - a).x * u.y - (c - a).y * u.x) / den
            if t > 1e-9 && t < 1 - 1e-9 && s > 1e-9 && s < 1 - 1e-9 { n += 1 }
        } }
        return n
    }

    @Test func rightAngleBendsKeepTheirCornerNextToAShortLeg() {
        // The vertical leg between the two long runs is shorter than the lane shifts, so a mitre clamped to half the leg would
        // average the shifts and leave a diagonal.
        let a = Self.node("a", 0, 40, 41, 60), b = Self.node("b", 217, 180, 60, 40)
        let forward = [(41.0, 65.0), (89, 65), (89, 180), (195.5, 180), (195.5, 196.25), (217, 196.25)]
        let g = Self.graph([a, b], [Self.edge(a, b, forward), Self.edge(a, b, forward), Self.edge(b, a, forward.reversed())])
        let separator = EdgeSeparator(); separator.spacing = 10; separator.routeEdges(g)
        for e in g.edges { #expect(Self.rectilinear(e.path), "\(e.path)") }
        #expect(separator.unseparatedEdges.isEmpty)
        for i in g.edges.indices { for j in g.edges.indices where j > i { #expect(Self.crossings(g.edges[i].path, g.edges[j].path) == 0) } }
    }

    @Test func laneEndsStayOnASmallFaceClearOfItsCorners() {
        // Three lanes at spacing 12 do not fit a 20-high face; the fan narrows instead of clamping onto the corners.
        let a = Self.node("a", 0, 0, 40, 20), b = Self.node("b", 200, 80, 40, 40)
        let path = [(40.0, 10.0), (100, 10), (100, 100), (200, 100)]
        let g = Self.graph([a, b], (0..<3).map { _ in Self.edge(a, b, path) })
        let separator = EdgeSeparator(); separator.spacing = 12; separator.routeEdges(g)
        let ys = g.edges.map { $0.path[0].y }.sorted()
        for e in g.edges {
            #expect(Self.rectilinear(e.path), "\(e.path)")
            #expect(e.path[0].x == 40 && e.path[0].y >= 5 - 1e-9 && e.path[0].y <= 15 + 1e-9, "start \(e.path[0])")
            #expect(e.path.last!.x == 200 && e.path.last!.y >= 86 - 1e-9 && e.path.last!.y <= 114 + 1e-9, "end \(e.path.last!)")
        }
        #expect(ys[1] - ys[0] >= 3 && ys[2] - ys[1] >= 3, "\(ys)")
        #expect(separator.unseparatedEdges.isEmpty)
    }

    @Test func reciprocalRoutesOfDifferentLengthKeepOneLaneOrderAroundTheirCorners() {
        // Both routes share the left and bottom runs, but one turns up before the other ends: the shorter one is on the inside
        // of every corner, so the lanes must not swap between the vertical and the horizontal run.
        let a = Self.node("a", 0, 0, 40, 40), b = Self.node("b", 260, 0, 60, 40)
        let out = [(40.0, 20.0), (70, 20), (70, 80), (220, 80), (220, 20), (260, 20)]
        let back = [(270.0, 40.0), (270, 80), (70, 80), (70, 20), (40, 20)]
        let g = Self.graph([a, b], [Self.edge(a, b, out), Self.edge(b, a, back)])
        let separator = EdgeSeparator(); separator.spacing = 10; separator.routeEdges(g)
        #expect(separator.unseparatedEdges.isEmpty)
        #expect(Self.crossings(g.edges[0].path, g.edges[1].path) == 0)
        for e in g.edges { #expect(Self.rectilinear(e.path), "\(e.path)") }
    }

    @Test func aTwinThatIsAlsoBeingShiftedDoesNotBlockALane() {
        // The reverse edge moves out of the way of the pair too, so judging the pair against its old route rejects a lane
        // that is fine once everything has moved.
        let a = Self.node("a", -180, 60, 110, 50), b = Self.node("b", 420, 60, 110, 50), wall = Self.node("wall", 130, 0, 80, 180)
        let path = [(-70.0, 85.0), (110, 85), (110, -10), (475, -10), (475, 60)]
        let back = [(475.0, 60.0), (475, -10), (-125, -10), (-125, 60)]
        let g = Self.graph([a, b, wall], [Self.edge(a, b, path), Self.edge(a, b, path), Self.edge(b, a, back)])
        let separator = EdgeSeparator(); separator.spacing = 10; separator.routeEdges(g)
        #expect(separator.unseparatedEdges.isEmpty, "\(separator.unseparatedEdges.count) unseparated")
        for i in g.edges.indices {
            #expect(Self.rectilinear(g.edges[i].path), "\(g.edges[i].path)")
            for j in g.edges.indices where j > i { #expect(Self.crossings(g.edges[i].path, g.edges[j].path) == 0) }
        }
        let runs = g.edges.map { $0.path.first { $0.y < 0 }!.y }
        #expect(Set(runs.map { ($0 * 100).rounded() }).count == 3, "top runs \(runs)")
    }
}
