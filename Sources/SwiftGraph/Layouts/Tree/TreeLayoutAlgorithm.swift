import Foundation

public final class TreeLayoutAlgorithm: LayoutAlgorithm {
    public var nodeSeparation: Float = 50
    public var levelSeparation: Float = 50

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        let f = Forest(a)
        guard let maxDepth = f.depth.max() else { return }
        var heights = Array(repeating: Float(0.0), count: maxDepth + 1)
        for i in a.nodes.indices { heights[f.depth[i]] = max(heights[f.depth[i]], a.nodes[i].height) }
        let ys = offsets(heights, gap: levelSeparation)
        var cursor: Float = 0.0
        for (rootIndex, root) in f.roots.enumerated() {
            LayoutStageScope.tick(rootIndex, of: f.roots.count)
            var stack = [(root, false)]
            while let (i, post) = stack.popLast() {
                if !post {
                    stack.append((i, true))
                    for j in f.children[i].reversed() { stack.append((j, false)) }
                    continue
                }
                let node = a.nodes[i]
                node.y = ys[f.depth[i]]
                if let first = f.children[i].first, let last = f.children[i].last {
                    node.x = (a.nodes[first].center.x + a.nodes[last].center.x) / 2 - node.width / 2
                    cursor = max(cursor, node.bounds.right + nodeSeparation)
                } else {
                    node.x = cursor
                    cursor += node.width + nodeSeparation
                }
            }
            cursor += nodeSeparation * 2
            try Task.checkCancellation()
        }
        packForest(a.nodes, components: f.components, spacing: max(20, nodeSeparation))
        straightEdges(graph)
    }
}
