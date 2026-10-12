import Foundation

/// The reference's two-corner detour around the first intersected obstacle.
/// This style router does not enforce port constraints or solve multi-obstacle pathfinding.
public final class PolylineEdgeRouter: EdgeRouter {
    public var padding: Double = 10
    /// Retained for API compatibility. This heuristic always emits a path.
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init() {}
    public func routeEdges(_ graph: LayoutGraph) {
        unroutableEdges = []
        guard !graph.nodes.isEmpty else { return }
        let tree = QuadTree<LayoutNode>(bounds: enclosingBounds(graph.nodes).inflated(by: 500))
        for node in graph.nodes { tree.insert(bounds: node.bounds, item: node) }
        for edge in graph.edges where edge.source !== edge.target {
            if Task.isCancelled { return }
            let start = edge.source.center, end = edge.target.center
            let area = Rect(x: min(start.x, end.x) - padding, y: min(start.y, end.y) - padding, width: abs(start.x - end.x) + padding * 2, height: abs(start.y - end.y) + padding * 2)
            var candidates: [LayoutNode] = []
            tree.query(area, results: &candidates)
            let obstacle = candidates.first { node in
                node !== edge.source && node !== edge.target && !(node.isGroup && (isAncestor(node, of: edge.source) || isAncestor(node, of: edge.target))) && node.bounds.intersectsLine(start, end)
            }
            edge.path = [start]
            if let obstacle { edge.path += detour(start, end, obstacle.bounds) }
            edge.path.append(end)
        }
    }
    private func detour(_ start: Point, _ end: Point, _ bounds: Rect) -> [Point] {
        let horizontal = abs(end.x - start.x) > abs(end.y - start.y)
        let mid = (start + end) / 2
        let primarySide = horizontal ? mid.y < bounds.center.y : mid.x < bounds.center.x
        func build(_ before: Bool) -> [Point] {
            if horizontal {
                let y = before ? bounds.top - padding : bounds.bottom + padding
                return [Point(x: bounds.left - padding, y: y), Point(x: bounds.right + padding, y: y)]
            }
            let x = before ? bounds.left - padding : bounds.right + padding
            return [Point(x: x, y: bounds.top - padding), Point(x: x, y: bounds.bottom + padding)]
        }
        func crosses(_ points: [Point]) -> Bool {
            let path = [start] + points + [end]
            return zip(path, path.dropFirst()).contains { bounds.intersectsLine($0, $1) }
        }
        let primary = build(primarySide)
        if !crosses(primary) { return primary }
        let fallback = build(!primarySide)
        return crosses(fallback) ? primary : fallback
    }
}
