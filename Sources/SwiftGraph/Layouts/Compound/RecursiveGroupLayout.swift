import Foundation

/// Fits nested frames bottom-up. Cores see sized ordinary-node proxies and must preserve topology.
public final class RecursiveGroupLayout: LayoutAlgorithm {
    public var coreLayout: any LayoutAlgorithm
    public var groupPadding: Float = 20

    /// Refine framed placement using incoming boundary connections after fitting the frames.
    public var optimizeIncomingEdges: Bool = true

    /// Disable group-level polyline routing when a separate router runs after group placement.
    public var routesEdges: Bool = true
    public var groupLayoutSelector: ((LayoutNode) -> any LayoutAlgorithm)?
    public private(set) var unroutableEdges: [LayoutEdge] = []
    /// `unroutableEdges` as indices into the laid-out graph's edges, in the shape every router reports.
    public private(set) var report = RoutingReport()
    var presetRouting: ((LayoutGraph) -> [LayoutEdge])?

    public init(_ coreLayout: any LayoutAlgorithm) { self.coreLayout = coreLayout }

    public func applyLayout(_ graph: LayoutGraph) throws {
        unroutableEdges = []
        report = RoutingReport()
        try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        let original = try GroupLayoutEngine(graph, padding: groupPadding)
        let layouts = original.groups.map { groupLayoutSelector?($0) ?? coreLayout }
        let engine = try GroupLayoutEngine(transaction.working, padding: groupPadding)
        var failures = Set<LayoutEdge>()
        let groupShare = optimizeIncomingEdges && routesEdges ? 0.9 : 1.0
        let slices = LayoutStageScope.slices(engine.groups.map { Double($0.children.count + 1) })
        for (index, (group, layout)) in zip(engine.groups, layouts).enumerated() {
            try Task.checkCancellation()
            if !group.children.isEmpty {
                let projection = engine.projection(for: group)
                try LayoutStageScope.run(
                    "Group \(index + 1)/\(engine.groups.count)",
                    from: groupShare * slices[index].from,
                    to: groupShare * slices[index].to
                ) {
                    try layout.applyLayout(projection.graph)
                }
                try engine.accept(projection, in: group)
            }
            let routing = engine.routingGraph(for: group, allOwnedEdges: presetRouting != nil)
            if !routing.edges.isEmpty {
                if let presetRouting {
                    failures.formUnion(presetRouting(routing))
                } else if routesEdges {
                    failures.formUnion(PolylineEdgeRouter().route(routing).unroutableEdges(in: routing))
                } else {
                    for edge in routing.edges where edge.path.count < 2 {
                        edge.path = [edge.source.center, edge.target.center]
                    }
                }
            }
            try engine.finish(group, routed: routing.edges)
        }
        if optimizeIncomingEdges && routesEdges {
            try LayoutStageScope.run("Incoming edges", from: groupShare) {
                try engine.refineIncomingEdges(excluding: failures)
            }
        }
        try transaction.commit(to: graph)
        unroutableEdges = zip(graph.edges, transaction.working.edges).compactMap { failures.contains($1) ? $0 : nil }
        report = RoutingReport(graph, unroutable: unroutableEdges)
    }
}
