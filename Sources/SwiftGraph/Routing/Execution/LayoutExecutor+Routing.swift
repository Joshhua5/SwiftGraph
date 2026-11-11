import Foundation

extension LayoutExecutor {
    func routing(
        _ snapshot: RoutingSnapshot,
        configuration: RoutingConfiguration,
        backend: LayoutBackend
    ) async throws -> RoutingResult {
        try configuration.validate()
        try options.validate()
        try Task.checkCancellation()
        if routingWorker == nil { routingWorker = RoutingComputeWorker() }
        // `routingWorker` was assigned on the line above if it was still nil.
        return try await routingWorker!
            .run(
                snapshot,
                configuration: configuration,
                backend: backend,
                enabled: metalEnabled,
                tolerance: options.maximumCoordinateError
            )
    }
}

func routingTransaction(
    _ snapshot: RoutingSnapshot,
    configuration: RoutingConfiguration,
    backend: LayoutBackend,
    enabled: Bool,
    tolerance: Float,
    makeCompute: () throws -> RoutingCompute
) throws -> RoutingResult {
    let start = ContinuousClock.now
    var actual = backend
    var reason: LayoutFallbackReason?
    if snapshot.geometry.edges.isEmpty {
        actual = .cpu
        reason = .noWork
    } else if backend == .automatic {
        if snapshot.edges.count < configuration.minimumMetalEdgeCount {
            actual = .cpu
            reason = .belowThreshold
        } else if !enabled || !LayoutExecutor.isMetalAvailable {
            actual = .cpu
            reason = .metalUnavailable
        } else {
            actual = .metal
        }
    }
    func run(_ compute: RoutingCompute?) throws -> RoutingResult {
        compute?.minimumPairs = RoutingCompute.roundTripPairs
        compute?.minimumElements = RoutingCompute.roundTripElements
        compute?.dispatchesFirstCall = backend == .metal
        let (graph, relatedNodes) = snapshot.makeGraph()
        let initialSubmissions = compute?.solver.submittedBatches ?? 0
        var unroutable: [LayoutEdge] = []
        RoutingCompute.$current.withValue(compute) {
            switch configuration.kind {
            case .polyline:
                let r = PolylineEdgeRouter()
                r.padding = configuration.padding
                r.edgeSpacing = configuration.edgeSpacing
                r.routeEdges(graph)
                unroutable = r.unroutableEdges
            case .channel:
                let r = ChannelEdgeRouter()
                r.gridSize = configuration.gridSize
                r.bendPenalty = configuration.channelBendPenalty
                r.congestionPenalty = configuration.congestionPenalty
                r.routeEdges(graph)
                unroutable = r.unroutableEdges
            case .bus:
                let r = BusEdgeRouter()
                r.busSpacing = configuration.busSpacing
                r.routeEdges(graph)
            case .octilinear: OctilinearEdgeRouter().routeEdges(graph)
            case .bsp:
                let r = BspEdgeRouter()
                r.margin = configuration.margin
                r.bendPenalty = configuration.bendPenalty
                r.edgeSpacing = configuration.edgeSpacing
                r.routeEdges(graph)
                unroutable = r.unroutableEdges
            case .orthogonalGrouped:
                let r = OrthogonalGroupedEdgeRouter()
                r.bundleSpacing = configuration.bundleSpacing
                r.obstacleMargin = configuration.obstacleMargin
                r.bendPenalty = configuration.bendPenalty
                r.routeEdges(graph)
                unroutable = r.unroutableEdges
            case .parallelEdges:
                let r = ParallelEdgeRouter()
                r.edgeSpacing = configuration.parallelEdgeSpacing
                r.routeEdges(graph)
            case .edgeSeparation:
                let r = EdgeSeparator()
                r.spacing = configuration.edgeSpacing
                r.routeEdges(graph)
            case .selfLoops:
                let r = SelfLoopRouter()
                r.loopSize = configuration.loopSize
                r.routeEdges(graph)
                unroutable = r.unroutableEdges
            case .curveFitting:
                let r = CurveFittingEdgeRouter()
                r.iterations = configuration.curveIterations
                r.routeEdges(graph)
            case .endpointClipping: EdgeEndpointClipper.clipToNodeBounds(graph)
            case .labelPlacement: LabelPlacementAlgorithm().applyLabelPlacement(graph)
            case .labelLayout:
                let r = LabelLayoutAlgorithm()
                r.iterations = configuration.labelIterations
                r.applyLabelLayout(graph)
            case .givenCoordinates:
                let r = PolylineEdgeRouter()
                r.padding = configuration.padding
                r.edgeSpacing = configuration.edgeSpacing
                r.routeEdges(graph)
                unroutable = r.unroutableEdges
            }
        }
        try RoutingCompute.cancellation?.check()
        if let failure = compute?.failure { throw failure }
        guard
            relatedNodes.allSatisfy({
                [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width >= 0 && $0.height >= 0
            }),
            graph.edges.allSatisfy({
                $0.path.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                    && [$0.labelBounds.x, $0.labelBounds.y, $0.labelBounds.width, $0.labelBounds.height]
                        .allSatisfy(\.isFinite)
            })
        else {
            throw LayoutExecutionError.invalidInput("Routing produced non-finite geometry.")
        }
        let submitted = (compute?.solver.submittedBatches ?? 0) - initialSubmissions
        let elapsed = start.duration(to: .now).seconds
        return RoutingResult(
            bounds: relatedNodes.map(\.bounds),
            rootBounds: graph.root.bounds,
            paths: graph.edges.map(\.path),
            labels: graph.edges.map(\.labelBounds),
            unroutable: unroutable.compactMap { graph.edges.firstIndex(of: $0) },
            metrics: LayoutExecutionMetrics(
                requestedBackend: backend,
                backend: submitted == 0 ? .cpu : actual,
                fallbackReason: submitted == 0 && actual == .metal ? .noWork : reason,
                nodeCount: graph.nodes.count,
                iterations: configuration.kind == .labelLayout
                    ? configuration.labelIterations
                    : configuration.kind == .curveFitting ? min(5, configuration.curveIterations) : 1,
                computeSeconds: elapsed,
                totalSeconds: elapsed,
                gpuSeconds: submitted == 0 ? nil : compute?.gpuSeconds,
                deviceName: submitted == 0 ? nil : compute?.solver.deviceName,
                cpuStages: (actual == .cpu
                    ? ["CPU \(configuration.kind.rawValue) routing and finishing"]
                    : routingCPUStages(configuration.kind)) + (compute?.fallbacks ?? []),
                metalStages: submitted == 0 ? [] : compute?.stages ?? []
            ),
            routeStyle: graph.routeStyle
        )
    }
    if actual != .metal { return try run(nil) }
    do {
        guard enabled else { throw OrganicLayoutError.metalUnavailable }
        return try run(makeCompute())
    } catch LayoutExecutionError.precisionLimit where backend == .automatic {
        actual = .cpu
        reason = .precisionLimit
        return try run(nil)
    } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
        actual = .cpu
        reason = .metalUnavailable
        return try run(nil)
    }
}

