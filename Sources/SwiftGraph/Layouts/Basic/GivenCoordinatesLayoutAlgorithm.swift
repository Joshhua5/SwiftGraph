import Foundation

public final class GivenCoordinatesLayoutAlgorithm: LayoutAlgorithm {
    public var edgeRouter: any EdgeRouter = PolylineEdgeRouter()

    public init() {}

    public func applyLayout(_ graph: LayoutGraph) throws {
        try Task.checkCancellation()
        edgeRouter.routeEdges(graph)
    }
}
