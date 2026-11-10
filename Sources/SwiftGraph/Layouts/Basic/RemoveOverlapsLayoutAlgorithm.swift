import Foundation

public final class RemoveOverlapsLayoutAlgorithm: LayoutAlgorithm {
    public var minSpacing: Float = 10

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let before = graph.nodes.map(\.bounds)
        defer { followMovedNodes(graph, from: before) }
        let leaves = graph.nodes.filter { !$0.isGroup }
        try forceScan(leaves, spacing: minSpacing)
        // Force scan cannot split nodes with identical centers; separate any such remainder locally.
        if try separateOverlaps(leaves, spacing: minSpacing, movable: leaves.map { _ in true }) { return }
        // Dense clusters can exhaust the pass budget; a rightward sweep always terminates.
        // Compare all preceding rectangles: a wide rectangle can overlap beyond its immediate neighbor.
        let sorted = graph.nodes.enumerated()
            .sorted { a, b in a.element.x == b.element.x ? a.offset < b.offset : a.element.x < b.element.x }
            .map(\.element)
        for i in sorted.indices {
            if i % 64 == 0 {
                try Task.checkCancellation()
                LayoutStageScope.tick(i, of: sorted.count)
            }
            let node = sorted[i]
            for other in sorted[..<i].sorted(by: { $0.x < $1.x })
            where node.y < other.bounds.bottom + minSpacing && node.bounds.bottom + minSpacing > other.y {
                if node.x < other.bounds.right + minSpacing && node.bounds.right > other.x {
                    node.x = other.bounds.right + minSpacing
                }
            }
        }
    }
}
