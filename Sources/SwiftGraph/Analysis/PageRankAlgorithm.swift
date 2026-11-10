import Foundation

public final class PageRankAlgorithm: LayoutAlgorithm {
    public var dampingFactor: Double = 0.85
    public var iterations = 20

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        let n = a.nodes.count
        guard n > 0 else { return }
        var incoming = a.incoming
        var degree = a.outgoing.map(\.count)
        // Self-links count for PageRank even though layout adjacency omits them.
        for e in graph.edges where e.source === e.target {
            if let i = a.index[e.source] {
                incoming[i].append(i)
                degree[i] += 1
            }
        }
        var ranks = Array(repeating: 1 / Double(n), count: n)
        for _ in 0..<max(0, iterations) {
            try Task.checkCancellation()
            let dangling = (0..<n).filter { degree[$0] == 0 }.reduce(0.0) { $0 + ranks[$1] }
            ranks = (0..<n)
                .map { i in
                    let links = incoming[i].reduce(0.0) { $0 + ranks[$1] / Double(degree[$1]) }
                    return (1 - dampingFactor) / Double(n) + dampingFactor * (links + dangling / Double(n))
                }
        }
        for i in 0..<n { a.nodes[i].metadata[GraphMetadataKeys.pageRank] = ranks[i] }
    }
}
