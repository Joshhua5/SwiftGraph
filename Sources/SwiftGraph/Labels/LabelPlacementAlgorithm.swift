import Foundation

public final class LabelPlacementAlgorithm {
    public var labelProvider: (LayoutEdge) -> String? = defaultLabelProvider

    /// Measured size of an edge's label text, for callers that can ask their UI toolkit. Without it a size already on
    /// `labelBounds` is kept, and otherwise the size is estimated from the character count.
    public var sizeProvider: (LayoutEdge, String) -> Size? = { _, _ in nil }

    public init() {}

    public func applyLabelPlacement(_ graph: LayoutGraph) {
        var labeled: [LayoutEdge] = []
        for edge in graph.edges {
            guard let text = labelProvider(edge), !text.isEmpty else { continue }
            labeled.append(edge)
            let size = labelSize(edge, text: text, provider: sizeProvider)
            let center = LabelCollisionRepair.midpoint(edge.path)
            edge.labelBounds = Rect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
        LabelCollisionRepair.apply(
            labeled,
            among: graph.edges,
            obstacles: graph.nodes.filter { !$0.isGroup }.map(\.bounds)
        )
    }
}
