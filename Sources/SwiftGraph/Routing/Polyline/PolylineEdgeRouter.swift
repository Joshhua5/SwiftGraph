import Foundation

/// Shortest polyline that keeps `padding` clear of every obstacle, finished with `EdgeSeparator`.
/// Detours prefer few bends, avoid crossing routes already laid, and fan out where several share a corner.
/// Each route runs between the boundary ports `PortAssignment` chose (honouring port constraints and candidates), and
/// keeps out of its own end nodes; an edge with no clear route between its ports is tried centre to centre.
/// Edges are laid longest first; detours that later routes cross more often are then rerouted against all of them.
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

    /// Rip-up passes after the first; a pass that moves nothing ends them early.
    private static let ripUpPasses = 2

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
        // Crossings each route had with the routes present when it was laid.
        var laid = Array(repeating: 0, count: edges.count)
        func crossings(_ path: [Point]) -> Int {
            zip(path, path.dropFirst()).reduce(0) { $0 + routed.crossings($1.0, $1.1) }
        }
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
        // Longest first, so the result hardly depends on `graph.edges` order (which only breaks ties). A long edge
        // crosses the most and has the dearest detours; a short one laid later steps round it cheaply. Shortest
        // first raised crossings by about a quarter on the 300-edge topology.
        let order = edges.indices.sorted {
            let a = (edges[$0].target.center - edges[$0].source.center).length
            let b = (edges[$1].target.center - edges[$1].source.center).length
            return (-a, $0) < (-b, $1)
        }
        let routing = LayoutStageScope.begin("Route", to: 0.6)
        for (position, i) in order.enumerated() {
            let edge = edges[i]
            if RoutingCompute.isCancelled { return }
            routing.tick(position, of: edges.count)
            let found = route(i)
            if RoutingCompute.isCancelled { return }
            if let found {
                edge.path = found.path
                register(i, found.bends)
            } else {
                failed.append(edge)
                edge.path = [edge.source.center, edge.target.center]
            }
            if crossingPenalty > 0 { laid[i] = crossings(edge.path) }
            routed.add(edge.path, owner: i)
        }
        routing.end()
        failed = edges.filter { edge in failed.contains { $0 === edge } }
        // Rip-up: a detour laid early could not see the routes laid after it. Only detours that later routes now
        // cross more often are reconsidered: for any other, every alternative has only become dearer. A clear
        // straight route is never replaced (the search returns it outright); letting crossings send it round
        // obstacles added crossings and bends overall on the 300-edge topology, as the detours met the separator.
        if crossingPenalty > 0 {
            let ripUp = LayoutStageScope.begin("Rip-up", from: 0.6, to: 0.85)
            for pass in 0..<Self.ripUpPasses {
                var moved = false
                for (position, i) in order.enumerated() {
                    if RoutingCompute.isCancelled { return }
                    ripUp.tick(pass * edges.count + position, of: Self.ripUpPasses * edges.count)
                    let edge = edges[i]
                    let old = edge.path
                    guard old.count > 2 else { continue }
                    routed.remove(owner: i)
                    let now = crossings(old)
                    if now > laid[i] {
                        func cost(_ path: [Point]) -> Float {
                            ObstaclePolyline.cost(path, bend: bendPenalty, crossing: crossingPenalty, routed: routed)
                        }
                        if let found = route(i), cost(found.path) < cost(old) - 1e-4 {
                            edge.path = found.path
                            register(i, found.bends)
                            moved = true
                        }
                        laid[i] = edge.path == old ? now : crossings(edge.path)
                    }
                    routed.add(edge.path, owner: i)
                }
                if !moved { break }
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
