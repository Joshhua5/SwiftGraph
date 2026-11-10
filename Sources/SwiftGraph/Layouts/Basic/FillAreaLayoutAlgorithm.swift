import Foundation

public final class FillAreaLayoutAlgorithm: LayoutAlgorithm {
    public var fillArea: Rect

    public init(_ areaToFill: Rect = Rect(width: 100, height: 100)) { fillArea = areaToFill }

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let nodes = graph.nodes.filter { !$0.isGroup }
        let count = nodes.count
        guard count > 0 else { return }
        let ratio = fillArea.width > 0 && fillArea.height > 0 ? fillArea.width / fillArea.height : 1
        let cols = min(count, max(1, Int(ceil(sqrt(Float(count) * ratio)))))
        let rows = (count + cols - 1) / cols
        let cw = fillArea.width > 0 ? fillArea.width / Float(cols) : 1
        let ch = fillArea.height > 0 ? fillArea.height / Float(rows) : 1
        for (i, n) in nodes.enumerated() {
            n.center = Point(x: fillArea.x + (Float(i % cols) + 0.5) * cw, y: fillArea.y + (Float(i / cols) + 0.5) * ch)
        }
        straightEdges(graph)
    }
}
