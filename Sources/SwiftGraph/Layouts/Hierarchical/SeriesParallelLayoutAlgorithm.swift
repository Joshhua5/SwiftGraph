import Foundation

public final class SeriesParallelLayoutAlgorithm: LayoutAlgorithm {
    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        // Transpose dimensions before layout, then transpose the entire drawing back.
        for n in graph.nodes {
            let w = n.width
            n.width = n.height
            n.height = w
        }
        do { try HierarchicalLayoutAlgorithm().applyLayout(graph) } catch {
            for n in graph.nodes {
                let w = n.width
                n.width = n.height
                n.height = w
            }
            throw error
        }
        for n in graph.nodes { n.bounds = Rect(x: n.y, y: n.x, width: n.height, height: n.width) }
        for e in graph.edges { e.path = e.path.map { Point(x: $0.y, y: $0.x) } }
    }
}
