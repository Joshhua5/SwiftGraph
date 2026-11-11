import Foundation
import Testing

@testable import SwiftGraph

@Suite struct CorridorProbeTests {
    static func denseGrid(columns: Int, rows: Int, edges: Int, seed: UInt64 = 7) -> LayoutGraph {
        let graph = LayoutGraph()
        for r in 0..<rows {
            for c in 0..<columns {
                let node = LayoutNode(id: "\(r)-\(c)", width: 80, height: 32)
                node.center = Point(x: Float(c) * 120, y: Float(r) * 80)
                graph.addNode(node)
            }
        }
        var state = seed
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33)
        }
        let count = graph.nodes.count
        while graph.edges.count < edges {
            let a = next() % count
            let b = next() % count
            if a != b { graph.addEdge(LayoutEdge(source: graph.nodes[a], target: graph.nodes[b])) }
        }
        return graph
    }

    /// Parallel stretches of different edges that overlap along their line: how many coincide, the closest
    /// distinct pair, and how many sit closer than 3 pt.
    static func lanes(_ graph: LayoutGraph) -> (merged: Int, closest: Float, under3: Int) {
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
        var under3 = 0
        for i in segments.indices {
            var j = i + 1
            while j < segments.count, segments[j].at - segments[i].at < 10 {
                let s = segments[i]
                let t = segments[j]
                j += 1
                guard s.edge != t.edge, s.vertical == t.vertical, min(s.high, t.high) - max(s.low, t.low) > 1
                else { continue }
                let d = t.at - s.at
                if d < 0.5 {
                    merged += 1
                } else {
                    closest = min(closest, d)
                    if d < 3 { under3 += 1 }
                }
            }
        }
        return (merged, closest, under3)
    }

    @Test(arguments: [100, 200, 300])
    func probe(_ edges: Int) {
        guard ProcessInfo.processInfo.environment["SWIFTGRAPH_PROBE"] != nil else { return }
        for name in ["bsp", "grouped"] {
            let graph = Self.denseGrid(columns: 8, rows: 8, edges: edges)
            let router: any EdgeRouter = name == "bsp" ? BspEdgeRouter() : OrthogonalGroupedEdgeRouter()
            let start = ContinuousClock.now
            router.routeEdges(graph)
            let elapsed = start.duration(to: .now)
            let lanes = Self.lanes(graph)
            let audit = RouteAudit(graph, router)
            print(
                "PROBE \(name) edges=\(edges) time=\(elapsed) merged=\(lanes.merged) closest=\(lanes.closest) "
                    + "under3=\(lanes.under3) crossings=\(audit.crossings) bends=\(audit.bends) "
                    + "hits=\(audit.leafHits.count) clearance=\(audit.minClearance) "
                    + "unsep=\(router.report.unseparated.count) unroutable=\(router.report.unroutable.count) "
                    + "length=\(graph.edges.map { ObstaclePolyline.length($0.path) }.reduce(0, +))"
            )
        }
    }
}
