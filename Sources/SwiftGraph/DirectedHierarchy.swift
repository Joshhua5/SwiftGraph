import Foundation

/// Sugiyama layering with virtual nodes, deterministic median ordering and weighted PAV placement.
final class DirectedHierarchy: LayoutAlgorithm {
    var layerSeparation: Double = 50
    var nodeSeparation: Double = 50
    var rankSeparation: Double { get { layerSeparation } set { layerSeparation = newValue } }
    var maxNodesPerRank: Int?
    var retainBestSweep = true
    init() {}
    func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph), count = a.nodes.count
        guard count > 0 else { return }
        var layers = a.layers(maxWidth: maxNodesPerRank ?? .max)
        var ranks = Array(repeating: 0, count: count)
        for (r, layer) in layers.enumerated() { for i in layer { ranks[i] = r } }
        var widths = a.nodes.map(\.width), incoming = Array(repeating: [Int](), count: count), outgoing = incoming
        var chains: [LayoutEdge: [Int]] = [:]
        for edge in graph.edges {
            guard let s = a.index[edge.source], let t = a.index[edge.target], s != t else { continue }
            let delta = ranks[t] - ranks[s], span = abs(delta)
            var chain: [Int] = []
            if span > 1 && span - 1 <= 64 {
                for step in 1..<span {
                    let v = widths.count, rank = ranks[s] + step * (delta > 0 ? 1 : -1)
                    widths.append(8); ranks.append(rank); incoming.append([]); outgoing.append([])
                    layers[rank].append(v); chain.append(v)
                }
            }
            chains[edge] = chain
            let path = [s] + chain + [t]
            for (u, v) in zip(path, path.dropFirst()) where abs(ranks[u] - ranks[v]) == 1 {
                let low = ranks[u] < ranks[v] ? u : v, high = ranks[u] < ranks[v] ? v : u
                outgoing[low].append(high); incoming[high].append(low)
            }
        }
        var order = Array(repeating: 0, count: widths.count)
        func updateOrder() { for layer in layers { for (p, i) in layer.enumerated() { order[i] = p } } }
        updateOrder()
        // Median sweeps can oscillate: keep the best complete ordering, not whichever
        // direction happened to run last. Count inversions without quadratic edge scans.
        func crossingCount() -> Int {
            var result = 0
            for rank in layers.indices.dropLast() {
                var tree = Array(repeating: 0, count: layers[rank + 1].count + 1)
                var seen = 0
                for node in layers[rank] {
                    for neighbor in outgoing[node] {
                        var i = order[neighbor] + 1, prefix = 0
                        while i > 0 { prefix += tree[i]; i -= i & -i }
                        result += seen - prefix
                    }
                    // Connections from one node do not cross one another.
                    for neighbor in outgoing[node] {
                        var i = order[neighbor] + 1
                        while i < tree.count { tree[i] += 1; i += i & -i }
                        seen += 1
                    }
                }
            }
            return result
        }
        var bestLayers = layers, bestCrossings = crossingCount()
        for sweep in 0..<12 {
            try Task.checkCancellation()
            let forward = sweep % 2 == 0
            let indices = forward ? Array(layers.indices) : Array(layers.indices.reversed())
            var changed = false
            for rank in indices {
                let old = layers[rank]
                var medians: [Int: Double] = [:]
                for i in old {
                    let values = (forward ? incoming[i] : outgoing[i]).map { order[$0] }.sorted()
                    if values.isEmpty { medians[i] = Double(order[i]) }
                    else { medians[i] = Double(values[(values.count - 1) / 2] + values[values.count / 2]) / 2 }
                }
                layers[rank].sort {
                    let l = medians[$0]!, r = medians[$1]!
                    return l == r ? order[$0] < order[$1] : l < r
                }
                changed = changed || old != layers[rank]
                for (p, i) in layers[rank].enumerated() { order[i] = p }
            }
            let crossings = crossingCount()
            if crossings < bestCrossings { bestLayers = layers; bestCrossings = crossings }
            if !changed && sweep > 0 { break }
        }
        if retainBestSweep { layers = bestLayers; updateOrder() }
        // Adjacent transpositions remove inversions left by median ties. Each swap strictly
        // improves the neighboring-rank crossing count, so ordering stays deterministic.
        for _ in 0..<4 {
            var changed = false
            for rank in layers.indices where layers[rank].count > 1 {
                for p in 0..<(layers[rank].count - 1) {
                    let u = layers[rank][p], v = layers[rank][p + 1]
                    var before = 0, after = 0
                    for lists in [(incoming[u], incoming[v]), (outgoing[u], outgoing[v])] {
                        for a in lists.0 { for b in lists.1 {
                            if order[a] > order[b] { before += 1 }
                            if order[a] < order[b] { after += 1 }
                        } }
                    }
                    if after < before {
                        layers[rank].swapAt(p, p + 1); order[u] = p + 1; order[v] = p; changed = true
                    }
                }
            }
            if !changed { break }
        }
        let heights = layers.map { layer in layer.map { $0 < count ? a.nodes[$0].height : 0 }.max() ?? 0 }
        let ys = offsets(heights, gap: layerSeparation)
        var xs = Array(repeating: 0.0, count: widths.count)
        for layer in layers {
            let total = layer.reduce(0.0) { $0 + widths[$1] } + Double(max(0, layer.count - 1)) * nodeSeparation
            var x = -total / 2
            for i in layer { xs[i] = x + widths[i] / 2; x += widths[i] + nodeSeparation }
        }
        for pass in 0..<3 {
            try Task.checkCancellation()
            for rank in (pass % 2 == 0 ? Array(layers.indices) : Array(layers.indices.reversed())) {
                let layer = layers[rank]
                var desired: [Double] = [], shift: [Double] = [], weights: [Double] = [], distance = 0.0
                for (position, i) in layer.enumerated() {
                    if position > 0 { distance += (widths[layer[position - 1]] + widths[i]) / 2 + nodeSeparation }
                    shift.append(distance)
                    let neighbors = incoming[i] + outgoing[i]
                    desired.append((neighbors.isEmpty ? xs[i] : neighbors.reduce(0.0) { $0 + xs[$1] } / Double(neighbors.count)) - distance)
                    weights.append(i < count ? 1 : 4)
                }
                let fitted = isotonic(desired, weights: weights)
                for (p, i) in layer.enumerated() { xs[i] = fitted[p] + shift[p] }
            }
        }
        for i in a.nodes.indices { a.nodes[i].center = Point(x: xs[i], y: ys[ranks[i]] + heights[ranks[i]] / 2) }
        for e in graph.edges {
            let bends = (chains[e] ?? []).map { Point(x: xs[$0], y: ys[ranks[$0]] + heights[ranks[$0]] / 2) }
            e.path = [e.source.center] + bends + [e.target.center]
        }
    }
}
private func isotonic(_ values: [Double], weights: [Double]) -> [Double] {
    var blocks: [(start: Int, end: Int, sum: Double, weight: Double)] = []
    for i in values.indices {
        blocks.append((i, i, values[i] * weights[i], weights[i]))
        while blocks.count > 1 {
            let last = blocks[blocks.count - 1], prev = blocks[blocks.count - 2]
            if prev.sum / prev.weight <= last.sum / last.weight { break }
            blocks.removeLast(); blocks.removeLast()
            blocks.append((prev.start, last.end, prev.sum + last.sum, prev.weight + last.weight))
        }
    }
    var result = values
    for block in blocks { for i in block.start...block.end { result[i] = block.sum / block.weight } }
    return result
}
