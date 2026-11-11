import Foundation

extension LayoutBuilder {
    /// Adds the finishing stages that follow a router.
    ///
    /// The stages run in `RouteFinishing`'s order: self-loops, repair, endpoint clipping, port distribution, then
    /// curve fitting for `.curved`.
    ///
    /// - Parameters:
    ///   - style: The geometry the routes are meant to have.
    ///   - curveIterations: Subdivision depth for `.curved`; ignored for other styles.
    ///   - portDistributionLimit: Port distribution is skipped when the graph has more edges than this. Nil always
    ///     distributes.
    /// - Returns: This builder.
    @discardableResult public func finishRoutes(
        style: RouteStyle,
        curveIterations: Int = RouteFinishing.defaultCurveIterations,
        portDistributionLimit: Int? = nil
    ) -> Self {
        routeSelfLoops()
            .transform { graph in
                LayoutStageScope.run("Post-routing repair") { _ = RouteFinishing.repair(graph, style: style) }
            }
            .clipEdgeEndpoints()
            .distributePorts(limit: portDistributionLimit)
        if style == .curved { routeCurveFitting { $0.iterations = curveIterations } }
        return self
    }

    /// Adds the finishing stages that follow a router, running each on the chosen backend.
    ///
    /// Each stage is its own pipeline step, so execution metrics and progress report them separately.
    ///
    /// - Parameters:
    ///   - style: The geometry the routes are meant to have.
    ///   - backend: The backend for self-loops, clipping and curve fitting.
    ///   - executor: The executor those stages run on.
    ///   - curveIterations: Subdivision depth for `.curved`; ignored for other styles.
    ///   - portDistributionLimit: Port distribution is skipped when the graph has more edges than this. Nil always
    ///     distributes.
    /// - Returns: This builder.
    @discardableResult public func finishRoutes(
        style: RouteStyle,
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        curveIterations: Int = RouteFinishing.defaultCurveIterations,
        portDistributionLimit: Int? = nil
    ) -> Self {
        routeSelfLoops(backend: backend, executor: executor)
            .transform { graph in
                LayoutStageScope.run("Post-routing repair") { _ = RouteFinishing.repair(graph, style: style) }
            }
            .clipEdgeEndpoints(backend: backend, executor: executor)
            // Port distribution is CPU-only, so the backend has nothing to select here.
            .distributePorts(limit: portDistributionLimit)
        if style == .curved {
            routeCurveFitting(backend: backend, executor: executor) { $0.iterations = curveIterations }
        }
        return self
    }

    private func distributePorts(limit: Int?) -> Self {
        guard limit != nil else { return distributePorts() }
        return transform { graph in
            guard RouteFinishing.distributesPorts(graph, limit: limit) else { return }
            PortDistributor().finishRoutes(graph)
        }
        .stage("Port distribution")
    }
}
