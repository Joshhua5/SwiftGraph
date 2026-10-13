/// Backend-aware routing helpers preserve the selected router's configuration and
/// report its actual GPU and CPU stages through the pipeline execution records.
public extension LayoutBuilder {
    @discardableResult func routePolyline(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(.polyline, backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func routeChannel(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(.channel, backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func routeBus(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(.bus, backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func routeOctilinear(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(.octilinear, backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func routeParallelEdges(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(.parallelEdges, backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func separateEdges(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(.edgeSeparation, backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func routeSelfLoops(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(.selfLoops, backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func routeCurveFitting(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(.curveFitting, backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func routeBsp(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(.bsp, backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func routeOrthogonalGrouped(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(.orthogonalGrouped, backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func layoutLabels(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(.labelLayout, backend: backend, executor: executor, configure: configure)
    }
    @discardableResult func clipEdgeEndpoints(backend: LayoutBackend, executor: LayoutExecutor = .shared) -> Self {
        routeEdges(.endpointClipping, backend: backend, executor: executor)
    }
    /// Port distribution is exact CPU geometry; the backend arguments keep the preset signatures uniform.
    @discardableResult func distributePorts(backend: LayoutBackend, executor: LayoutExecutor = .shared) -> Self { distributePorts() }
    @discardableResult func placeLabels(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        labelProvider: ((LayoutEdge) -> String?)? = nil) -> Self {
        let operation = RoutingLayoutOperation(.labelPlacement, backend: backend, executor: executor)
        if let labelProvider { operation.labelProvider = labelProvider }
        return useAsyncAlgorithm(operation)
    }
    /// Given coordinates have no node-placement phase. Select the desired stock
    /// router while preserving the graph's existing node geometry.
    @discardableResult func useGivenCoordinates(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        router: RoutingKind = .givenCoordinates, configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        routeEdges(router, backend: backend, executor: executor, configure: configure)
    }
}
