import Foundation

public final class BarycenterLayoutAlgorithm: LayoutAlgorithm {
    public var iterations = 3
    public var minSpacing: Float = 10

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        let bounds = graph.bounds
        var fixed = a.nodes.map { $0.metadata[GraphMetadataKeys.fixed] as? Bool == true }
        if !fixed.contains(true) {
            fixed = a.nodes.map {
                $0.x <= bounds.left + 1 || $0.bounds.right >= bounds.right - 1 || $0.y <= bounds.top + 1
                    || $0.bounds.bottom >= bounds.bottom - 1
            }
        }
        var positions = a.nodes.map(\.center)
        let solving = LayoutStageScope.begin("Solve", to: 0.85)
        for iteration in 0..<max(0, iterations) {
            try Task.checkCancellation()
            solving.tick(iteration, of: iterations)
            var next = positions
            for i in a.nodes.indices where !fixed[i] && !a.neighbors[i].isEmpty {
                next[i] = a.neighbors[i].reduce(Point.zero) { $0 + positions[$1] } / Float(a.neighbors[i].count)
            }
            positions = next
        }
        solving.end()
        for i in a.nodes.indices where !fixed[i] { a.nodes[i].center = positions[i] }
        // Averaging pulls nodes that share neighbors onto one point; spread them without moving anchors.
        _ = try LayoutStageScope.run("Separate overlaps", from: 0.85) {
            try separateOverlaps(a.nodes, spacing: minSpacing, movable: fixed.map { !$0 })
        }
        straightEdges(graph)
    }
}
