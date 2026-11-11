import Foundation

/// Sugiyama layering with virtual nodes, deterministic median ordering and weighted PAV placement.
public final class HierarchicalLayoutAlgorithm: LayoutAlgorithm {
    /// The gap between layers. With `routesEdges`, it is a minimum: a gap whose edges need more tracks than fit is
    /// widened until they do.
    public var layerSeparation: Float = 50
    public var nodeSeparation: Float = 50

    public var rankSeparation: Float {
        get { layerSeparation }
        set { layerSeparation = newValue }
    }

    public var maxNodesPerRank: Int?

    /// Routes edges orthogonally with the shared layered router, which may widen layer gaps to fit its tracks.
    /// Disable it when another router runs after packing or group placement; layers are then exactly
    /// `layerSeparation` apart.
    public var routesEdges = true

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        let count = a.nodes.count
        guard count > 0 else { return }
        var layers = a.layers(maxWidth: maxNodesPerRank ?? .max)
        var ranks = Array(repeating: 0, count: count)
        for (r, layer) in layers.enumerated() { for i in layer { ranks[i] = r } }
        var widths = a.nodes.map(\.width)
        var incoming = Array(repeating: [Int](), count: count)
        var outgoing = incoming
        var chains: [LayoutEdge: [Int]] = [:]
        for edge in graph.edges {
            guard let s = a.index[edge.source], let t = a.index[edge.target], s != t else { continue }
            let delta = ranks[t] - ranks[s]
            let span = abs(delta)
            var chain: [Int] = []
            if span > 1 && span - 1 <= 64 {
                for step in 1..<span {
                    let v = widths.count
                    let rank = ranks[s] + step * (delta > 0 ? 1 : -1)
                    widths.append(0)
                    ranks.append(rank)
                    incoming.append([])
                    outgoing.append([])
                    layers[rank].append(v)
                    chain.append(v)
                }
            }
            chains[edge] = chain
            let path = [s] + chain + [t]
            for (u, v) in zip(path, path.dropFirst()) where abs(ranks[u] - ranks[v]) == 1 {
                let low = ranks[u] < ranks[v] ? u : v
                let high = ranks[u] < ranks[v] ? v : u
                outgoing[low].append(high)
                incoming[high].append(low)
            }
        }
        var order = Array(repeating: 0, count: widths.count)
        func updateOrder() { for layer in layers { for (p, i) in layer.enumerated() { order[i] = p } } }
        updateOrder()
        try LayoutStageScope.run("Ordering", from: 0.1, to: 0.45) {
            for sweep in 0..<4 {
                try Task.checkCancellation()
                LayoutStageScope.tick(sweep, of: 4)
                let forward = sweep % 2 == 0
                let indices = forward ? Array(layers.indices) : Array(layers.indices.reversed())
                var changed = false
                for rank in indices {
                    let old = layers[rank]
                    var medians: [Int: Float] = [:]
                    for i in old {
                        let values = (forward ? incoming[i] : outgoing[i]).map { order[$0] }.sorted()
                        if values.isEmpty {
                            medians[i] = Float(order[i])
                        } else {
                            medians[i] = Float(values[(values.count - 1) / 2] + values[values.count / 2]) / 2
                        }
                    }
                    layers[rank]
                        .sort {
                            let l = medians[required: $0]
                            let r = medians[required: $1]
                            return l == r ? order[$0] < order[$1] : l < r
                        }
                    changed = changed || old != layers[rank]
                    for (p, i) in layers[rank].enumerated() { order[i] = p }
                }
                if !changed && sweep > 0 { break }
            }
        }
        let heights = layers.map { layer in layer.map { $0 < count ? a.nodes[$0].height : 0 }.max() ?? 0 }
        let ys = offsets(heights, gap: layerSeparation)
        var xs = Array(repeating: Float(0), count: widths.count)
        for layer in layers {
            let gaps = zip(layer, layer.dropFirst())
                .map { hierarchyGap($0, $1, originals: count, separation: nodeSeparation) }
            let total = layer.reduce(Float(0)) { $0 + widths[$1] } + gaps.reduce(0, +)
            var x = -total / 2
            for (p, i) in layer.enumerated() {
                xs[i] = x + widths[i] / 2
                x += widths[i] + (p < gaps.count ? gaps[p] : 0)
            }
        }
        try LayoutStageScope.run("Coordinates", from: 0.45, to: 0.7) {
            for pass in 0..<3 {
                try Task.checkCancellation()
                LayoutStageScope.tick(pass, of: 3)
                for rank in (pass % 2 == 0 ? Array(layers.indices) : Array(layers.indices.reversed())) {
                    let layer = layers[rank]
                    var desired: [Float] = []
                    var shift: [Float] = []
                    var weights: [Float] = []
                    var distance: Float = 0
                    for (position, i) in layer.enumerated() {
                        if position > 0 {
                            distance +=
                                (widths[layer[position - 1]] + widths[i]) / 2
                                + hierarchyGap(layer[position - 1], i, originals: count, separation: nodeSeparation)
                        }
                        shift.append(distance)
                        let neighbors = incoming[i] + outgoing[i]
                        desired.append(
                            (neighbors.isEmpty
                                ? xs[i] : neighbors.reduce(Float(0)) { $0 + xs[$1] } / Float(neighbors.count))
                                - distance
                        )
                        weights.append(i < count ? 1 : 4)
                    }
                    let fitted = isotonic(desired, weights: weights)
                    for (p, i) in layer.enumerated() { xs[i] = fitted[p] + shift[p] }
                }
            }
        }
        for i in a.nodes.indices { a.nodes[i].center = Point(x: xs[i], y: ys[ranks[i]] + heights[ranks[i]] / 2) }
        guard routesEdges else { return }
        var routed: [[Point]?] = []
        var flows: [Int?] = []
        for e in graph.edges {
            guard let chain = chains[e], let s = a.index[e.source], let t = a.index[e.target] else {
                routed.append(nil)
                flows.append(nil)
                continue
            }
            routed.append(chain.map { Point(x: xs[$0], y: ys[ranks[$0]] + heights[ranks[$0]] / 2) })
            flows.append((ranks[t] - ranks[s]).signum())
        }
        try LayoutStageScope.run("Route edges", from: 0.7) {
            try routeLayeredEdges(graph, chains: routed, flows: flows, layerSeparation: layerSeparation)
        }
    }
}

