import Foundation

public final class TabularLayoutAlgorithm: LayoutAlgorithm {
    public var cellSpacing: Float = 50

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        gridLayout(graph, spacing: cellSpacing)
        straightEdges(graph)
    }
}

func gridLayout(_ graph: LayoutGraph, spacing: Float) {
    let nodes = graph.nodes.filter { !$0.isGroup }
    guard !nodes.isEmpty else { return }
    let columns = Int(ceil(sqrt(Double(nodes.count))))
    let stepX = (nodes.map(\.width).max() ?? 0) + spacing
    let stepY = (nodes.map(\.height).max() ?? 0) + spacing
    for (i, n) in nodes.enumerated() {
        n.x = Float(i % columns) * stepX
        n.y = Float(i / columns) * stepY
    }
}
