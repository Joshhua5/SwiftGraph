import Foundation

/// Shortest polyline that keeps `padding` clear of every obstacle, finished with `EdgeSeparator`.
/// Detours prefer few bends, avoid crossing routes already laid, and fan out where several share a corner.
/// Each route runs between the boundary ports `PortAssignment` chose (honouring port constraints and candidates), and
/// keeps out of its own end nodes; an edge with no clear route between its ports is tried centre to centre.
public final class PolylineEdgeRouter: EdgeRouter {
    public var padding: Float = ObstaclePolyline.defaultPadding

    /// Spreads edges sharing a collinear stretch this far apart; 0 leaves them overlapping.
    public var edgeSpacing: Float = 10

    /// Cost of a half-turn in a detour, in length units; 0 chooses the shortest path alone.
    public var bendPenalty: Float = 20

    /// Cost of crossing a routed segment in a detour, in length units; 0 ignores crossings.
    public var crossingPenalty: Float = 40

    /// Unroutable edges keep a straight centre-to-centre line (a fallback) so they stay visible; unseparated edges
    /// still share a stretch with another after separation.
    public private(set) var report = RoutingReport()

    /// Edges with no clear route; they keep a straight centre-to-centre line so they stay visible.
    @available(*, deprecated, message: "Use report.unroutable or report.unroutableEdges(in:)")
    public var unroutableEdges: [LayoutEdge] { failed }

    /// Edges that still share a stretch with another after separation (no room for lanes, or lanes would cut a node).
    @available(*, deprecated, message: "Use report.unseparated or report.unseparatedEdges(in:)")
    public var unseparatedEdges: [LayoutEdge] { cramped }

    private var failed: [LayoutEdge] = []
    private var cramped: [LayoutEdge] = []

    public init() {}

    public func routeEdges(_ graph: LayoutGraph) {
        graph.routeStyle = .polyline
        failed = []
        cramped = []
        report = RoutingReport()
        defer { report = RoutingReport(graph, unroutable: failed, unseparated: cramped, fallbacks: failed) }
        guard !graph.nodes.isEmpty else { return }
        let scene = ObstaclePolyline.Scene(graph.nodes)
        let routed = ObstaclePolyline.SegmentIndex(bounds: scene.bounds)
        let edges = graph.edges.filter { $0.source !== $0.target }
        let assigned = PortAssignment(edgeSpacing: edgeSpacing).assign(graph, style: .polyline)
        var corners: [Point: [ObstaclePolyline.Bend]] = [:]
        var used = Array(repeating: [ObstaclePolyline.Bend](), count: edges.count)
        var detoured: [Int] = []
        func route(_ i: Int) -> (path: [Point], gap: Float, bends: [ObstaclePolyline.Bend])? {
            func search(
                _ ports: (source: EdgePort, target: EdgePort)?
            ) -> (
                path: [Point], gap: Float, bends: [ObstaclePolyline.Bend]
            )? {
                scene.route(
                    edges[i],
                    padding: padding,
                    bend: bendPenalty,
                    crossing: crossingPenalty,
                    routed: routed,
                    corners: corners,
                    fan: edgeSpacing,
                    ports: ports
                )
            }
            guard let source = assigned.source(of: edges[i]), let target = assigned.target(of: edges[i]) else {
                return search(nil)
            }
            return search((source, target)) ?? search(nil)
        }
        func register(_ i: Int, _ bends: [ObstaclePolyline.Bend]) {
            for b in used[i] { corners[b.corner]?.removeAll { $0 == b } }
            for b in bends { corners[b.corner, default: []].append(b) }
            used[i] = bends
        }
        let routing = LayoutStageScope.begin("Route", to: 0.6)
        for (i, edge) in edges.enumerated() {
            if RoutingCompute.isCancelled { return }
            routing.tick(i, of: edges.count)
            let found = route(i)
            if RoutingCompute.isCancelled { return }
            if let found {
                edge.path = found.path
                register(i, found.bends)
            } else {
                failed.append(edge)
                edge.path = [edge.source.center, edge.target.center]
            }
            if edge.path.count > 2 { detoured.append(i) }
            routed.add(edge.path, owner: i)
        }
        routing.end()
        // One rip-up pass: a detour found early could not see the routes laid after it.
        if crossingPenalty > 0 {
            let ripUp = LayoutStageScope.begin("Rip-up", from: 0.6, to: 0.85)
            for (position, i) in detoured.enumerated() {
                if RoutingCompute.isCancelled { return }
                ripUp.tick(position, of: detoured.count)
                let edge = edges[i]
                let old = edge.path
                routed.remove(owner: i)
                let before = ObstaclePolyline.cost(old, bend: bendPenalty, crossing: crossingPenalty, routed: routed)
                if let found = route(i),
                    ObstaclePolyline.cost(found.path, bend: bendPenalty, crossing: crossingPenalty, routed: routed)
                        < before - 1e-4
                {
                    edge.path = found.path
                    register(i, found.bends)
                }
                routed.add(edge.path, owner: i)
            }
            ripUp.end()
        }
        if edgeSpacing > 0 {
            let separator = EdgeSeparator()
            separator.spacing = edgeSpacing
            LayoutStageScope.run("Separate", from: 0.85) { separator.separate(edges, scene) }
            cramped = separator.unseparated
        }
    }
}
