import Foundation

public final class PartitionGridLayoutAlgorithm: LayoutAlgorithm {
    public var cellAssignment: [String: (row: Int, col: Int)] = [:]
    public var defaultColumnWidth: Float = 150
    public var defaultRowHeight: Float = 100
    public var cellPadding: Float = 20

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let cells = cellAssignment.filter { $0.value.row >= 0 && $0.value.col >= 0 }
        guard !cells.isEmpty, !graph.nodes.isEmpty else { return }
        // The guard above leaves `cells` non-empty, so both maxima have a value.
        var heights = Array(repeating: defaultRowHeight, count: cells.values.map(\.row).max()! + 1)
        var widths = Array(repeating: defaultColumnWidth, count: cells.values.map(\.col).max()! + 1)
        for n in graph.nodes {
            guard let c = cells[n.id] else { continue }
            heights[c.row] = max(heights[c.row], n.height + cellPadding * 2)
            widths[c.col] = max(widths[c.col], n.width + cellPadding * 2)
        }
        let xs = offsets(widths)
        let ys = offsets(heights)
        for n in graph.nodes {
            guard let c = cells[n.id] else { continue }
            n.center = Point(x: xs[c.col] + widths[c.col] / 2, y: ys[c.row] + heights[c.row] / 2)
        }
        ChannelEdgeRouter().routeEdges(graph)
    }
}

func offsets(_ sizes: [Float], gap: Float = 0) -> [Float] {
    var position: Float = 0.0
    return sizes.map { size in
        defer { position += size + gap }
        return position
    }
}
