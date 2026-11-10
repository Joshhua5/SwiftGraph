import Foundation

public final class SwimlaneLayoutAlgorithm: LayoutAlgorithm {
    public var laneAssignment: [String: Int] = [:]
    public var laneWidth: Float = 200
    public var laneSpacing: Float = 20
    public var laneInternalPadding: Float = 20
    public var nodeVerticalSpacing: Float = 30
    public var subLayout: (any LayoutAlgorithm)?
    public private(set) var computedLanes: [(laneId: Int, x: Float, width: Float)] = []

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        computedLanes = []
        let a = Adjacency(graph)
        let layers = a.layers()
        var rank = Array(repeating: 0, count: a.nodes.count)
        for (r, layer) in layers.enumerated() { for i in layer { rank[i] = r } }
        let targetLanes = max(1, Int(ceil(sqrt(Double(a.nodes.count)))))
        let ranksPerLane = max(1, Int(ceil(Double(layers.count) / Double(targetLanes))))
        var lanes: [Int: [LayoutNode]] = [:]
        for (i, n) in a.nodes.enumerated() {
            let lane = laneAssignment.isEmpty ? rank[i] / ranksPerLane : laneAssignment[n.id, default: 0]
            lanes[lane, default: []].append(n)
        }
        let heights = layers.map { $0.map { a.nodes[$0].height }.max() ?? 0 }
        let ys = offsets(heights, gap: nodeVerticalSpacing)
        var x: Float = 0.0
        let ids = lanes.keys.sorted()
        for (index, id) in ids.enumerated() {
            try Task.checkCancellation()
            let nodes = lanes[required: id]
            let effectiveWidth: Float
            if let subLayout {
                let g = subgraph(graph, nodes: nodes)
                try LayoutStageScope.run("Lane \(index + 1)/\(ids.count)", part: index, of: ids.count) {
                    try subLayout.applyLayout(g)
                }
                let b = g.bounds
                effectiveWidth = max(laneWidth, b.width + 2 * laneInternalPadding)
                translate(g, by: Point(x: x + effectiveWidth / 2 - b.center.x, y: laneInternalPadding - b.y))
            } else {
                effectiveWidth = max(laneWidth, (nodes.map(\.width).max() ?? 0) + 2 * laneInternalPadding)
                var bottom: Float = 0.0
                for n in nodes.sorted(by: {
                    rank[a.index[required: $0]] == rank[a.index[required: $1]]
                        ? a.index[required: $0] < a.index[required: $1]
                        : rank[a.index[required: $0]] < rank[a.index[required: $1]]
                }) {
                    n.y = max(bottom, ys[rank[a.index[required: n]]] + laneInternalPadding)
                    n.x = x + (effectiveWidth - n.width) / 2
                    bottom = n.bounds.bottom + nodeVerticalSpacing
                }
            }
            computedLanes.append((id, x, effectiveWidth))
            x += effectiveWidth + laneSpacing
        }
        for e in graph.edges where e.source !== e.target {
            if abs(e.source.center.y - e.target.center.y) < nodeVerticalSpacing / 2 {
                e.sourcePort = e.source.center.x < e.target.center.x ? .right : .left
                e.targetPort = e.sourcePort == .right ? .left : .right
            } else {
                e.sourcePort = e.source.center.y < e.target.center.y ? .bottom : .top
                e.targetPort = e.sourcePort == .bottom ? .top : .bottom
            }
        }
    }
}
