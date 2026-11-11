import Foundation

extension LayeredRouter {
    /// Routes a placed layered drawing whose ranks follow `flow`, then runs the refinement passes the directed
    /// layout runs on the drawing it keeps.
    ///
    /// Without `respacesRanks`, the nodes stay put and each corridor's tracks are spread across the gap the placement
    /// left. With it, the coordinated strategy also runs: it plans every corridor's tracks together and moves each
    /// rank along the flow so its corridors are as wide as their tracks need, never narrower than
    /// `configuration.minimumRankGap`; nodes move only along the flow, and ranks keep their order. As in the directed
    /// layout, routing the placement as it is competes with it, but only when the coordinated drawing has a hard
    /// defect (a missing route, an overlap or a shared run); the better-scoring drawing is kept.
    ///
    /// Each edge's `path` must hold its rank chain on entry: the source centre, one point per rank it crosses, then
    /// the target centre. An edge whose chain does not match the ranks is still routed, without a corridor guide.
    /// `feedback` edges join nodes of one rank and leave from the sides facing across the flow. An edge left with
    /// an empty path could not be routed.
    static func routeDrawing(
        nodes: [LayoutNode],
        edges: [LayoutEdge],
        feedback: Set<LayoutEdge>,
        flow: LayeredFlow,
        respacesRanks: Bool,
        configuration: LayeredRoutingConfiguration = .init(),
        pitch: Float = 12
    ) throws {
        var configuration = configuration
        configuration.previousPaths = flow.inRouterFrame(configuration.previousPaths)
        let edgeIndices = Dictionary(uniqueKeysWithValues: edges.enumerated().map { ($0.element, $0.offset) })
        func router() -> LayeredRouter {
            LayeredRouter(
                nodes: nodes,
                edges: edges,
                feedback: feedback,
                edgeIndices: edgeIndices,
                configuration: configuration,
                pitch: pitch
            )
        }
        func measure() throws -> DirectedGeometry.Score {
            try DirectedGeometry.measure(nodes: nodes, edges: edges, spacing: configuration.edgeSpacing)
        }
        func routeCoordinated() throws {
            let placement = nodes.map(\.bounds)
            let guides = edges.map(\.path)
            try router().route(coordinated: true)
            let score = try measure()
            // A coordinated drawing with a hard defect competes with routing the placement as it is, which the
            // directed layout always tries. Doing so only on a defect keeps narrow, crowded gaps from paying for
            // the slower per-edge search on every drawing.
            guard score.missing + score.overlaps + score.shared > 0 else { return }
            let coordinated = (bounds: nodes.map(\.bounds), paths: edges.map(\.path))
            for (node, bounds) in zip(nodes, placement) { node.bounds = bounds }
            for (edge, guide) in zip(edges, guides) { edge.path = guide }
            try router().route(coordinated: false)
            guard !(try measure()).precedes(score) else { return }
            for (node, bounds) in zip(nodes, coordinated.bounds) { node.bounds = bounds }
            for (edge, path) in zip(edges, coordinated.paths) { edge.path = path }
        }
        try flow.inRouterFrame(nodes: nodes, edges: edges) {
            if respacesRanks && !configuration.keepsPreviousRoutes {
                try routeCoordinated()
            } else {
                try router().route(coordinated: false)
            }
            guard !configuration.keepsPreviousRoutes else { return }
            // `route` refines only drawings that keep earlier routes; a fresh one gets the passes the directed
            // layout runs after choosing its drawing.
            let refinement = router()
            try refinement.refine()
            try refinement.improveWorstRoutes()
            try refinement.polish()
        }
    }

    /// `graph`'s nodes less the groups that contain other nodes of `graph`: a group with members in the drawing is
    /// their frame, not an obstacle to their routes.
    static func obstacleNodes(of graph: LayoutGraph) -> [LayoutNode] {
        var containers = Set<LayoutNode>()
        for node in graph.nodes {
            var ancestor = node.parent
            while let current = ancestor, containers.insert(current).inserted { ancestor = current.parent }
        }
        return graph.nodes.filter { !containers.contains($0) }
    }
}
