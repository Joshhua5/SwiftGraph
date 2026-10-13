import Foundation

public final class ComponentLayout: LayoutAlgorithm {
    public var coreLayout: any LayoutAlgorithm
    public var componentSpacing: Double = 50
    public var preferredAspectRatio: Double = 1
    public init(_ coreLayout: any LayoutAlgorithm) { self.coreLayout = coreLayout }
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph), components = a.components()
        if components.count == 1 { try coreLayout.applyLayout(graph); return }
        var graphs: [LayoutGraph] = [], bounds: [Rect] = []
        for component in components {
            try Task.checkCancellation()
            let g = subgraph(graph, nodes: component.map { a.nodes[$0] })
            try coreLayout.applyLayout(g)
            let b = g.bounds
            translate(g, by: Point(x: -b.x, y: -b.y)); graphs.append(g); bounds.append(b)
        }
        let width = max(200, sqrt(bounds.reduce(0.0) { $0 + $1.width * $1.height }) * max(0.01, preferredAspectRatio))
        var x = 0.0, y = 0.0, rowHeight = 0.0
        for i in graphs.indices.sorted(by: { bounds[$0].height == bounds[$1].height ? $0 < $1 : bounds[$0].height > bounds[$1].height }) {
            if x > 0 && x + bounds[i].width > width { x = 0; y += rowHeight + componentSpacing; rowHeight = 0 }
            translate(graphs[i], by: Point(x: x, y: y))
            x += bounds[i].width + componentSpacing; rowHeight = max(rowHeight, bounds[i].height)
        }
    }
}

public final class MultiPageLayoutAlgorithm: LayoutAlgorithm {
    public var pageWidth: Double = 800
    public var pageHeight: Double = 1100
    public var pageSpacing: Double = 100
    public var coreLayout: any LayoutAlgorithm
    public init(_ coreLayout: (any LayoutAlgorithm)? = nil) { self.coreLayout = coreLayout ?? HierarchicalLayoutAlgorithm() }
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let a = Adjacency(graph)
        for (i, component) in a.components().enumerated() {
            try Task.checkCancellation()
            let g = subgraph(graph, nodes: component.map { a.nodes[$0] })
            try coreLayout.applyLayout(g)
            let b = g.bounds
            translate(g, by: Point(x: Double(i % 3) * (pageWidth + pageSpacing) + (pageWidth - b.width) / 2 - b.x,
                                   y: Double(i / 3) * (pageHeight + pageSpacing) + (pageHeight - b.height) / 2 - b.y))
        }
    }
}

public final class SubgraphLayoutAlgorithm: LayoutAlgorithm {
    public var selectedNodeIds: Set<String> = []
    public var coreLayout: any LayoutAlgorithm
    public var preserveCentroid = true
    /// Clearance takes precedence over centroid preservation. Disable for legacy placement.
    public var avoidUnselectedNodes = true
    public init(_ coreLayout: any LayoutAlgorithm) { self.coreLayout = coreLayout }
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        let g = subgraph(graph, nodes: graph.nodes.filter { selectedNodeIds.contains($0.id) })
        guard !g.nodes.isEmpty else { return }
        func centroid() -> Point { g.nodes.reduce(Point.zero) { $0 + $1.center } / Double(g.nodes.count) }
        let initial = centroid()
        try coreLayout.applyLayout(g)
        if preserveCentroid { translate(g, by: initial - centroid()) }
        if avoidUnselectedNodes {
            let obstacles = graph.nodes.filter { node in
                !selectedNodeIds.contains(node.id) && !g.nodes.contains {
                    isAncestor(node, of: $0) || isAncestor($0, of: node)
                }
            }.map(\.bounds)
            var envelope = g.bounds
            for edge in g.edges {
                for p in edge.path { envelope = envelope.union(Rect(x: p.x, y: p.y)) }
                if edge.labelBounds.width > 0 { envelope = envelope.union(edge.labelBounds) }
            }
            let padded = obstacles.map { $0.inflated(by: 10) }
            if padded.contains(where: { $0.intersects(envelope) }) {
                let xs = Set([0.0] + padded.flatMap { [$0.left - envelope.right, $0.right - envelope.left] }).sorted()
                let ys = Set([0.0] + padded.flatMap { [$0.top - envelope.bottom, $0.bottom - envelope.top] }).sorted()
                var best: Point?
                for x in xs {
                    try Task.checkCancellation()
                    for y in ys {
                        let candidate = Point(x: x, y: y)
                        if let best, candidate.lengthSquared >= best.lengthSquared { continue }
                        if !padded.contains(where: { $0.intersects(envelope.translated(by: candidate)) }) { best = candidate }
                    }
                }
                if let best { translate(g, by: best) }
            }
        }
        let routing = subgraph(graph, nodes: graph.nodes)
        routing.edges = graph.edges.filter { selectedNodeIds.contains($0.source.id) != selectedNodeIds.contains($0.target.id) }
        ChannelEdgeRouter().routeEdges(routing)
        if avoidUnselectedNodes {
            ObstaclePolyline.repair(graph, edges: graph.edges.filter {
                selectedNodeIds.contains($0.source.id) || selectedNodeIds.contains($0.target.id)
            })
        }
        try Task.checkCancellation()
    }
}

