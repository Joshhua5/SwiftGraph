import Foundation

public final class VerticalStackLayoutAlgorithm: LayoutAlgorithm {
    public var spacing: Float = 40
    public var paddingX: Float = 10
    public var paddingY: Float = 10

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        var y = paddingY
        let width = graph.nodes.map(\.width).max() ?? 0
        // Numeric-aware ordering keeps n2 before n10.
        for n in graph.nodes.sorted(by: { $0.id.compare($1.id, options: .numeric) == .orderedAscending }) {
            n.x = paddingX
            n.y = y
            n.width = width
            y += n.height + spacing
        }
    }
}
