import Foundation

/// The stages that run after a router, in the one order every preset, helper and consumer shares.
///
/// The order is self-loops, repair, endpoint clipping, port distribution, then curve fitting. Self-loops come first
/// so repair and port distribution see them. Curves come last so they round the corners of the final routes, with
/// the ports already in place; curve fitting keeps both end segments' directions and leaves a corner sharp when its
/// arc would touch a node, so nothing after it needs repairing.
public enum RouteFinishing {
    /// Curve subdivision depth used when the caller does not choose one.
    public static let defaultCurveIterations = 2

    /// Finishes the graph's routes for one style.
    ///
    /// - Parameters:
    ///   - graph: The routed graph; its edge paths are replaced.
    ///   - style: The geometry the routes are meant to have.
    ///   - curveIterations: Subdivision depth for `.curved`; ignored for other styles.
    ///   - portDistributionLimit: Port distribution is skipped when the graph has more edges than this. Nil always
    ///     distributes.
    /// - Returns: The edges repair could not clear of nodes.
    @discardableResult
    public static func finish(
        _ graph: LayoutGraph,
        style: RouteStyle,
        curveIterations: Int = defaultCurveIterations,
        portDistributionLimit: Int? = nil
    ) -> [LayoutEdge] {
        SelfLoopRouter().finishRoutes(graph)
        let failed = repair(graph, style: style)
        EdgeEndpointClipper.clipToNodeBounds(graph)
        if distributesPorts(graph, limit: portDistributionLimit) { PortDistributor().finishRoutes(graph) }
        if style == .curved {
            let curves = CurveFittingEdgeRouter()
            curves.iterations = curveIterations
            curves.finishRoutes(graph)
        }
        return failed
    }

    /// Reroutes routes that cross a node, and shortens clear detours far longer than the direct distance.
    ///
    /// Straight routes are left alone: repair would add the bends the style rules out.
    static func repair(_ graph: LayoutGraph, style: RouteStyle) -> [LayoutEdge] {
        guard style != .straight else { return [] }
        return ObstaclePolyline.repair(graph, spacing: 0, shortenDetours: true)
    }

    static func distributesPorts(_ graph: LayoutGraph, limit: Int?) -> Bool {
        guard let limit else { return true }
        return graph.edges.count <= limit
    }
}
