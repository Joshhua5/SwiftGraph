import Foundation

/// Metal runs the iteration kernel once per subdivision cycle; compatibility, resampling, node clearance, edge
/// fanning and simplification are the same CPU code the synchronous router uses.
extension LayoutExecutor {
    func bundle(
        _ snapshot: GeometrySnapshot,
        paths input: [[Point]],
        configuration: EdgeBundlingConfiguration,
        backend: LayoutBackend,
        routing: RoutingSnapshot? = nil
    ) async throws -> BundlingResult {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        try configuration.validate()
        try options.validate()
        let seeded = routing?.makeGraph().0 ?? snapshot.makeGraph()
        for (edge, path) in zip(seeded.edges, input) { edge.path = path }
        ObstaclePolyline.repair(seeded, spacing: 0)
        let existing = seeded.edges.map(\.path)
        let edges = snapshot.edges.filter { $0.source != $0.target }
        guard edges.isEmpty || max(1, configuration.segments) < 8_388_608 / edges.count else {
            throw LayoutExecutionError.invalidInput("Bundling exceeds the 64 MiB control-point limit.")
        }
        var chosen = backend
        var reason: LayoutFallbackReason?
        var gpuTime: Double?
        var device: String?
        var paths: [BundledPath]
        if edges.isEmpty || configuration.iterations == 0 || configuration.segments <= 1 {
            chosen = .cpu
            reason = .noWork
        } else if backend == .automatic {
            if edges.count < options.minimumBundlingEdgeCount || configuration.iterations < options.minimumIterations {
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
                var (state, bundler) = try snapshot.prepareBundling(
                    configuration,
                    paths: existing,
                    tolerance: options.maximumCoordinateError
                )
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                let solver = try metalSolver()
                var seconds = 0.0
                let cycles = bundler.schedule.count
                let batchSize = options.iterationsPerBatch
                try await LayoutStageScope.run("Bundle", from: 0.05, to: 0.9) {
                    for cycle in bundler.schedule.indices {
                        try await LayoutStageScope.run("Cycle \(cycle + 1)/\(cycles)", part: cycle, of: cycles) {
                            if cycle > 0 { state = bundler.state(cycle: cycle) }
                            let result = try await solver.bundleAsync(
                                state,
                                iterations: bundler.schedule[cycle].iterations,
                                batchSize: batchSize
                            )
                            seconds += result.gpuSeconds
                            guard result.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                                throw OrganicLayoutError.metalFailure("Non-finite bundle coordinates")
                            }
                            bundler.finish(cycle: cycle, positions: result.positions.map { Point(x: $0.x, y: $0.y) })
                        }
                    }
                }
                device = solver.deviceName
                gpuTime = seconds
                paths = zip(edges, bundler.paths()).map { BundledPath(index: $0.index, points: $1) }
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu
                reason = .precisionLimit
                paths = try LayoutStageScope.run("Bundle", from: 0.05, to: 0.9) {
                    try snapshot.cpuBundle(configuration, paths: existing)
                }
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu
                reason = .metalUnavailable
                paths = try LayoutStageScope.run("Bundle", from: 0.05, to: 0.9) {
                    try snapshot.cpuBundle(configuration, paths: existing)
                }
            }
        } else {
            paths = try LayoutStageScope.run("Bundle", from: 0.05, to: 0.9) {
                try snapshot.cpuBundle(configuration, paths: existing)
            }
        }
        try Task.checkCancellation()
        let repaired = routing?.makeGraph().0 ?? snapshot.makeGraph()
        for path in paths { repaired.edges[path.index].path = path.points }
        repaired.routeStyle = .polyline
        let failures = Set(
            LayoutStageScope.run("Repair", from: 0.9) {
                ObstaclePolyline.repair(repaired, spacing: 0, shortenDetours: true)
            }
        )
        let unroutable = repaired.edges.indices.filter { failures.contains(repaired.edges[$0]) }
        paths = paths.map { BundledPath(index: $0.index, points: repaired.edges[$0.index].path) }
        guard paths.allSatisfy({ $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else {
            throw LayoutExecutionError.invalidInput("Non-finite bundle coordinates")
        }
        let elapsed = start.duration(to: .now).seconds
        return BundlingResult(
            paths: paths,
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
                    ? [
                        "compatibility construction", "route resampling and subdivision",
                        "node clearance, edge fanning, simplification and final obstacle repair",
                    ] : ["edge bundling"],
                metalStages: chosen == .metal
                    ? ["bundling iterations"]
                    : (gpuTime == nil ? [] : ["discarded bundling iterations before CPU fallback"])
            ),
            unroutable: unroutable
        )
    }
}
