import Foundation

struct HierarchyPlacementOutput: Sendable {
    var layers: [UInt32]

    /// The last position of each fitted block, indexed by pass and vertex.
    var blockEnds: [UInt32]

    /// Merge count after inserting each vertex, retaining PAV's binary sum association.
    var mergeCounts: [UInt32]
    var gpuSeconds: Double
}

/// CPU topology preparation only: no median ordering or PAV fitting takes place here.
struct HierarchyPlacementPlan: Sendable {
    var originalCount: Int
    var layers: [[Int]]
    var ranks: [Int]
    var widths: [Float]
    var heights: [Float]
    var incoming: [[Int]]
    var outgoing: [[Int]]
    var chains: [[Int]]

    /// Sign of each edge's rank change; nil for self-loops and edges outside the graph, which are not routed between
    /// ranks.
    var flows: [Int?]
    var nodeSeparation: Float
    var layerSeparation: Float
    var routesEdges: Bool

    init(_ graph: LayoutGraph, configuration: HierarchicalLayoutConfiguration) throws {
        let adjacency = Adjacency(graph)
        originalCount = adjacency.nodes.count
        widths = adjacency.nodes.map(\.width)
        layers = adjacency.layers(maxWidth: configuration.maxNodesPerRank ?? .max)
        ranks = Array(repeating: 0, count: originalCount)
        for (rank, layer) in layers.enumerated() { for vertex in layer { ranks[vertex] = rank } }
        incoming = Array(repeating: [], count: originalCount)
        outgoing = incoming
        chains = Array(repeating: [], count: graph.edges.count)
        flows = Array(repeating: nil, count: graph.edges.count)
        for (index, edge) in graph.edges.enumerated() {
            try Task.checkCancellation()
            if index & 255 == 0 { LayoutStageScope.tick(index, of: graph.edges.count) }
            guard let source = adjacency.index[edge.source], let target = adjacency.index[edge.target], source != target
            else { continue }
            let delta = ranks[target] - ranks[source]
            let span = abs(delta)
            flows[index] = delta.signum()
            if span > 1 && span - 1 <= 64 {
                for step in 1..<span {
                    let vertex = widths.count
                    let rank = ranks[source] + step * (delta > 0 ? 1 : -1)
                    widths.append(0)
                    ranks.append(rank)
                    incoming.append([])
                    outgoing.append([])
                    layers[rank].append(vertex)
                    chains[index].append(vertex)
                }
            }
            let path = [source] + chains[index] + [target]
            for (a, b) in zip(path, path.dropFirst()) where abs(ranks[a] - ranks[b]) == 1 {
                let low = ranks[a] < ranks[b] ? a : b
                let high = ranks[a] < ranks[b] ? b : a
                outgoing[low].append(high)
                incoming[high].append(low)
            }
        }
        let count = adjacency.nodes.count
        heights = layers.map { layer in layer.map { $0 < count ? adjacency.nodes[$0].height : 0 }.max() ?? 0 }
        nodeSeparation = configuration.nodeSeparation
        layerSeparation = configuration.layerSeparation
        routesEdges = configuration.routesEdges
    }

    func validateMetal(tolerance: Float) throws {
        guard widths.count < 4_194_304,
            incoming.reduce(0, { $0 + $1.count }) < Int(UInt32.max),
            outgoing.reduce(0, { $0 + $1.count }) < Int(UInt32.max)
        else {
            throw LayoutExecutionError.invalidInput("Hierarchy exceeds Metal index capacity.")
        }
        let bound = widths.reduce(0, +) + Float(widths.count) * abs(nodeSeparation)
        // The kernel uses split Float arithmetic, not a single Float coordinate.
        // Bound accumulated error rather than rejecting wide ranks solely for the
        // high component's ULP. The same caller tolerance remains in force.
        let maximumDegree = incoming.indices.map { incoming[$0].count + outgoing[$0].count }.max() ?? 0
        guard maximumDegree < 16_777_216 else {
            throw LayoutExecutionError.invalidInput("Hierarchy degree exceeds precise Metal count capacity")
        }
        let errorBound = bound * Float(max(1, widths.count, maximumDegree)) * 1e-13
        guard bound.isFinite, errorBound <= tolerance,
            widths.allSatisfy(\.isFinite), nodeSeparation.isFinite
        else {
            throw LayoutExecutionError.precisionLimit
        }
    }

