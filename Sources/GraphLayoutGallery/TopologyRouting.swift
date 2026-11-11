import Foundation
import SwiftGraph
import SwiftGraphUI

/// Edge routing applied after placement. `.layoutDefault` keeps a preset's own routes
/// (or polyline for bare algorithms); anything else re-routes the placed graph.
enum TopologyRouting: String, CaseIterable, Hashable, Sendable, Identifiable {
    case layoutDefault = "Layout Default"
    case straight = "Straight"
    case polyline = "Polyline"
    case channel = "Orthogonal Channel"
    case orthogonalGrouped = "Orthogonal Grouped"
    case bsp = "BSP"
    case octilinear = "Octilinear"
    case bundled = "Bundled"
    case curves = "Curve Fitting"

    var id: String { rawValue }

    /// Port distribution and the channel router's separation pass are skipped above this edge count; both are
    /// too slow on large topologies.
    private static let finishingEdgeLimit = 150

    /// The geometry this choice produces. `.layoutDefault` keeps the layout's own routes, whose style the graph
    /// does not record yet, so it is finished as polyline.
    var style: RouteStyle {
        switch self {
        case .layoutDefault, .polyline, .bundled: .polyline
        case .straight: .straight
        case .channel, .orthogonalGrouped, .bsp: .orthogonal
        case .octilinear: .octilinear
        case .curves: .curved
        }
    }

    func apply(to builder: LayoutBuilder, after layout: TopologyLayout, backend: LayoutBackend = .cpu) {
        switch self {
        case .layoutDefault:
            if case .preset = layout { return }
        case .straight:
            builder.transform { graph in
                for edge in graph.edges { edge.path = [edge.source.center, edge.target.center] }
            }
        case .polyline, .curves:
            builder.routePolyline(backend: backend)
        case .channel:
            builder.routeChannel(backend: backend)
                .transformAsync { graph in
                    guard graph.edges.count <= Self.finishingEdgeLimit else { return }
                    try await RoutingLayoutOperation(.edgeSeparation, backend: backend).applyLayoutAsync(graph)
                }
        // BSP and grouped routing separate their own lanes.
        case .orthogonalGrouped:
            builder.routeOrthogonalGrouped(backend: backend)
        case .bsp:
            builder.routeBsp(backend: backend)
        case .octilinear:
            builder.routeOctilinear(backend: backend)
        case .bundled:
            builder.routePolyline(backend: backend).routeWithBundling(backend: backend)
        }
        builder.finishRoutes(style: style, backend: backend, portDistributionLimit: Self.finishingEdgeLimit)
    }
}
