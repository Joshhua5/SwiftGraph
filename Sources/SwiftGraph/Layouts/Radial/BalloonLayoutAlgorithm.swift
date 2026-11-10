import Foundation

public final class BalloonLayoutAlgorithm: LayoutAlgorithm {
    public var minRadius: Float = 50

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph, excludingGroups: true)
        let f = Forest(a, undirected: true, degreeRoots: true)
        var sizes = Array(repeating: 1, count: a.nodes.count)
        var cursor: Float = 0.0
        for i in f.order.reversed() { sizes[i] += f.children[i].reduce(0) { $0 + sizes[$1] } }
        for (componentIndex, root) in f.roots.enumerated() {
            LayoutStageScope.tick(componentIndex, of: f.roots.count)
            a.nodes[root].x = 0
            a.nodes[root].y = 0
            var component = [a.nodes[root]]
            var stack = [(root, Float(0.0), 2 * Float.pi)]
            while let (i, start, sweep) = stack.popLast() {
                let children = f.children[i]
                guard !children.isEmpty else { continue }
                let total = children.reduce(0) { $0 + sizes[$1] }
                // The guard above leaves `children` non-empty.
                let span = children.map { hypot(a.nodes[$0].width, a.nodes[$0].height) }.max()! + 20
                let r = max(minRadius, Float(children.count) * span / max(sweep, 1e-9))
                var angle = start
                for child in children {
                    let childSweep = sweep * Float(sizes[child]) / Float(total)
                    let mid = angle + childSweep / 2
                    a.nodes[child].center = a.nodes[i].center + Point(x: r * cos(mid), y: r * sin(mid))
                    component.append(a.nodes[child])
                    stack.append((child, angle, childSweep))
                    angle += childSweep
                }
            }
            let bounds = enclosingBounds(component)
            if componentIndex > 0 { for node in component { node.x += cursor - bounds.x } }
            cursor = componentIndex == 0 ? bounds.right + minRadius : cursor + bounds.width + minRadius
            try Task.checkCancellation()
        }
        straightEdges(graph)
    }
}
