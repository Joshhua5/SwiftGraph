import Foundation

public final class AlignmentLayoutAlgorithm: LayoutAlgorithm {
    public var horizontalAlignment: AlignmentMode = .none
    public var verticalAlignment: AlignmentMode = .none
    public var gridSize: Float = 20

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let bounds = graph.bounds
        var moved = false
        for n in graph.nodes {
            let old = n.bounds
            switch horizontalAlignment {
            case .left: n.x = bounds.left
            case .right: n.x = bounds.right - n.width
            case .center: n.x = bounds.center.x - n.width / 2
            case .snapToGrid where gridSize > 0: n.x = (n.x / gridSize).rounded(.toNearestOrEven) * gridSize
            default: break
            }
            switch verticalAlignment {
            case .top: n.y = bounds.top
            case .bottom: n.y = bounds.bottom - n.height
            case .middle: n.y = bounds.center.y - n.height / 2
            case .snapToGrid where gridSize > 0: n.y = (n.y / gridSize).rounded(.toNearestOrEven) * gridSize
            default: break
            }
            moved = moved || n.bounds != old
        }
        if moved { straightEdges(graph) }
    }
}
