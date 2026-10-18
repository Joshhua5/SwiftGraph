import Foundation

/// Sugiyama layering with virtual nodes, deterministic median ordering and weighted PAV placement.
public final class HierarchicalLayoutAlgorithm: LayoutAlgorithm {
    public var layerSeparation: Float = 50
    public var nodeSeparation: Float = 50
    public var rankSeparation: Float { get { layerSeparation } set { layerSeparation = newValue } }
    public var maxNodesPerRank: Int?
    /// Disable provisional routing when another router runs after packing or group placement.
    public var routesEdges = true
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
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
                    widths.append(0); ranks.append(rank); incoming.append([]); outgoing.append([])
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
        for sweep in 0..<4 {
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
            if !changed && sweep > 0 { break }
        }
        let heights = layers.map { layer in layer.map { $0 < count ? a.nodes[$0].height : 0 }.max() ?? 0 }
        let ys = offsets(heights, gap: layerSeparation)
        var xs = Array(repeating: Float(0), count: widths.count)
        for layer in layers {
            let gaps = zip(layer, layer.dropFirst()).map { hierarchyGap($0, $1, originals: count, separation: nodeSeparation) }
            let total = layer.reduce(Float(0)) { $0 + widths[$1] } + gaps.reduce(0, +)
            var x = -total / 2
            for (p, i) in layer.enumerated() {
                xs[i] = x + widths[i] / 2
                x += widths[i] + (p < gaps.count ? gaps[p] : 0)
            }
        }
        for pass in 0..<3 {
            try Task.checkCancellation()
            for rank in (pass % 2 == 0 ? Array(layers.indices) : Array(layers.indices.reversed())) {
                let layer = layers[rank]
                var desired: [Float] = [], shift: [Float] = [], weights: [Float] = [], distance: Float = 0
                for (position, i) in layer.enumerated() {
                    if position > 0 { distance += (widths[layer[position - 1]] + widths[i]) / 2 + hierarchyGap(layer[position - 1], i, originals: count, separation: nodeSeparation) }
                    shift.append(distance)
                    let neighbors = incoming[i] + outgoing[i]
                    desired.append((neighbors.isEmpty ? xs[i] : neighbors.reduce(Float(0)) { $0 + xs[$1] } / Float(neighbors.count)) - distance)
                    weights.append(i < count ? 1 : 4)
                }
                let fitted = isotonic(desired, weights: weights)
                for (p, i) in layer.enumerated() { xs[i] = fitted[p] + shift[p] }
            }
        }
        for i in a.nodes.indices { a.nodes[i].center = Point(x: xs[i], y: ys[ranks[i]] + heights[ranks[i]] / 2) }
        guard routesEdges else { return }
        var routed: [[Point]?] = [], flows: [Int?] = []
        for e in graph.edges {
            guard let chain = chains[e], let s = a.index[e.source], let t = a.index[e.target] else { routed.append(nil); flows.append(nil); continue }
            routed.append(chain.map { Point(x: xs[$0], y: ys[ranks[$0]] + heights[ranks[$0]] / 2) }); flows.append((ranks[t] - ranks[s]).signum())
        }
        try routeLayeredEdges(graph, chains: routed, flows: flows)
    }
}

