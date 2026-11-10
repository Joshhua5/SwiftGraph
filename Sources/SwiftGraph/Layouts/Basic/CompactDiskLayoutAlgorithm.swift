import Foundation

public final class CompactDiskLayoutAlgorithm: LayoutAlgorithm {
    public var spacing: Float = 40

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let nodes = graph.nodes.filter { !$0.isGroup }.sorted { $0.width * $0.height > $1.width * $1.height }
        guard !nodes.isEmpty else { return }
        let largest = nodes.prefix(max(1, nodes.count / 2))
        let c = largest.reduce(Float(0.0)) { $0 + max($1.width, $1.height) } / Float(largest.count) / 2 + spacing
        for (i, n) in nodes.enumerated() {
            let r = c * sqrt(Float(i))
            let angle = Double(i) * .pi * (3 - sqrt(5))
            n.center = Point(x: r * Float(cos(angle)), y: r * Float(sin(angle)))
        }
        straightEdges(graph)
    }
}
