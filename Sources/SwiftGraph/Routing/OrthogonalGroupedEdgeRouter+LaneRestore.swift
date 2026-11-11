import Foundation

extension OrthogonalGroupedEdgeRouter {
    /// `EdgeSeparator` only rejects a lane shift that enters a node, so in a corridor narrower than its lanes a shift
    /// can land a route exactly on a node's outline. Such an edge goes back to its merged route, which the channels
    /// kept `obstacleMargin` clear; a lane-mate that would now cross it goes back too, so the bundle stays merged
    /// rather than tangled. Moving nodes aside (`movesNodesToWidenCorridors`) avoids most of these cases.
    func restoreLanesTouchingNodes(_ graph: LayoutGraph, edges: [LayoutEdge], merged: [[Point]]) {
        let leaves = graph.nodes.filter { !$0.isGroup }
        guard !leaves.isEmpty else { return }
        let tree = QuadTree<LayoutNode>(bounds: enclosingBounds(leaves).inflated(by: 100))
        for leaf in leaves { tree.insert(bounds: leaf.bounds, item: leaf) }

        var restored: [Int] = []
        for (index, edge) in edges.enumerated() where edge.path != merged[index] {
            let before = Self.touchedNodes(merged[index], edge, tree)
            guard !Self.touchedNodes(edge.path, edge, tree).isSubset(of: before) else { continue }
            edge.path = merged[index]
            restored.append(index)
        }
        while let index = restored.popLast() {
            for (other, edge) in edges.enumerated() where edge.path != merged[other] {
                let before = Self.properCrossings(merged[other], merged[index])
                guard Self.properCrossings(edge.path, merged[index]) > before else { continue }
                edge.path = merged[other]
                restored.append(other)
            }
        }
    }

    /// Leaves other than the edge's own endpoints that the path meets, boundary contact included.
    private static func touchedNodes(
        _ path: [Point],
        _ edge: LayoutEdge,
        _ tree: QuadTree<LayoutNode>
    ) -> Set<LayoutNode> {
        var result = Set<LayoutNode>()
        for (a, b) in zip(path, path.dropFirst()) {
            let box = Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            // `Rect.intersects` is open, so a zero-width segment box needs inflating to find the nodes it touches.
            tree.forEach(intersecting: box.inflated(by: 1)) { bounds, node in
                guard node !== edge.source, node !== edge.target, bounds.intersectsLine(a, b) else { return }
                result.insert(node)
            }
        }
        return result
    }

    private static func properCrossings(_ p: [Point], _ q: [Point]) -> Int {
        func side(_ a: Point, _ b: Point, _ c: Point) -> Float { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        func proper(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
            side(a, b, c) * side(a, b, d) < 0 && side(c, d, a) * side(c, d, b) < 0
        }
        var count = 0
        for (a, b) in zip(p, p.dropFirst()) {
            count += zip(q, q.dropFirst()).filter { proper(a, b, $0.0, $0.1) }.count
        }
        return count
    }
}
