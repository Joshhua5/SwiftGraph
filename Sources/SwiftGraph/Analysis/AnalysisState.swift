import Foundation

struct AnalysisState: Sendable {
    var count: Int
    var incomingOffsets: [UInt32]
    var incoming: [UInt32]
    var degree: [UInt32]
    var neighborOffsets: [UInt32]
    var neighbors: [UInt32]

    init(_ snapshot: GeometrySnapshot) throws {
        count = snapshot.nodes.count
        guard snapshot.edges.count <= 8_388_608 else {
            throw LayoutExecutionError.invalidInput("Analysis adjacency exceeds the 64 MiB limit.")
        }
        var incoming = Array(repeating: [UInt32](), count: count)
        var neighbors = incoming
        var degree = Array(repeating: UInt32(0), count: count)
        for edge in snapshot.edges where edge.source != edge.target {
            incoming[edge.target].append(UInt32(edge.source))
            degree[edge.source] += 1
            neighbors[edge.source].append(UInt32(edge.target))
            neighbors[edge.target].append(UInt32(edge.source))
        }
        // PageRank appends self-links after its ordinary adjacency, matching the CPU's summation order.
        for edge in snapshot.edges where edge.source == edge.target {
            incoming[edge.source].append(UInt32(edge.source))
            degree[edge.source] += 1
        }
        func flatten(_ values: [[UInt32]]) throws -> ([UInt32], [UInt32]) {
            var flat: [UInt32] = []
            var offsets: [UInt32] = [0]
            for row in values {
                guard flat.count + row.count <= 16_777_216 else {
                    throw LayoutExecutionError.invalidInput("Analysis adjacency exceeds the 64 MiB limit.")
                }
                flat.append(contentsOf: row)
                offsets.append(UInt32(flat.count))
            }
            return (offsets, flat)
        }
        (incomingOffsets, self.incoming) = try flatten(incoming)
        (neighborOffsets, self.neighbors) = try flatten(neighbors)
        self.degree = degree
    }

    func pageRankErrorBound(iterations: Int) -> Double {
        let maximumIncoming = zip(incomingOffsets, incomingOffsets.dropFirst()).map { Int($1 - $0) }.max() ?? 0
        return Double(iterations) * Double(count + maximumIncoming) / Double(max(1, count)) * 64
            * pow(Double(Float.ulpOfOne), 2)
    }

    func cpuPageRank(_ configuration: PageRankConfiguration) throws -> [Double] {
        guard count > 0 else { return [] }
        var ranks = Array(repeating: 1 / Double(count), count: count)
        for iteration in 0..<configuration.iterations {
            try Task.checkCancellation()
            LayoutStageScope.tick(iteration, of: configuration.iterations)
            let dangling = (0..<count).filter { degree[$0] == 0 }.reduce(0.0) { $0 + ranks[$1] }
            ranks = (0..<count)
                .map { i in
                    let links = incoming[Int(incomingOffsets[i])..<Int(incomingOffsets[i + 1])]
                        .reduce(0.0) { $0 + ranks[Int($1)] / Double(degree[Int($1)]) }
                    return (1 - configuration.dampingFactor) / Double(count) + configuration.dampingFactor
                        * (links + dangling / Double(count))
                }
        }
        return ranks
    }

    func cpuClusters() throws -> [Int] {
        var labels = Array(0..<count)
        var order = labels
        var random = SeededRandom()
        for round in 0..<20 {
            try Task.checkCancellation()
            LayoutStageScope.tick(round, of: 20)
            shuffle(&order, random: &random)
            var changed = false
            for i in order {
                var counts: [Int: Int] = [:]
                var labelOrder: [Int] = []
                for j in neighbors[Int(neighborOffsets[i])..<Int(neighborOffsets[i + 1])] {
                    if counts[labels[Int(j)]] == nil { labelOrder.append(labels[Int(j)]) }
                    counts[labels[Int(j)], default: 0] += 1
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
        return labels
    }
}

func shuffle(_ order: inout [Int], random: inout SeededRandom) {
    if order.count > 1 {
        for i in stride(from: order.count - 1, through: 1, by: -1) {
            order.swapAt(i, Int(random.next() * Double(i + 1)))
        }
    }
}

struct AnalysisResult: Sendable {
    var ranks: [Double]?
    var labels: [Int]?
    var metrics: LayoutExecutionMetrics
}
