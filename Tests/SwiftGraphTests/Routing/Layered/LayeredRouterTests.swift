import Foundation
import Testing

@testable import SwiftGraph

struct LayeredRouterTests {
    /// Three ranks left to right, with a long edge past the middle rank and two edges sharing a corridor.
    private func leftToRight() -> LayoutGraph {
        let g = LayoutGraph()
        let centers = [
            Point(x: 0, y: 0), Point(x: 0, y: 80), Point(x: 160, y: 20), Point(x: 160, y: 100), Point(x: 320, y: 40),
        ]
        for (i, center) in centers.enumerated() {
            let node = LayoutNode(id: "n\(i)", width: 60, height: 30)
            node.center = center
            g.addNode(node)
        }
        for (s, t) in [(0, 2), (1, 2), (0, 3), (2, 4), (3, 4)] {
            g.addEdge(LayoutEdge(source: g.nodes[s], target: g.nodes[t]))
        }
        let long = LayoutEdge(source: g.nodes[1], target: g.nodes[4])
        g.addEdge(long)
        for edge in g.edges { edge.path = [edge.source.center, edge.target.center] }
        long.path = [g.nodes[1].center, Point(x: 160, y: 160), g.nodes[4].center]
        return g
    }

    private func transposed(_ g: LayoutGraph) -> LayoutGraph {
        let t = LayoutGraph()
        for node in g.nodes {
            t.addNode(LayoutNode(id: node.id, width: node.height, height: node.width))
            t.nodes.last?.center = Point(x: node.center.y, y: node.center.x)
        }
        let index = Dictionary(uniqueKeysWithValues: g.nodes.enumerated().map { ($0.element, $0.offset) })
        for edge in g.edges {
            let copy = LayoutEdge(source: t.nodes[index[required: edge.source]], target: t.nodes[index[required: edge.target]])
            copy.path = edge.path.map { Point(x: $0.y, y: $0.x) }
            t.addEdge(copy)
        }
        return t
    }

    @Test(arguments: [false, true])
    func topToBottomFlowRoutesTheTransposedDrawing(_ respacesRanks: Bool) throws {
        let across = leftToRight()
        let down = transposed(across)
        try LayeredRouter.routeDrawing(
            nodes: across.nodes,
            edges: across.edges,
            feedback: [],
            flow: .leftToRight,
            respacesRanks: respacesRanks
        )
        try LayeredRouter.routeDrawing(
            nodes: down.nodes,
            edges: down.edges,
            feedback: [],
            flow: .topToBottom,
            respacesRanks: respacesRanks
        )
        for (a, b) in zip(across.nodes, down.nodes) {
            #expect(b.bounds == Rect(x: a.y, y: a.x, width: a.height, height: a.width))
        }
        for (a, b) in zip(across.edges, down.edges) {
            #expect(!a.path.isEmpty)
            #expect(b.path == a.path.map { Point(x: $0.y, y: $0.x) })
            // Forward edges leave the bottom side and enter the top side.
            #expect(b.path.first?.y == b.source.bounds.bottom && b.path.last?.y == b.target.bounds.top)
        }
    }

    @Test(arguments: [0, 7] as [Float])
    func hierarchicalMovesRanksOnlyAlongTheFlow(_ widthStep: Float) throws {
        func graph() -> LayoutGraph {
            let g = LayoutGraph()
            for i in 0..<8 { g.addNode(LayoutNode(id: "n\(i)", width: 40 + Float(i) * widthStep, height: 20)) }
            // Every top node feeds every bottom node: one crowded gap.
            for s in 0..<4 { for t in 4..<8 { g.addEdge(LayoutEdge(source: g.nodes[s], target: g.nodes[t])) } }
            return g
        }
        let placed = graph()
        let unrouted = HierarchicalLayoutAlgorithm()
        unrouted.routesEdges = false
        try unrouted.applyLayout(placed)
        let routed = graph()
        try HierarchicalLayoutAlgorithm().applyLayout(routed)
        #expect(placed.nodes[4].y - placed.nodes[0].bounds.bottom == 50)
        #expect(routed.nodes[4].y - routed.nodes[0].bounds.bottom >= 50)
        #expect(zip(placed.nodes, routed.nodes).allSatisfy { $0.center.x == $1.center.x })
        #expect(routed.routeStyle == .orthogonal)
        for edge in routed.edges {
            #expect(isRectilinear(edge.path))
            #expect(edge.path.first.map { liesOnOutline($0, edge.source.bounds) } == true)
            #expect(edge.path.last.map { liesOnOutline($0, edge.target.bounds) } == true)
        }
        let score = try DirectedGeometry.measure(nodes: routed.nodes, edges: routed.edges)
        #expect(score.shared == 0 && score.missing == 0)
    }
}
