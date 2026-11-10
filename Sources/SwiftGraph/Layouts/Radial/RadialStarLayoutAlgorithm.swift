import Foundation

public final class RadialStarLayoutAlgorithm: LayoutAlgorithm {
    public var radius: Float = 200

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph, excludingGroups: true)
        guard
            let root = a.nodes.indices.max(by: {
                a.neighbors[$0].count == a.neighbors[$1].count ? $0 > $1 : a.neighbors[$0].count < a.neighbors[$1].count
            })
        else { return }
        a.nodes[root].center = .zero
        let others = a.nodes.indices.filter { $0 != root }
        var depth = Array(repeating: 1, count: a.nodes.count)
        var angles = Array(repeating: 0.0, count: a.nodes.count)
        depth[root] = 0
        for (j, i) in others.enumerated() { angles[i] = Double(j) * 2 * .pi / Double(others.count) }
        try placeRadialRings(a.nodes, depth: depth, angles: angles, minimumStep: radius)
        straightEdges(graph)
        ObstaclePolyline.repair(graph)
        try Task.checkCancellation()
    }
}
