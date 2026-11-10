import Foundation

/// The nesting a tree map partitions: the group hierarchy, or the edge forest when the graph has no groups.
/// A detached view (`subgraph`) lists every member directly under its root while members keep their real parents,
/// so nesting is recovered from those parents: a member is top-level when its parent is the root or outside the view.
func treeMapChildren(_ graph: LayoutGraph) -> [LayoutNode: [LayoutNode]] {
    let members = Set(graph.nodes)
    func isTopLevel(_ node: LayoutNode) -> Bool {
        node.parent.map { $0 === graph.root || !members.contains($0) } ?? true
    }
    var children: [LayoutNode: [LayoutNode]] = [:]
    if graph.nodes.allSatisfy(isTopLevel) && !graph.edges.isEmpty {
        let a = Adjacency(graph)
        let f = Forest(a)
        children[graph.root] = f.roots.map { a.nodes[$0] }
        for i in a.nodes.indices { children[a.nodes[i]] = f.children[i].map { a.nodes[$0] } }
    } else {
        children[graph.root] = graph.root.children.filter { members.contains($0) && isTopLevel($0) }
        for node in graph.nodes { children[node] = node.children.filter(members.contains) }
    }
    return children
}

public final class TreeMapLayoutAlgorithm: LayoutAlgorithm {
    public var padding: Float = 5

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        var children = treeMapChildren(graph)
        var order: [LayoutNode] = []
        var seen = Set<LayoutNode>()
        var stack = [graph.root]
        while let node = stack.popLast() {
            guard seen.insert(node).inserted else { continue }
            order.append(node)
            let list = (children[node] ?? node.children).filter { !seen.contains($0) }
            children[node] = list
            stack.append(contentsOf: list.reversed())
        }
        var weights: [LayoutNode: Float] = [:]
        for node in order.reversed() {
            weights[node] = max(1, (children[node] ?? []).reduce(Float(0.0)) { $0 + weights[$1, default: 0] })
        }
        graph.root.bounds = Rect(width: 1000, height: 1000)
        for (position, node) in order.enumerated() {
            if position & 63 == 0 { LayoutStageScope.tick(position, of: order.count) }
            try Task.checkCancellation()
            let r = node.bounds
            let vertical = r.width > r.height
            let list = children[node] ?? []
            let inner = Rect(
                x: r.x + padding,
                y: r.y + padding,
                width: max(0, r.width - 2 * padding),
                height: max(0, r.height - 2 * padding)
            )
            var position = vertical ? inner.x : inner.y
            let total = max(1, list.reduce(Float(0.0)) { $0 + weights[$1, default: 1] })
            for child in list {
                let ratio = weights[child, default: 1] / total
                if vertical {
                    child.bounds = Rect(x: position, y: inner.y, width: inner.width * ratio, height: inner.height)
                    position += inner.width * ratio
                } else {
                    child.bounds = Rect(x: inner.x, y: position, width: inner.width, height: inner.height * ratio)
                    position += inner.height * ratio
                }
            }
        }
    }
}