public enum GraphError: Error, Equatable { case cyclicGroupHierarchy }

/// Fits nested frames bottom-up. Cores see sized ordinary-node proxies and must preserve topology.
public final class RecursiveGroupLayout: LayoutAlgorithm {
    public var coreLayout: any LayoutAlgorithm
    public var groupPadding: Double = 20
    /// Refine framed placement using incoming boundary connections after fitting the frames.
    public var optimizeIncomingEdges: Bool = true
    public var groupLayoutSelector: ((LayoutNode) -> any LayoutAlgorithm)?
    public private(set) var unroutableEdges: [LayoutEdge] = []
    public init(_ coreLayout: any LayoutAlgorithm) { self.coreLayout = coreLayout }
    public func applyLayout(_ graph: LayoutGraph) throws {
        unroutableEdges = []
        try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        let original = try GroupLayoutEngine(graph, padding: groupPadding)
        let layouts = original.groups.map { groupLayoutSelector?($0) ?? coreLayout }
        let engine = try GroupLayoutEngine(transaction.working, padding: groupPadding)
        var failures = Set<LayoutEdge>()
        for (group, layout) in zip(engine.groups, layouts) {
            try Task.checkCancellation()
            if !group.children.isEmpty {
                let projection = engine.projection(for: group)
                try layout.applyLayout(projection.graph)
                try engine.accept(projection, in: group)
            }
            let routing = engine.routingGraph(for: group)
            if !routing.edges.isEmpty {
                let router = PolylineEdgeRouter(); router.routeEdges(routing)
                failures.formUnion(router.unroutableEdges)
            }
            try engine.finish(group, routed: routing.edges)
        }
        if optimizeIncomingEdges { try engine.refineIncomingEdges(excluding: failures) }
        try transaction.commit(to: graph)
        unroutableEdges = zip(graph.edges, transaction.working.edges).compactMap { failures.contains($1) ? $0 : nil }
    }
}

public final class SwimlaneLayoutAlgorithm: LayoutAlgorithm {
    public var laneAssignment: [String: Int] = [:]
    public var laneWidth: Double = 200
    public var laneSpacing: Double = 20
    public var laneInternalPadding: Double = 20
    public var nodeVerticalSpacing: Double = 30
    public var subLayout: (any LayoutAlgorithm)?
    public private(set) var computedLanes: [(laneId: Int, x: Double, width: Double)] = []
    public init() {}
    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation(); computedLanes = []
        let a = Adjacency(graph), layers = a.layers()
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
        var x = 0.0
        for id in lanes.keys.sorted() {
            try Task.checkCancellation()
            let nodes = lanes[id]!
            let effectiveWidth: Double
            if let subLayout {
                let g = subgraph(graph, nodes: nodes)
                try subLayout.applyLayout(g)
                let b = g.bounds; effectiveWidth = max(laneWidth, b.width + 2 * laneInternalPadding)
                translate(g, by: Point(x: x + effectiveWidth / 2 - b.center.x, y: laneInternalPadding - b.y))
            } else {
                effectiveWidth = max(laneWidth, (nodes.map(\.width).max() ?? 0) + 2 * laneInternalPadding)
                var bottom = 0.0
                for n in nodes.sorted(by: { rank[a.index[$0]!] == rank[a.index[$1]!] ? a.index[$0]! < a.index[$1]! : rank[a.index[$0]!] < rank[a.index[$1]!] }) {
                    n.y = max(bottom, ys[rank[a.index[n]!]] + laneInternalPadding)
                    n.x = x + (effectiveWidth - n.width) / 2; bottom = n.bounds.bottom + nodeVerticalSpacing
                }
            }
            computedLanes.append((id, x, effectiveWidth)); x += effectiveWidth + laneSpacing
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
