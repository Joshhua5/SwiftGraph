import Foundation

/// Sugiyama layering with virtual nodes, deterministic median ordering and weighted PAV placement.
final class DirectedHierarchy: LayoutAlgorithm {
    var layerSeparation: Float = 50
    var nodeSeparation: Float = 50
    var rankSeparation: Float { get { layerSeparation } set { layerSeparation = newValue } }
    var maxNodesPerRank: Int?
    var retainBestSweep = true
    /// Spacing of the ports on one side of a node; targets then aim at the neighbour's port, not its centre.
    var portPitch: Float = 0
    static let maxVirtualNodes = 20_000
    /// Feedback edges laid out against their direction: they rank, order and get virtual chains as target-to-source edges.
    var reversed: Set<LayoutEdge> = []
    init() {}
    func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph), count = a.nodes.count
        guard count > 0 else { return }
        var layers: [[Int]]
        if let width = maxNodesPerRank { layers = a.layers(maxWidth: width) }
        else {
            // Network simplex shortens edges globally; layers keep the caller's node order, which the trials vary.
            let pairs = graph.edges.compactMap { e -> (Int, Int)? in
                guard let s = a.index[e.source], let t = a.index[e.target] else { return nil }
                return reversed.contains(e) ? (t, s) : (s, t)
            }
            let ranked = DirectedLayering.ranks(count: count, edges: pairs)
            layers = Array(repeating: [], count: (ranked.max() ?? 0) + 1)
            for (i, rank) in ranked.enumerated() { layers[rank].append(i) }
        }
        var ranks = Array(repeating: 0, count: count)
        for (r, layer) in layers.enumerated() { for i in layer { ranks[i] = r } }
        var widths = a.nodes.map(\.width), incoming = Array(repeating: [Int](), count: count), outgoing = incoming
        var chains: [LayoutEdge: [Int]] = [:], dummyBudget = Self.maxVirtualNodes
        for edge in graph.edges {
            guard let source = a.index[edge.source], let target = a.index[edge.target], source != target else { continue }
            let (s, t) = reversed.contains(edge) ? (target, source) : (source, target)
            let delta = ranks[t] - ranks[s], span = abs(delta)
            var chain: [Int] = []
            // Any span gets guidance; only the total of virtual nodes is bounded, so a pathological graph stays linear-ish.
            if span > 1 && span - 1 <= dummyBudget {
                dummyBudget -= span - 1
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
                var medians: [Int: Float] = [:]
                for i in old {
                    let values = (forward ? incoming[i] : outgoing[i]).map { order[$0] }.sorted()
                    if values.isEmpty { medians[i] = Float(order[i]) }
                    else { medians[i] = Float(values[(values.count - 1) / 2] + values[values.count / 2]) / 2 }
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
        var xs = Array(repeating: Float(0), count: widths.count)
        for layer in layers {
            let total = layer.reduce(Float(0)) { $0 + widths[$1] } + Float(max(0, layer.count - 1)) * nodeSeparation
            var x = -total / 2
            for i in layer { xs[i] = x + widths[i] / 2; x += widths[i] + nodeSeparation }
        }
        // Port-aware targets: a node wants to sit where its edges' ports line up with the neighbours' ports.
        var sortedIn = incoming, sortedOut = outgoing
        for i in incoming.indices {
            sortedIn[i].sort { order[$0] < order[$1] }; sortedOut[i].sort { order[$0] < order[$1] }
        }
        func portOffsets(_ list: [Int], of i: Int) -> [Float] {
            guard i < count, list.count > 1 else { return Array(repeating: 0, count: list.count) }
            let step = min(portPitch, max(0, widths[i] - 24) / Float(list.count - 1))
            return list.indices.map { (Float($0) - Float(list.count - 1) / 2) * step }
        }
        let inOffsets = sortedIn.indices.map { portOffsets(sortedIn[$0], of: $0) }, outOffsets = sortedOut.indices.map { portOffsets(sortedOut[$0], of: $0) }
        // For each vertex, (neighbour, neighbour's port offset, own port offset) over all its edges.
        var attachments = Array(repeating: [(Int, Float, Float)](), count: widths.count)
        var inSlots: [[Int]: [Int]] = [:]
        for v in sortedIn.indices { for (j, u) in sortedIn[v].enumerated() { inSlots[[u, v], default: []].append(j) } }
        for u in sortedOut.indices {
            var used: [Int: Int] = [:]
            for (j, v) in sortedOut[u].enumerated() {
                let k = used[v, default: 0]; used[v] = k + 1
                let slot = inSlots[[u, v]]![k]
                attachments[u].append((v, inOffsets[v][slot], outOffsets[u][j]))
                attachments[v].append((u, outOffsets[u][j], inOffsets[v][slot]))
            }
        }
        for pass in 0..<4 {
            try Task.checkCancellation()
            for rank in (pass % 2 == 0 ? Array(layers.indices) : Array(layers.indices.reversed())) {
                let layer = layers[rank]
                var desired: [Float] = [], shift: [Float] = [], weights: [Float] = [], distance: Float = 0
                for (position, i) in layer.enumerated() {
                    if position > 0 { distance += (widths[layer[position - 1]] + widths[i]) / 2 + nodeSeparation }
                    shift.append(distance)
                    let targets = attachments[i].map { xs[$0.0] + $0.1 - $0.2 }
                    desired.append((targets.isEmpty ? xs[i] : targets.reduce(Float(0), +) / Float(targets.count)) - distance)
                    weights.append(i < count ? 1 : 4)
                }
                let fitted = isotonicFit(desired, weights: weights)
                for (p, i) in layer.enumerated() { xs[i] = fitted[p] + shift[p] }
            }
        }
        for i in a.nodes.indices { a.nodes[i].center = Point(x: xs[i], y: ys[ranks[i]] + heights[ranks[i]] / 2) }
        for e in graph.edges {
            var bends = (chains[e] ?? []).map { Point(x: xs[$0], y: ys[ranks[$0]] + heights[ranks[$0]] / 2) }
            if reversed.contains(e) { bends.reverse() }
            e.path = [e.source.center] + bends + [e.target.center]
        }
    }
}
func isotonicFit(_ values: [Float], weights: [Float]) -> [Float] {
    var blocks: [(start: Int, end: Int, sum: Float, weight: Float)] = []
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
