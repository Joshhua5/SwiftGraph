import Foundation

/// The CPU algorithms retain their ordered searches, port rules and hierarchy behavior. Metal
/// accelerates geometry stages; it does not replace them with a different routing algorithm.
public enum RoutingKind: String, CaseIterable, Sendable {
    case polyline, channel, bus, octilinear, bsp, orthogonalGrouped, parallelEdges
    case edgeSeparation, selfLoops, curveFitting, endpointClipping, labelPlacement, labelLayout, givenCoordinates
}
