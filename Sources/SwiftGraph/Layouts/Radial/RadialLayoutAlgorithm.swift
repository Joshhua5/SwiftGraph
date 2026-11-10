import Foundation

public final class RadialLayoutAlgorithm: LayoutAlgorithm {
    public var layerSeparation: Float = 100

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph, excludingGroups: true)
        guard
            let root = a.nodes.indices.max(by: {
                a.neighbors[$0].count == a.neighbors[$1].count ? $0 > $1 : a.neighbors[$0].count < a.neighbors[$1].count
            })
        else { return }
        var depth = Array(repeating: -1, count: a.nodes.count)
        var queue = [root]
        var cursor = 0
        depth[root] = 0
        while cursor < queue.count {
            let i = queue[cursor]
            cursor += 1
            for j in a.neighbors[i] where depth[j] < 0 {
                depth[j] = depth[i] + 1
                queue.append(j)
            }
        }
        let outer = (depth.max() ?? 0) + 1
        for i in depth.indices where depth[i] < 0 { depth[i] = outer }
        a.nodes[root].center = .zero
        var angles = Array(repeating: 0.0, count: a.nodes.count)
        for d in 1...max(1, outer) {
            let ring = a.nodes.indices.filter { depth[$0] == d }
            for (j, i) in ring.enumerated() { angles[i] = Double(j) * 2 * .pi / Double(ring.count) }
        }
        try placeRadialRings(a.nodes, depth: depth, angles: angles, minimumStep: layerSeparation)
        straightEdges(graph)
        ObstaclePolyline.repair(graph)
        try Task.checkCancellation()
    }
}
