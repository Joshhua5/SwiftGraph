import Foundation

/// Keeps the largest connected component in place and shelves every other component in rows directly below it,
/// no wider than that component (or the widest component shelved).
func packAroundLargestComponent(_ graph: LayoutGraph, spacing: Float = 40) {
    let a = Adjacency(graph)
    let components = a.components()
    guard components.count > 1,
        let main = components.indices.max(by: {
            components[$0].count == components[$1].count ? $0 > $1 : components[$0].count < components[$1].count
        })
    else { return }
    let anchor = enclosingBounds(components[main].map { a.nodes[$0] })
    let others = components.indices.filter { $0 != main }
    let bounds = Dictionary(
        uniqueKeysWithValues: others.map { ($0, enclosingBounds(components[$0].map { a.nodes[$0] })) }
    )
    let rowWidth = max(anchor.width, others.map { bounds[required: $0].width }.max() ?? 0)
    var x: Float = 0
    var y = anchor.bottom + spacing
    var rowHeight: Float = 0
    for c in others.sorted(by: { first, second in
        let firstHeight = bounds[required: first].height
        let secondHeight = bounds[required: second].height
        return firstHeight == secondHeight ? first < second : firstHeight > secondHeight
    }) {
        let b = bounds[required: c]
        if x > 0 && x + b.width > rowWidth {
            x = 0
            y += rowHeight + spacing
            rowHeight = 0
        }
        let shift = Point(x: anchor.x + x - b.x, y: y - b.y)
        for i in components[c] { a.nodes[i].center = a.nodes[i].center + shift }
        x += b.width + spacing
        rowHeight = max(rowHeight, b.height)
    }
}

/// Moves each node with a single neighbour back along the line from that neighbour to the first position where it
/// is `gap` clear of every other node. A leaf never moves further away than it already is.
func pullLeavesToNeighbours(_ graph: LayoutGraph, gap: Float = 40) {
    let a = Adjacency(graph)
    for i in a.nodes.indices {
        let neighbours = Set(a.neighbors[i])
        guard neighbours.count == 1, let n = neighbours.first else { continue }
        let leaf = a.nodes[i]
        let c = a.nodes[n].center
        let offset = leaf.center - c
        let distance = offset.length
        guard distance > 1e-3 else { continue }
        let u = offset / distance
        let hw = leaf.width / 2 + gap
        let hh = leaf.height / 2 + gap
        var intervals: [(Float, Float)] = []
        for (k, other) in a.nodes.enumerated() where k != i {
            let r = other.bounds
            var lower = -Float.infinity
            var upper = Float.infinity
            for (origin, velocity, low, high) in [
                (c.x, u.x, r.left - hw, r.right + hw), (c.y, u.y, r.top - hh, r.bottom + hh),
            ] {
                if abs(velocity) < 1e-7 {
                    if origin <= low || origin >= high { upper = -.infinity }
                } else {
                    let p = (low - origin) / velocity
                    let q = (high - origin) / velocity
                    lower = max(lower, min(p, q))
                    upper = min(upper, max(p, q))
                }
            }
            if lower < upper && upper > 0 { intervals.append((lower, upper)) }
        }
        var t: Float = 0
        for (lower, upper) in intervals.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 })
        where t >= lower && t <= upper {
            t = upper.nextUp
        }
        if t < distance { leaf.center = c + u * t }
    }
}

func positionNetworkHubs(_ graph: LayoutGraph, hubCount: Int) {
    let hubs = graph.nodes.enumerated()
        .sorted {
            let l = $0.element.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0
            let r = $1.element.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0
            return l == r ? $0.offset < $1.offset : l > r
        }
        .prefix(max(0, hubCount)).map(\.element)
    let minimum = min(Float(300), Float(max(1, graph.nodes.count)) * 25)
    let angles = hubs.indices.map { 2 * Float.pi * Float($0) / Float(hubs.count) }
    let radius =
        hubs.count > 1
        ? Float(
            rectangleCircleRadius(
                hubs.map(\.bounds),
                angles: angles.map(Double.init),
                gap: 20,
                minimum: Double(minimum)
            )
        )
        .nextUp : 0
    for (i, hub) in hubs.enumerated() {
        hub.metadata[GraphMetadataKeys.fixed] = true
        let angle = angles[i]
        hub.center = Point(x: radius * cos(angle), y: radius * sin(angle))
    }
    let fixed = Set(hubs)
    for node in graph.nodes { node.metadata[GraphMetadataKeys.layoutSubset] = !fixed.contains(node) }
}

func networkPlacement(_ graph: LayoutGraph, hubCount: Int, iterations: Int) throws {
    try PageRankAlgorithm().applyLayout(graph)
    let old = graph.nodes.map { ($0.metadata[GraphMetadataKeys.fixed], $0.metadata[GraphMetadataKeys.layoutSubset]) }
    defer {
        for (node, values) in zip(graph.nodes, old) {
            node.metadata[GraphMetadataKeys.fixed] = values.0
            node.metadata[GraphMetadataKeys.layoutSubset] = values.1
        }
    }
    positionNetworkHubs(graph, hubCount: hubCount)
    let organic = OrganicLayoutAlgorithm()
    organic.scope = .subset
    organic.iterations = Float(iterations)
    try organic.applyLayout(graph)
}