    func apply(_ output: HierarchyPlacementOutput, to graph: LayoutGraph) throws {
        guard output.layers.count == widths.count, output.blockEnds.count == widths.count * 3,
            output.mergeCounts.count == widths.count * 3,
            Set(output.layers).count == widths.count,
            output.layers.allSatisfy({ Int($0) < widths.count })
        else {
            throw OrganicLayoutError.metalFailure("Invalid hierarchy permutation")
        }
        var ordered: [[Int]] = []
        var cursor = 0
        for (rank, layer) in layers.enumerated() {
            let next = output.layers[cursor..<(cursor + layer.count)].map(Int.init)
            guard next.allSatisfy({ ranks[$0] == rank }) else {
                throw OrganicLayoutError.metalFailure("Invalid hierarchy rank")
            }
            ordered.append(next)
            cursor += layer.count
        }
        var xs = Array(repeating: Float(0), count: widths.count)
        for layer in ordered {
            let gaps = zip(layer, layer.dropFirst())
                .map { hierarchyGap($0, $1, originals: originalCount, separation: nodeSeparation) }
            let total = layer.reduce(Float(0)) { $0 + widths[$1] } + gaps.reduce(0, +)
            var x = -total / 2
            for (p, vertex) in layer.enumerated() {
                xs[vertex] = x + widths[vertex] / 2
                x += widths[vertex] + (p < gaps.count ? gaps[p] : 0)
            }
        }
        // Reconstruct from GPU decisions. The KKT checks reject Float decisions
        // that would violate isotonic projection, allowing automatic CPU fallback.
        try LayoutStageScope.run("Coordinates", to: 0.6) {
            for pass in 0..<3 {
                LayoutStageScope.tick(pass, of: 3)
                for rank in (pass % 2 == 0 ? Array(ordered.indices) : Array(ordered.indices.reversed())) {
                    try Task.checkCancellation()
                    let layer = ordered[rank]
                    var desired: [Float] = []
                    var shifts: [Float] = []
                    var distance: Float = 0
                    for (position, vertex) in layer.enumerated() {
                        if position > 0 {
                            distance +=
                                (widths[layer[position - 1]] + widths[vertex]) / 2
                                + hierarchyGap(
                                    layer[position - 1],
                                    vertex,
                                    originals: originalCount,
                                    separation: nodeSeparation
                                )
                        }
                        shifts.append(distance)
                        let neighbors = incoming[vertex] + outgoing[vertex]
                        desired.append(
                            (neighbors.isEmpty
                                ? xs[vertex] : neighbors.reduce(Float(0)) { $0 + xs[$1] } / Float(neighbors.count))
                                - distance
                        )
                    }
                    var blocks: [(start: Int, end: Int, sum: Float, weight: Float)] = []
                    for position in layer.indices {
                        let weight: Float = layer[position] < originalCount ? 1.0 : 4.0
                        blocks.append((position, position, desired[position] * weight, weight))
                        let merges = Int(output.mergeCounts[pass * widths.count + layer[position]])
                        guard merges < blocks.count else {
                            throw OrganicLayoutError.metalFailure("Invalid hierarchy merge history")
                        }
                        for _ in 0..<merges {
                            let last = blocks.removeLast()
                            let previous = blocks.removeLast()
                            blocks.append(
                                (previous.start, last.end, previous.sum + last.sum, previous.weight + last.weight)
                            )
                        }
                    }
                    var previous = -Float.infinity
                    for block in blocks {
                        let position = block.start
                        let end = block.end
                        let mean = block.sum / block.weight
                        let previousAllowance = max(abs(mean), previous.isFinite ? abs(previous) : 0).ulp * 16
                        guard mean.isFinite, mean + previousAllowance >= previous else {
                            throw LayoutExecutionError.precisionLimit
                        }
                        var prefix: Float = 0
                        var prefixWeight: Float = 0
                        for p in position...end {
                            guard output.blockEnds[pass * widths.count + layer[p]] == UInt32(end) else {
                                throw OrganicLayoutError.metalFailure("Inconsistent hierarchy fitted block")
                            }
                            let w: Float = layer[p] < originalCount ? 1.0 : 4.0
                            prefix += desired[p] * w
                            prefixWeight += w
                            // PAV's merged blocks use a binary merge summation. A tiny
                            // rounding allowance avoids rejecting the same optimum solely for
                            // different association; meaningful grouping differences still fail.
                            let allowance = max(abs(prefix), abs(mean * prefixWeight)).ulp * 16
                            guard p == end || prefix + allowance >= mean * prefixWeight else {
                                throw LayoutExecutionError.precisionLimit
                            }
                            xs[layer[p]] = mean + shifts[p]
                        }
                        previous = mean
                    }
                }
            }
        }
        let ys = offsets(heights, gap: layerSeparation)
        for i in 0..<originalCount { graph.nodes[i].center = Point(x: xs[i], y: ys[ranks[i]] + heights[ranks[i]] / 2) }
        guard routesEdges else { return }
        let routed: [[Point]?] = chains.indices.map { i in
            flows[i] == nil ? nil : chains[i].map { Point(x: xs[$0], y: ys[ranks[$0]] + heights[ranks[$0]] / 2) }
        }
        try LayoutStageScope.run("Route edges", from: 0.6) {
            try routeLayeredEdges(graph, chains: routed, flows: flows, layerSeparation: layerSeparation)
        }
    }
}
