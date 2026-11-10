import Foundation

public final class OrthogonalLayoutAlgorithm: LayoutAlgorithm {
    public var gridSize: Float = 100

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        gridLayout(graph, spacing: gridSize)
        for e in graph.edges where e.source !== e.target {
            let a = e.source.center
            let b = e.target.center
            let x = (a.x + b.x) / 2
            e.path = [a, Point(x: x, y: a.y), Point(x: x, y: b.y), b]
        }
    }
}
