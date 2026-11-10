import Foundation

public final class CircularLayoutAlgorithm: LayoutAlgorithm {
    public var radius: Float = 300

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let nodes = graph.nodes.filter { !$0.isGroup }
        guard !nodes.isEmpty else { return }
        let fitted = fittedCirclePlacement(nodes.map(\.bounds), minimum: radius)
        let r = fitted.radius
        for (i, node) in nodes.enumerated() {
            let angle = fitted.angles[i]
            node.center = Point(x: r + 50 + r * cos(angle), y: r + 50 + r * sin(angle))
        }
        straightEdges(graph)
    }
}
