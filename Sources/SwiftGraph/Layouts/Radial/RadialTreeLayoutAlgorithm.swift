import Foundation

public final class RadialTreeLayoutAlgorithm: LayoutAlgorithm {
    public var layerDistance: Float = 100

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        let f = Forest(a)
        for (rootIndex, root) in f.roots.enumerated() {
            LayoutStageScope.tick(rootIndex, of: f.roots.count)
            var indices: [Int] = []
            var angles = Array(repeating: 0.0, count: a.nodes.count)
            var stack = [(root, 0.0, 2 * Double.pi)]
            while let (i, start, end) = stack.popLast() {
                angles[i] = (start + end) / 2
                indices.append(i)
                let children = f.children[i]
                let sweep = (end - start) / Double(max(1, children.count))
                for (j, child) in children.enumerated().reversed() {
                    stack.append((child, start + Double(j) * sweep, start + Double(j + 1) * sweep))
                }
            }
            let component = indices.map { a.nodes[$0] }
            try placeRadialRings(
                component,
                depth: indices.map { f.depth[$0] },
                angles: indices.map { angles[$0] },
                minimumStep: layerDistance,
                compactDepths: true
            )
            try Task.checkCancellation()
        }
        packForest(a.nodes, components: f.components, spacing: layerDistance.isFinite ? max(20, layerDistance) : 100)
        straightEdges(graph)
        ObstaclePolyline.repair(graph)
        try Task.checkCancellation()
    }
}
