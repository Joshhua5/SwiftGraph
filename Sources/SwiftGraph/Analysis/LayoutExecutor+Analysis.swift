import Foundation

extension LayoutExecutor {
    func analysis(
        _ snapshot: GeometrySnapshot,
        kind: AnalysisKind,
        pageRank: PageRankConfiguration,
        clusters: ClusterAnalysisConfiguration,
        backend: LayoutBackend
    ) async throws -> AnalysisResult {
        let start = ContinuousClock.now
        try options.validate()
        try Task.checkCancellation()
        let state = try AnalysisState(snapshot)
        var actual = backend
        var reason: LayoutFallbackReason?
        var ranks: [Double]?
        var labels: [Int]?
        var gpu: Double?
        var device: String?
        var refinedRankOrdering = false
        let iterations = kind == .pageRank ? pageRank.iterations : 20
        if state.count == 0 || iterations == 0 || (kind == .clusters && state.neighbors.isEmpty) {
            actual = .cpu
            reason = .noWork
        } else if backend == .automatic {
            let minimum = kind == .pageRank ? pageRank.minimumMetalNodeCount : clusters.minimumMetalNodeCount
            if state.count < minimum {
                actual = .cpu
                reason = .belowThreshold
            } else if !metalEnabled || !Self.isMetalAvailable {
                actual = .cpu
                reason = .metalUnavailable
            } else {
                actual = .metal
            }
        }
        if actual == .metal {
            do {
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                let solver = try metalSolver()
                if kind == .pageRank {
                    let batchSize = options.iterationsPerBatch
                    let result = try await LayoutStageScope.run("Rank", to: 0.8) {
                        try await solver.pageRankAsync(state, configuration: pageRank, batchSize: batchSize)
                    }
                    ranks = result.ranks
                    gpu = result.gpuSeconds
                    let sorted = result.ranks.sorted()
                    let uncertainty = state.pageRankErrorBound(iterations: pageRank.iterations) * 2
                    if zip(sorted, sorted.dropFirst()).contains(where: { $1 - $0 <= uncertainty }) {
                        // Numerical overlap can change hub selection. Recompute exact Double ranks
                        // together to preserve order and total mass; GPU iterations supplied the
                        // conservative ambiguity decision, so this cost is disclosed in metrics.
                        let progress = LayoutStageScope.capture()
                        let refinement = Task.detached {
                            try progress.bind {
                                try LayoutStageScope.run("Refine ranks", from: 0.8) { try state.cpuPageRank(pageRank) }
                            }
                        }
                        ranks = try await withTaskCancellationHandler {
                            try await refinement.value
                        } onCancel: {
                            refinement.cancel()
                        }
                        refinedRankOrdering = true
                    }
                } else {
                    let result = try await solver.clustersAsync(state)
                    labels = result.labels
                    gpu = result.gpuSeconds
                }
                device = solver.deviceName
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                actual = .cpu
                reason = .precisionLimit
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                actual = .cpu
                reason = .metalUnavailable
            }
        }
        if actual == .cpu {
            if kind == .pageRank { ranks = try state.cpuPageRank(pageRank) } else { labels = try state.cpuClusters() }
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).seconds
        return AnalysisResult(
            ranks: ranks,
            labels: labels,
            metrics: LayoutExecutionMetrics(
                requestedBackend: backend,
                backend: actual,
                fallbackReason: reason,
                nodeCount: state.count,
                iterations: iterations,
                computeSeconds: elapsed,
                totalSeconds: elapsed,
                gpuSeconds: gpu,
                deviceName: device,
                cpuStages: actual == .cpu
                    ? [kind == .pageRank ? "PageRank iterations" : "seeded in-place label propagation"]
                    : [
                        "adjacency preparation",
                        kind == .pageRank ? "rank readback" : "seeded shuffle and convergence control",
                    ] + (refinedRankOrdering ? ["exact Double PageRank refinement for ambiguous rank ordering"] : []),
                metalStages: actual == .metal
                    ? [
                        kind == .pageRank
                            ? "double-single PageRank dangling reduction and incoming-link iterations"
                            : "ordered in-place cluster voting and label updates"
                    ] : []
            )
        )
    }
}