private func routingCPUStages(_ kind: RoutingKind) -> [String] {
    switch kind {
    case .polyline, .givenCoordinates:
        [
            "visibility vertices and ordered shortest-path search",
            "exact Double obstacle predicates and safe lane assignment",
        ]
    case .channel: ["port selection, ordered A* search and congestion updates"]
    case .bsp:
        [
            "BSP hierarchy, ordered visibility search and long-route channel comparison",
            "exact Double segment predicates and safe lane assignment",
        ]
    case .orthogonalGrouped:
        [
            "hierarchy channels, ordered A* search, node nudge ordering and shared lanes",
            "exact Double blockers and endpoint clipping reconstruction",
        ]
    case .selfLoops: ["corner generation, ordered corner ranking and exact Double clearance/crossings"]
    case .edgeSeparation:
        [
            "shared-line grouping, lane ordering and shifted-line intersections",
            "exact Double no-new-obstacle predicate",
        ]
    case .curveFitting: ["subdivision iteration scheduling and exact endpoint preservation"]
    case .endpointClipping: ["exact containment, boundary intersection and path compaction"]
    case .labelPlacement: ["label text sizing, midpoint placement, candidate ranking and exact collision refinement"]
    case .labelLayout: ["seeded annealing, exact energy accumulation and candidate ranking"]
    case .parallelEdges: ["edge grouping, lane ordering and exact endpoint preservation"]
    case .bus: ["hub selection, bus axis selection and edge orientation"]
    case .octilinear: ["near-endpoint bend suppression and exact endpoint preservation"]
    }
}