/// Routes edges between ranks: paths leave and enter on node faces facing the layer direction, ends sharing a face are
/// spread evenly in neighbour order (so reciprocal and duplicate edges never coincide), and a segment that would cross
/// a node (including edges spanning more ranks than get virtual nodes) is detoured. `chains[i]` are the virtual-node
/// points of `graph.edges[i]` and `flows[i]` the sign of its rank change; nil entries are drawn centre to centre.
func routeLayeredEdges(_ graph: LayoutGraph, chains: [[Point]?], flows: [Int?]) throws {
    struct End { var edge: Int; var isSource: Bool; var key: Float }
    struct Face: Hashable { var node: LayoutNode; var side: PortConstraint }
    var faces: [Face: [End]] = [:]
    for (i, e) in graph.edges.enumerated() {
        guard let chain = chains[i], let flow = flows[i] else { e.path = [e.source.center, e.target.center]; continue }
        let s = e.source, t = e.target
        let sides: (PortConstraint, PortConstraint) = flow > 0 ? (.bottom, .top) : flow < 0 ? (.top, .bottom) : (t.center.x >= s.center.x ? (.right, .left) : (.left, .right))
        for (node, side, toward, isSource) in [(s, sides.0, chain.first ?? t.center, true), (t, sides.1, chain.last ?? s.center, false)] {
            faces[Face(node: node, side: side), default: []].append(End(edge: i, isSource: isSource, key: side == .top || side == .bottom ? toward.x : toward.y))
        }
    }
    var ports = Array(repeating: [Point.zero, Point.zero], count: graph.edges.count)
    for (face, ends) in faces {
        let r = face.node.bounds, sorted = ends.sorted { ($0.key, $0.edge, $0.isSource ? 0 : 1) < ($1.key, $1.edge, $1.isSource ? 0 : 1) }
        for (k, end) in sorted.enumerated() {
            let f = Float(k + 1) / Float(sorted.count + 1)
            let p: Point
            switch face.side {
            case .top: p = Point(x: r.left + r.width * f, y: r.top)
            case .bottom: p = Point(x: r.left + r.width * f, y: r.bottom)
            case .left: p = Point(x: r.left, y: r.top + r.height * f)
            default: p = Point(x: r.right, y: r.top + r.height * f)
            }
            ports[end.edge][end.isSource ? 0 : 1] = p
        }
    }
    let solid = graph.nodes.filter { $0.width > 0 && $0.height > 0 }
    let tree = QuadTree<LayoutNode>(bounds: enclosingBounds(solid).inflated(by: 1))
    for node in solid { tree.insert(bounds: node.bounds, item: node) }
    for (i, e) in graph.edges.enumerated() {
        if i % 64 == 0 { try Task.checkCancellation() }
        guard let chain = chains[i] else { continue }
        func near(_ area: Rect) -> [LayoutNode] {
            tree.query(area).filter { $0 !== e.source && $0 !== e.target && !($0.isGroup && (isAncestor($0, of: e.source) || isAncestor($0, of: e.target))) }
        }
        func route(_ points: [Point]) -> [Point] {
            var path = points, k = 0
            while k + 1 < path.count {
                let a = path[k], b = path[k + 1], box = RoutingCompute.bounds(a, b)
                if near(box.inflated(by: 0.5)).contains(where: { $0.bounds.intersectsLine(a, b) }) {
                    let window = max(40, max(box.width, box.height) / 2)
                    if let detour = ObstaclePolyline.search(a, b, near(box.inflated(by: window)).map(\.bounds), padding: 8), detour.count > 2 {
                        path.replaceSubrange(k...(k + 1), with: detour); k += detour.count - 1; continue
                    }
                }
                k += 1
            }
            return compactPath(path)
        }
        var path = route([ports[i][0]] + chain + [ports[i][1]])
        let length = ObstaclePolyline.length(path)
        if !chain.isEmpty && length > 4 * max(1, (e.target.center - e.source.center).length) {
            let direct = route([ports[i][0], ports[i][1]])
            if ObstaclePolyline.length(direct) < length * 0.75,
               ObstaclePolyline.clear(direct, near(ObstaclePolyline.bounds(direct).inflated(by: 1)).map(\.bounds)) {
                path = direct
            }
        }
        e.path = path
    }
}
private func isotonic(_ values: [Float], weights: [Float]) -> [Float] {
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

public final class SeriesParallelLayoutAlgorithm: LayoutAlgorithm {
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        // Transpose dimensions before layout, then transpose the entire drawing back.
        for n in graph.nodes { let w = n.width; n.width = n.height; n.height = w }
        do { try HierarchicalLayoutAlgorithm().applyLayout(graph) }
        catch {
            for n in graph.nodes { let w = n.width; n.width = n.height; n.height = w }
            throw error
        }
        for n in graph.nodes { n.bounds = Rect(x: n.y, y: n.x, width: n.height, height: n.width) }
        for e in graph.edges { e.path = e.path.map { Point(x: $0.y, y: $0.x) } }
    }
}
