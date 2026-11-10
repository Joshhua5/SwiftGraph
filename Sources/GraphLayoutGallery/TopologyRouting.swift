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

    private func separateEdgesIfSmall(_ builder: LayoutBuilder, backend: LayoutBackend) {
        builder.transformAsync { graph in
            guard graph.edges.count <= 150 else { return }
            try await RoutingLayoutOperation(.edgeSeparation, backend: backend).applyLayoutAsync(graph)
        }
    }

    func apply(to builder: LayoutBuilder, after layout: TopologyLayout, backend: LayoutBackend = .cpu) {
        switch self {
        case .layoutDefault:
            if case .preset = layout { return }
            builder.routeSelfLoops(backend: backend).clipEdgeEndpoints(backend: backend)
                .transform { if $0.edges.count <= 150 { PortDistributor().routeEdges($0) } }
            return
        case .straight:
            builder.transform { graph in
                for edge in graph.edges { edge.path = [edge.source.center, edge.target.center] }
            }
        case .polyline:
            builder.routePolyline(backend: backend)
        case .channel:
            builder.routeChannel(backend: backend)
            separateEdgesIfSmall(builder, backend: backend)
        case .orthogonalGrouped:
            builder.routeOrthogonalGrouped(backend: backend)
            separateEdgesIfSmall(builder, backend: backend)
        case .bsp:
            builder.routeBsp(backend: backend)
            separateEdgesIfSmall(builder, backend: backend)
        case .octilinear:
            builder.routeOctilinear(backend: backend)
        case .bundled:
            builder.routePolyline(backend: backend).routeWithBundling(backend: backend)
        case .curves:
            builder.routePolyline(backend: backend).clipEdgeEndpoints(backend: backend)
                .transform { if $0.edges.count <= 150 { PortDistributor().routeEdges($0) } }
                .routeCurveFitting(backend: backend)
            builder.routeSelfLoops(backend: backend).clipEdgeEndpoints(backend: backend)
            return
        }
        builder.routeSelfLoops(backend: backend).clipEdgeEndpoints(backend: backend)
            .transform { if $0.edges.count <= 150 { PortDistributor().routeEdges($0) } }
    }
}
