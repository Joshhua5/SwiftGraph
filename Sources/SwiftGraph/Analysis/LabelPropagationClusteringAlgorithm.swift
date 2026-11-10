import Foundation

public final class LabelPropagationClusteringAlgorithm: LayoutAlgorithm {
    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        var labels = Array(a.nodes.indices)
        var order = labels
        var random = SeededRandom()
        for _ in 0..<20 {
            try Task.checkCancellation()
            if order.count > 1 {
                for i in stride(from: order.count - 1, through: 1, by: -1) {
                    order.swapAt(i, Int(random.next() * Double(i + 1)))
                }
            }
            var changed = false
            for i in order {
                var counts: [Int: Int] = [:]
                var labelOrder: [Int] = []
                for j in a.neighbors[i] {
                    if counts[labels[j]] == nil { labelOrder.append(labels[j]) }
                    counts[labels[j], default: 0] += 1
                }
                var best = labels[i]
                var bestCount = counts[best, default: 0]
                for label in labelOrder where counts[required: label] > bestCount {
                    best = label
                    bestCount = counts[required: label]
                }
                if labels[i] != best {
                    changed = true
                    labels[i] = best
                }
            }
            if !changed { break }
        }
        for i in a.nodes.indices { a.nodes[i].metadata[GraphMetadataKeys.cluster] = labels[i] }
    }
}

@available(*, deprecated, renamed: "LabelPropagationClusteringAlgorithm")
public typealias LouvainClusteringAlgorithm = LabelPropagationClusteringAlgorithm