/// Routes a top-to-bottom layered drawing with the shared `LayeredRouter`. Its tracks are planned per rank gap, and a
/// gap whose tracks need more room than `layerSeparation` is widened by moving the ranks below it down; nothing moves
/// across the flow. `chains[i]` are the virtual-node points of `graph.edges[i]` and `flows[i]` the sign of its rank
/// change (0 for an edge within one rank); nil entries, self-loops and edges into or out of a group that contains
/// other nodes of the drawing are drawn centre to centre, as before. An edge the router cannot route gets the
/// orthogonal `RoutingFallback`.
func routeLayeredEdges(_ graph: LayoutGraph, chains: [[Point]?], flows: [Int?], layerSeparation: Float) throws {
    let nodes = LayeredRouter.obstacleNodes(of: graph)
    let members = Set(nodes)
    var routed: [LayoutEdge] = []
    var feedback = Set<LayoutEdge>()
    for (i, edge) in graph.edges.enumerated() {
        guard let chain = chains[i], let flow = flows[i], edge.source !== edge.target,
            members.contains(edge.source), members.contains(edge.target)
        else { continue }
        edge.path = [edge.source.center] + chain + [edge.target.center]
        routed.append(edge)
        if flow == 0 { feedback.insert(edge) }
    }
    var configuration = LayeredRoutingConfiguration()
    configuration.minimumRankGap = layerSeparation
    configuration.readsPortConstraints = false
    try LayeredRouter.routeDrawing(
        nodes: nodes,
        edges: routed,
        feedback: feedback,
        flow: .topToBottom,
        respacesRanks: true,
        configuration: configuration
    )
    // Layered routes are orthogonal; the fallback keeps that shape.
    graph.routeStyle = .orthogonal
    let routedEdges = Set(routed)
    for edge in graph.edges {
        if !routedEdges.contains(edge) {
            edge.path = [edge.source.center, edge.target.center]
        } else if edge.path.count < 2 {
            edge.path = RoutingFallback.route(edge, graph)
        }
    }
}

private func isotonic(_ values: [Float], weights: [Float]) -> [Float] {
    var blocks: [(start: Int, end: Int, sum: Float, weight: Float)] = []
    for i in values.indices {
        blocks.append((i, i, values[i] * weights[i], weights[i]))
        while blocks.count > 1 {
            let last = blocks[blocks.count - 1]
            let prev = blocks[blocks.count - 2]
            if prev.sum / prev.weight <= last.sum / last.weight { break }
            blocks.removeLast()
            blocks.removeLast()
            blocks.append((prev.start, last.end, prev.sum + last.sum, prev.weight + last.weight))
        }
    }
    var result = values
    for block in blocks { for i in block.start...block.end { result[i] = block.sum / block.weight } }
    return result
}
