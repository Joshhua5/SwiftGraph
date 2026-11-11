import Foundation

/// The geometry a drawing's routes are meant to have.
///
/// Finishing reads it to decide which stages apply, so a stage never has to infer the style from the routes.
public enum RouteStyle: String, CaseIterable, Hashable, Sendable {
    /// Straight segments from end to end; finishing leaves blocked routes straight rather than adding bends.
    case straight
    /// Horizontal and vertical segments only.
    case orthogonal
    /// Horizontal, vertical and 45-degree segments.
    case octilinear
    /// Free-angle segments.
    case polyline
    /// Polyline routes whose corners finishing rounds into arcs.
    case curved
}
