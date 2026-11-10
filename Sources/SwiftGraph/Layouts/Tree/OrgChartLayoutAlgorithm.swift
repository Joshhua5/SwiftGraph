import Foundation

public final class OrgChartLayoutAlgorithm: LayoutAlgorithm {
    public var layerDistance: Float = 80
    public var siblingDistance: Float = 40

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        let f = Forest(a)
        let assistant = a.nodes.map { ($0.data as? String)?.lowercased() == "assistant" }
        var depths = Array(repeating: -1, count: a.nodes.count)
        var pending = f.roots
        for root in f.roots { depths[root] = 0 }
        while let i = pending.popLast() {
            let step = f.children[i].contains { assistant[$0] } ? 2 : 1
            for child in f.children[i] where !assistant[child] {
                depths[child] = depths[i] + step
                pending.append(child)
            }
        }
        let levels = orgChartLevelOffsets(a.nodes, depths: depths, minimum: layerDistance)
        var cursor: Float = 0.0
        for (rootIndex, root) in f.roots.enumerated() {
            LayoutStageScope.tick(rootIndex, of: f.roots.count)
            var stack = [(root, false)]
            while let (i, post) = stack.popLast() {
                let regular = f.children[i].filter { !assistant[$0] }
                let assistants = f.children[i].filter { assistant[$0] }
                if !post {
                    stack.append((i, true))
                    for child in regular.reversed() { stack.append((child, false)) }
                    continue
                }
                let node = a.nodes[i]
                node.y = levels[depths[i]]
                if let first = regular.first, let last = regular.last {
                    node.x = (a.nodes[first].center.x + a.nodes[last].center.x) / 2 - node.width / 2
                } else {
                    node.x = cursor
                    cursor += node.width
                }
                cursor = max(cursor, node.bounds.right)
                var assistantY = node.y + 20
                for j in assistants {
                    a.nodes[j].x = node.bounds.right + 20
                    a.nodes[j].y = assistantY
                    assistantY += a.nodes[j].height + 10
                    cursor = max(cursor, a.nodes[j].bounds.right)
                }
                cursor += siblingDistance
            }
            try Task.checkCancellation()
        }
        packForest(a.nodes, components: f.components, spacing: max(20, siblingDistance))
        straightEdges(graph)
    }
}
