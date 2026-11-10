import Foundation

public final class KandinskyLayoutAlgorithm: LayoutAlgorithm {
    public var gridPadding: Float = 40
    public var maxCellsPerRow: Int?

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        let layers = a.layers(maxWidth: maxCellsPerRow ?? .max)
        guard let columns = layers.map(\.count).max() else { return }
        var widths = Array(repeating: Float(0.0), count: columns)
        var heights = Array(repeating: Float(0.0), count: layers.count)
        for (r, layer) in layers.enumerated() {
            for (c, i) in layer.enumerated() {
                widths[c] = max(widths[c], a.nodes[i].width)
                heights[r] = max(heights[r], a.nodes[i].height)
            }
        }
        let xs = offsets(widths, gap: gridPadding)
        let ys = offsets(heights, gap: gridPadding)
        for (r, layer) in layers.enumerated() {
            for (c, i) in layer.enumerated() {
                a.nodes[i].center = Point(x: xs[c] + widths[c] / 2, y: ys[r] + heights[r] / 2)
            }
        }
        ChannelEdgeRouter().routeEdges(graph)
    }
}
