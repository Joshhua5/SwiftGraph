import Foundation

extension LayoutExecutor {
    func barycenter(
        _ snapshot: GeometrySnapshot,
        configuration: BarycenterLayoutConfiguration,
        backend: LayoutBackend
    ) async throws -> OrganicResult {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        try configuration.validate()
        try options.validate()
        let graph = snapshot.makeGraph()
        let adjacency = Adjacency(graph)
        let bounds = graph.bounds
        var fixed = snapshot.nodes.map(\.fixed)
        if !fixed.contains(true) {
            fixed = graph.nodes.map {
                $0.x <= bounds.left + 1 || $0.bounds.right >= bounds.right - 1 || $0.y <= bounds.top + 1
                    || $0.bounds.bottom >= bounds.bottom - 1
            }
        }
        var chosen = backend
        var reason: LayoutFallbackReason?
        var gpuTime: Double?
        var device: String?
        if snapshot.nodes.isEmpty || configuration.iterations == 0
            || snapshot.nodes.indices.allSatisfy({ fixed[$0] || adjacency.neighbors[$0].isEmpty })
        {
            chosen = .cpu
            reason = .noWork
        } else if backend == .automatic {
            if snapshot.nodes.count < options.minimumNodeCount || configuration.iterations < options.minimumIterations {
                chosen = .cpu
                reason = .belowThreshold
            } else if !metalEnabled || !Self.isMetalAvailable {
                chosen = .cpu
                reason = .metalUnavailable
            } else {
                chosen = .metal
            }
        }
        if chosen == .metal {
            do {
                let prepared = try snapshot.prepareBarycenter(
                    fixed: fixed,
                    neighbors: adjacency.neighbors,
                    tolerance: options.maximumCoordinateError
                )
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                let solver = try metalSolver()
                let workBound = max(1, Int(min(64, 16_777_216 / Double(max(1, prepared.state.neighbors.count)))))
                let batchSize = min(options.iterationsPerBatch, workBound)
                let result = try await LayoutStageScope.run("Solve", to: 0.85) {
                    try await solver.solveAsync(
                        prepared.state,
                        iterations: configuration.iterations,
                        temperature: 0,
                        parameters: ForceParameters(repulsionSquared: 0, attraction: 0),
                        batchSize: batchSize,
                        barycenter: true
                    )
                }
                guard result.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                    throw OrganicLayoutError.metalFailure("Non-finite barycenter output")
                }
                guard result.positions.allSatisfy({ max(abs($0.x), abs($0.y)).ulp <= options.maximumCoordinateError })
                else {
                    throw LayoutExecutionError.precisionLimit
                }
                gpuTime = result.gpuSeconds
                device = solver.deviceName
                for i in graph.nodes.indices where !fixed[i] && !adjacency.neighbors[i].isEmpty {
                    graph.nodes[i].center = Point(
                        x: result.positions[i].x + prepared.origin.x,
                        y: result.positions[i].y + prepared.origin.y
                    )
                }
                _ = try LayoutStageScope.run("Separate overlaps", from: 0.85) {
                    try separateOverlaps(graph.nodes, spacing: configuration.minSpacing, movable: fixed.map { !$0 })
                }
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu
                reason = .precisionLimit
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu
                reason = .metalUnavailable
            }
        }
        if chosen == .cpu {
            let algorithm = BarycenterLayoutAlgorithm()
            algorithm.iterations = configuration.iterations
            algorithm.minSpacing = configuration.minSpacing
            try algorithm.applyLayout(graph)
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).seconds
        return OrganicResult(
            centers: graph.nodes.map(\.center),
            fixed: fixed,
            metrics: LayoutExecutionMetrics(
                requestedBackend: backend,
                backend: chosen,
                fallbackReason: reason,
                nodeCount: snapshot.nodes.count,
                iterations: configuration.iterations,
                computeSeconds: elapsed,
                totalSeconds: elapsed,
                gpuSeconds: gpuTime,
                deviceName: device,
                cpuStages: chosen == .metal
                    ? ["anchor selection", "overlap cleanup", "straight edge routing"]
                    : ["barycenter refinement and routing"],
                metalStages: chosen == .metal ? ["neighbor averaging"] : []
            )
        )
    }
}
