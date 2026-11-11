public protocol EdgeRouter {
    func routeEdges(_ graph: LayoutGraph)

    /// What the last `routeEdges` call could not do; see `RoutingReport`.
    var report: RoutingReport { get }
}

public typealias ILayoutAlgorithm = LayoutAlgorithm

public typealias IEdgeRouter = EdgeRouter
