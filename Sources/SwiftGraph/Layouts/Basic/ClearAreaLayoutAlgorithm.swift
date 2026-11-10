import Foundation

public final class ClearAreaLayoutAlgorithm: LayoutAlgorithm {
    public var clearArea: Rect

    public init(_ areaToClear: Rect = Rect(width: 100, height: 100)) { clearArea = areaToClear }

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let gap: Float = 10.0
        for n in graph.nodes where n.bounds.intersects(clearArea) {
            let start = n.bounds
            let others = n.isGroup ? [] : graph.nodes.filter { $0 !== n && !$0.isGroup }.map(\.bounds)
            // Leave the area on each side, then keep going past any node the move would land on.
            let moves = [
                Point(x: clearArea.left - start.right - gap, y: 0), Point(x: clearArea.right - start.left + gap, y: 0),
                Point(x: 0, y: clearArea.top - start.bottom - gap), Point(x: 0, y: clearArea.bottom - start.top + gap),
            ]
            .enumerated()
            .map { side, initial in
                var offset = initial
                while let hit = others.first(where: {
                    start.translated(by: offset).inflated(by: gap - 1e-6).intersects($0)
                }) {
                    switch side {
                    case 0: offset.x = hit.left - gap - start.right
                    case 1: offset.x = hit.right + gap - start.left
                    case 2: offset.y = hit.top - gap - start.bottom
                    default: offset.y = hit.bottom + gap - start.top
                    }
                }
                return offset
            }
            // `moves` always holds one candidate per side, four in all.
            let best = moves.min { abs($0.x) + abs($0.y) < abs($1.x) + abs($1.y) }!
            n.x += best.x
            n.y += best.y
        }
        straightEdges(graph)
    }
}
