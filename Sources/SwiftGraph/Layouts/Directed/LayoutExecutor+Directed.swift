import Foundation

extension LayoutExecutor {
    func directed(
        _ snapshot: DirectedExecutionSnapshot,
        configuration: DirectedLayoutConfiguration,
        cache: DirectedLayoutCache?,
        backend: LayoutBackend
    ) async throws -> DirectedExecutionResult {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        try configuration.validateExecution()
        try options.validate()
        var chosen = backend
        var reason: LayoutFallbackReason?
        var gpu = 0.0
        var device: String?
        let hasWork = snapshot.nodes.count > 1 || (configuration.mode == .fresh && !snapshot.nodes.isEmpty)
        if !hasWork {
            chosen = .cpu
            reason = .noWork
        } else if backend == .automatic {
            if snapshot.nodes.count < options.minimumNodeCount {
                chosen = .cpu
                reason = .belowThreshold
            } else if !metalEnabled || !Self.isMetalAvailable {
                chosen = .cpu
                reason = .metalUnavailable
            } else {
                chosen = .metal
            }
        }
        var graph = snapshot.makeGraph()
        var diagnostics: DirectedLayoutDiagnostics
        var geometryUsed = false
        if chosen == .metal {
            do {
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                let solver = try metalSolver()
                diagnostics = try await DirectedLayoutOperation(configuration: configuration, cache: cache)
                    .applyAsyncWorking(
                        graph,
                        // Placement is CPU work shared with the synchronous operation: the port-aware, layering and
                        // virtual-edge rules below have no GPU mirror, so only scoring uses the device.
                        hierarchy: { graph, hierarchy in try hierarchy.applyLayout(graph)
                        },
                        measure: { nodes, edges in
                            let result = try await solver.directedGeometryAsync(
                                nodes: nodes,
                                edges: edges,
                                tolerance: self.options.maximumCoordinateError
                            )
                            geometryUsed = geometryUsed || nodes.count > 1 || edges.count > 1
                            gpu += result.gpuSeconds
                            if geometryUsed { device = solver.deviceName }
                            // The kernel scores strict sharing; near-parallel proximity is reduced on the CPU.
                            var score = result.score
                            score.proximity = try DirectedGeometry.proximity(
                                edges: edges,
                                spacing: configuration.edgeSpacing
                            )
                            return score
                        }
                    )
                device = solver.deviceName
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu
                reason = .precisionLimit
                graph = snapshot.makeGraph()
                diagnostics = try DirectedLayoutOperation(configuration: configuration, cache: cache).apply(graph)
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu
                reason = .metalUnavailable
                graph = snapshot.makeGraph()
                diagnostics = try DirectedLayoutOperation(configuration: configuration, cache: cache).apply(graph)
            }
        } else {
            diagnostics = try DirectedLayoutOperation(configuration: configuration, cache: cache).apply(graph)
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).seconds
        var metrics = LayoutExecutionMetrics(
            requestedBackend: backend,
            backend: chosen,
            fallbackReason: reason,
            nodeCount: snapshot.nodes.count,
            iterations: configuration.candidateCount,
            computeSeconds: elapsed,
            totalSeconds: elapsed,
            gpuSeconds: geometryUsed ? gpu : nil,
            deviceName: device
        )
        let effectiveMode: DirectedLayoutMode =
            configuration.mode == .fresh && !configuration.fixedNodeIDs.isEmpty ? .incremental : configuration.mode
        metrics.cpuStages =
            graph.nodes.isEmpty
            ? [] : ["port-sizing-and-feedback-classification", "Double-geometry-reconstruction", "final-diagnostics"]
        if geometryUsed { metrics.cpuStages += ["exact-crossing-deduplication-and-score-reduction"] }
        if (diagnostics.stageMilliseconds["routing"] ?? 0) > 0 {
            metrics.cpuStages += ["obstacle-routing", "route-refinement"]
        }
        if (diagnostics.stageMilliseconds["placement"] ?? 0) > 0 {
            metrics.cpuStages += [effectiveMode == .fresh ? "hierarchy-placement" : "incremental-insertion"]
        }
        if effectiveMode == .fresh && !graph.nodes.isEmpty {
            metrics.cpuStages += ["component-connectivity", "component-packing"]
        }
        metrics.metalStages = geometryUsed ? ["directed-geometry-scoring"] : []
        return DirectedExecutionResult(
            bounds: graph.nodes.map(\.bounds),
            paths: graph.edges.map(\.path),
            diagnostics: diagnostics,
            metrics: metrics
        )
    }
}
