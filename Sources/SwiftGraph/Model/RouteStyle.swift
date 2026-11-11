/// The shape a drawing's routes were drawn in. The router that lays the routes records it on the graph
/// (`LayoutGraph.routeStyle`), so the stages after it (repair, fallback, port distribution, moving nodes) keep that
/// shape instead of guessing it from the geometry. A single edge that had to fall back to another shape does not
/// change the style of the drawing; the stages judge that edge on its own.
public enum RouteStyle: String, CaseIterable, Codable, Sendable {
    /// Horizontal and vertical legs: channel, BSP, grouped, bus and directed routing.
    case orthogonal
    /// Horizontal, vertical and 45-degree legs.
    case octilinear
    /// Straight legs at any angle.
    case polyline
    /// Routes whose corners have been rounded.
    case curved
}

extension LayoutGraph {
    /// Whether finishing stages should treat the drawing as orthogonal: the recorded style when a router set one,
    /// otherwise the old inference from `edges` (every route axis-aligned and at least one with a bend).
    func isOrthogonalDrawing(_ edges: [LayoutEdge]) -> Bool {
        if let routeStyle { return routeStyle == .orthogonal }
        return edges.allSatisfy { isRectilinear($0.path) } && edges.contains { $0.path.count >= 3 }
    }
}

/// Whether every leg of `path` is horizontal or vertical.
func isRectilinear(_ path: [Point]) -> Bool {
    zip(path, path.dropFirst()).allSatisfy { abs($0.x - $1.x) < 1e-5 || abs($0.y - $1.y) < 1e-5 }
}

/// The style every one of `graphs` recorded, or nil when they differ or none recorded one.
func sharedRouteStyle(_ graphs: [LayoutGraph]) -> RouteStyle? {
    guard let first = graphs.first?.routeStyle else { return nil }
    return graphs.allSatisfy { $0.routeStyle == first } ? first : nil
}
