import Foundation
import SwiftGraph

enum VisualGraphs {
    static func graph(_ count: Int = 12, shape: String = "dag") -> LayoutGraph {
        let g = LayoutGraph()
        for i in 0..<count {
            let n = LayoutNode(id: "n\(i)", width: 80 + Float(i % 4) * 25, height: 32 + Float(i % 3) * 8)
            n.x = Float(i % 4) * 220 - 120
            n.y = Float(i / 4) * 150 - 80
            g.addNode(n)
        }
        guard count > 1 else { return g }
        for i in 1..<count {
            if shape == "disconnected" && i % 4 == 0 { continue }
            let parent = shape == "star" ? 0 : (shape == "tree" ? (i - 1) / 2 : i - 1)
            g.addEdge(LayoutEdge(source: g.nodes[parent], target: g.nodes[i]))
            if (shape == "dag" || shape == "dense") && i > 3 {
                g.addEdge(LayoutEdge(source: g.nodes[i - 3], target: g.nodes[i]))
            }
            if shape == "dense" && i > 5 { g.addEdge(LayoutEdge(source: g.nodes[i - 5], target: g.nodes[i])) }
        }
        if shape == "cyclic" {
            for (a, b) in [(count - 1, 0), (0, 1), (1, 0), (0, 0)] {
                g.addEdge(LayoutEdge(source: g.nodes[a], target: g.nodes[b]))
            }
        }
        return g
    }

    static func groups(edges: Bool = true) -> LayoutGraph {
        let g = graph(8, shape: "tree")
        if !edges { g.edges = [] }
        let outer = LayoutNode(id: "group-a", width: 600, height: 400)
        outer.isGroup = true
        let inner = LayoutNode(id: "group-b", width: 300, height: 200)
        inner.isGroup = true
        for n in g.nodes.prefix(4) {
            g.root.children.removeAll { $0 === n }
            n.parent = inner
            inner.children.append(n)
        }
        inner.parent = outer
        outer.children.append(inner)
        g.addNode(outer)
        g.addNode(inner)
        return g
    }

    static func obstacle() -> LayoutGraph {
        let g = LayoutGraph()
        for (id, rect) in [
            ("source", Rect(x: -180, y: 60, width: 110, height: 50)),
            ("target", Rect(x: 420, y: 60, width: 110, height: 50)),
            ("wall", Rect(x: 120, y: 0, width: 80, height: 180)),
        ] {
            let n = LayoutNode(id: id, width: rect.width, height: rect.height)
            n.bounds = rect
            g.addNode(n)
        }
        for _ in 0..<2 {
            let e = LayoutEdge(source: g.nodes[0], target: g.nodes[1])
            e.sourcePort = .right
            e.targetPortCandidates = [.left, .top]
            e.path = [e.source.center, e.target.center]
            g.addEdge(e)
        }
        let reverse = LayoutEdge(source: g.nodes[1], target: g.nodes[0])
        reverse.path = [reverse.source.center, reverse.target.center]
        g.addEdge(reverse)
        g.addEdge(LayoutEdge(source: g.nodes[0], target: g.nodes[0]))
        SelfLoopRouter().routeEdges(g)
        return g
    }

    static func routing(_ name: String) throws -> LayoutGraph {
        if name == "curve-fitting" {
            let g = graph(8)
            try HierarchicalLayoutAlgorithm().applyLayout(g)
            return g
        }
        if name == "octilinear" {
            let g = graph(8, shape: "tree")
            try CircularLayoutAlgorithm().applyLayout(g)
            return g
        }
        if name == "bundling" || name == "bus" {
            let g = graph(12)
            g.edges = []
            for (i, n) in g.nodes.enumerated() {
                n.x = i < 6 ? 0 : 720
                n.y = Float(i % 6) * 110
            }
            for i in 0..<6 {
                let pairs = name == "bus" ? [(0, i + 6), (i, 11)] : [(i, i + 6), (i, (i + 1) % 6 + 6)]
                for (s, t) in pairs {
                    let e = LayoutEdge(source: g.nodes[s], target: g.nodes[t])
                    e.path = [e.source.center, e.target.center]
                    g.addEdge(e)
                }
            }
            return g
        }
        return obstacle()
    }

    static func finish(_ g: LayoutGraph, route: Bool = false) {
        if route { PolylineEdgeRouter().routeEdges(g) }
        SelfLoopRouter().routeEdges(g)
        EdgeEndpointClipper.clipToNodeBounds(g)
    }
}
