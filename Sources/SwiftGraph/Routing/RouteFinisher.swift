import Foundation

/// A stage that adjusts routes already on the graph instead of searching for new ones.
///
/// Separating lanes, distributing ports, rounding corners and looping self-edges all need routes to exist, so they run
/// after a router. Finishers still conform to `EdgeRouter`, so code holding them as `any EdgeRouter` keeps compiling,
/// but new code that only needs to adjust routes should take a `RouteFinisher`. `routeEdges` on a finisher is the same
/// call as `finishRoutes`.
public protocol RouteFinisher {
    /// Adjusts the routes of `graph`, replacing edge paths in place.
    func finishRoutes(_ graph: LayoutGraph)

    /// What the last `finishRoutes` call could not do; see `RoutingReport`.
    var report: RoutingReport { get }
}

extension RouteFinisher {
    /// Finishes `graph`'s routes and returns what the pass could not do; the same report stays available as `report`.
    @discardableResult
    public func finish(_ graph: LayoutGraph) -> RoutingReport {
        finishRoutes(graph)
        return report
    }
}
