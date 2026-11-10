import Foundation

/// Reusable compute owner. Only immutable, Sendable snapshots/results cross this actor boundary.
public actor LayoutExecutor {
    public static let shared = LayoutExecutor()
    public nonisolated static var isMetalAvailable: Bool { MetalForceSolver.isAvailable }
    public let options: MetalLayoutOptions
    var metal: MetalForceSolver?
    var routingWorker: RoutingComputeWorker?
    let metalEnabled: Bool

    public init(options: MetalLayoutOptions = .init()) {
        self.options = options
        self.metalEnabled = true
    }

    // Deterministic unavailable-device testing, without a public "pretend Metal" backend.
    init(options: MetalLayoutOptions = .init(), metalEnabled: Bool) {
        self.options = options
        self.metalEnabled = metalEnabled
    }

    public func statistics() -> LayoutExecutorStatistics {
        let routing = routingWorker?.statisticsSnapshot()
        return LayoutExecutorStatistics(
            pipelineBuilds: (metal?.pipelineBuilds ?? 0) + (routing?.pipelineBuilds ?? 0),
            bufferAllocations: (metal?.bufferAllocations ?? 0) + (routing?.bufferAllocations ?? 0),
            bufferReuses: (metal?.bufferReuses ?? 0) + (routing?.bufferReuses ?? 0),
            submittedBatches: (metal?.submittedBatches ?? 0) + (routing?.submittedBatches ?? 0),
            completedBatches: (metal?.completedBatches ?? 0) + (routing?.completedBatches ?? 0),
            cachedBufferBytes: (metal?.cachedBufferBytes ?? 0) + (routing?.cachedBufferBytes ?? 0)
        )
    }

    /// The executor's Metal solver, created on first use and reused by every later GPU operation.
    func metalSolver() throws -> MetalForceSolver {
        if let metal { return metal }
        let solver = try MetalForceSolver()
        metal = solver
        return solver
    }

    /// Releases idle buffers only; resources belonging to in-flight requests remain retained.
    public func releaseCachedBuffers() async {
        metal?.releaseCachedBuffers()
        await routingWorker?.releaseCachedBuffers()
    }

    func organic(
        _ snapshot: GeometrySnapshot,
        configuration: OrganicLayoutConfiguration,
        backend: LayoutBackend
    ) async throws -> OrganicResult {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        try configuration.validate()
        try options.validate()
        let fixed = snapshot.nodes.map { $0.fixed || (configuration.scope == .subset && !$0.selected) }
        var chosen = backend
        var reason: LayoutFallbackReason?
        if snapshot.nodes.isEmpty || configuration.iterations == 0 || fixed.allSatisfy({ $0 }) {
            return OrganicResult(
                centers: snapshot.nodes.map { $0.bounds.center },
                fixed: fixed,
                metrics: metrics(backend, .cpu, .noWork, snapshot, configuration, start),
                diagnostics: configuration.quality == .quality
                    ? try OrganicQualitySearch(snapshot, configuration).diagnostics : nil
            )
        }
        if backend == .automatic {
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
        if configuration.quality == .quality {
            do {
                return try await qualityOrganic(
                    snapshot,
                    configuration: configuration,
                    requested: backend,
                    actual: chosen,
                    reason: reason,
                    start: start
                )
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                return try await qualityOrganic(
                    snapshot,
                    configuration: configuration,
                    requested: backend,
                    actual: .cpu,
                    reason: .precisionLimit,
                    start: start
                )
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                return try await qualityOrganic(
                    snapshot,
                    configuration: configuration,
                    requested: backend,
                    actual: .cpu,
                    reason: .metalUnavailable,
                    start: start
                )
            }
        }
        var centers: [Point]
        var cpuPreparation = 0.0
        var gpuTime: Double?
        var deviceName: String?
        if chosen == .metal {
            // Check precision before compiling or allocating GPU resources.
            do {
                let prepared = try snapshot.prepareMetal(
                    configuration: configuration,
                    fixed: fixed,
                    tolerance: options.maximumCoordinateError
                )
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                let solver = try metalSolver()
                // Node-count-dependent batch bound keeps large dispatches more cancellable.
                let n = Double(snapshot.nodes.count)
                let workBound = max(1, Int(min(64, 16_777_216 / max(1, n * n))))
                let batchSize =
                    (configuration.preparedPositions && options.iterationsPerBatch > 1)
                    ? (snapshot.nodes.count < 64
                        ? max(options.iterationsPerBatch, min(configuration.iterations, 600))
                        : max(options.iterationsPerBatch, 15))
                    : min(options.iterationsPerBatch, workBound)
                let result = try await solver.solveAsync(
                    prepared.state,
                    iterations: configuration.iterations,
                    temperature: configuration.initialTemperature,
                    parameters: ForceParameters(
                        repulsionSquared: configuration.repulsionForce * configuration.repulsionForce,
                        attraction: configuration.attractionForce
                    ),
                    batchSize: batchSize,
                    coolingIterationBudget: configuration.iterationBudget
                )
                gpuTime = result.gpuSeconds
                deviceName = solver.deviceName
                cpuPreparation += result.cpuPreparationSeconds
                guard result.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                    throw OrganicLayoutError.metalFailure("Non-finite output coordinates")
                }
                guard result.positions.allSatisfy({ max(abs($0.x), abs($0.y)).ulp <= options.maximumCoordinateError })
                else {
                    throw LayoutExecutionError.precisionLimit
                }
                if fixed.contains(true) {
                    centers = result.positions.map { Point(x: $0.x + prepared.origin.x, y: $0.y + prepared.origin.y) }
                } else {
                    // The solver returns one position per snapshot node, and empty snapshots returned early above.
                    let minX = result.positions.map(\.x).min()!
                    let minY = result.positions.map(\.y).min()!
                    centers = result.positions.map { Point(x: $0.x - minX, y: $0.y - minY) }
                }
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu
                reason = .precisionLimit
                centers = try snapshot.cpuOrganic(configuration)
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu
                reason = .metalUnavailable
                centers = try snapshot.cpuOrganic(configuration)
            }
        } else {
            centers = try snapshot.cpuOrganic(configuration)
        }
        try Task.checkCancellation()
        guard centers.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw LayoutExecutionError.invalidInput("Force calculation produced non-finite coordinates.")
        }
        return OrganicResult(
            centers: centers,
            fixed: fixed,
            metrics: metrics(
                backend,
                chosen,
                reason,
                snapshot,
                configuration,
                start,
                gpu: gpuTime,
                device: deviceName,
                cpuPreparation: cpuPreparation
            )
        )
    }

    private func qualityOrganic(
        _ snapshot: GeometrySnapshot,
        configuration: OrganicLayoutConfiguration,
        requested: LayoutBackend,
        actual: LayoutBackend,
        reason: LayoutFallbackReason?,
        start: ContinuousClock.Instant
    ) async throws -> OrganicResult {
        let preparationStart = ContinuousClock.now
        var search = try OrganicQualitySearch(snapshot, configuration)
        let starts = search.starts()
        // Reject predictable precision failures before submitting any candidate. Automatic
        // fallback therefore does not discard successful GPU solves from timing/iteration totals.
        if actual == .metal {
            for positions in starts {
                for strength: Float in [0.5, 1.0, 2.0] {
                    try Task.checkCancellation()
                    let (input, candidate) = search.candidate(positions, strength: strength)
                    _ = try input.prepareMetal(
                        configuration: candidate,
                        fixed: search.fixed,
                        tolerance: options.maximumCoordinateError
                    )
                }
            }
        }
        let preparationSeconds = preparationStart.duration(to: .now).seconds
        var solverSeconds = 0.0
        var evaluationSeconds = 0.0
        var cpuPreparation = 0.0
        var gpu: Double?
        var device: String?
        let strengths: [Float] = [0.5, 1.0, 2.0]
        let candidateCount = starts.count * strengths.count
        for (startIndex, positions) in starts.enumerated() {
            for (strengthIndex, strength) in strengths.enumerated() {
                try Task.checkCancellation()
                let index = startIndex * strengths.count + strengthIndex
                try await LayoutStageScope.run(
                    "Candidate \(index + 1)/\(candidateCount)",
                    part: index,
                    of: candidateCount
                ) {
                    let (input, candidate) = search.candidate(positions, strength: strength)
                    let solveStart = ContinuousClock.now
                    let result = try await LayoutStageScope.run("Force simulation", to: 0.85) {
                        try await organic(input, configuration: candidate, backend: actual)
                    }
                    solverSeconds += solveStart.duration(to: .now).seconds
                    cpuPreparation += result.metrics.cpuPreparationSeconds
                    if let seconds = result.metrics.gpuSeconds { gpu = (gpu ?? 0) + seconds }
                    device = result.metrics.deviceName
                    let evaluationStart = ContinuousClock.now
                    try LayoutStageScope.run("Evaluate", from: 0.85) { try search.consider(result.centers) }
                    evaluationSeconds += evaluationStart.duration(to: .now).seconds
                }
            }
        }
        try Task.checkCancellation()
        var executionMetrics = metrics(
            requested,
            actual,
            reason,
            snapshot,
            configuration,
            start,
            gpu: gpu,
            device: device,
            cpuPreparation: cpuPreparation
        )
        executionMetrics.qualityPhases = OrganicQualityTimings(
            preparationSeconds: preparationSeconds,
            solverSeconds: solverSeconds,
            evaluationSeconds: evaluationSeconds
        )
        return OrganicResult(
            centers: search.best,
            fixed: search.fixed,
            metrics: executionMetrics,
            diagnostics: search.diagnostics
        )
    }

    private func metrics(
        _ requested: LayoutBackend,
        _ actual: LayoutBackend,
        _ reason: LayoutFallbackReason?,
        _ snapshot: GeometrySnapshot,
        _ configuration: OrganicLayoutConfiguration,
        _ start: ContinuousClock.Instant,
        gpu: Double? = nil,
        device: String? = nil,
        cpuPreparation: Double = 0
    ) -> LayoutExecutionMetrics {
        let elapsed = start.duration(to: .now).seconds
        return LayoutExecutionMetrics(
            requestedBackend: requested,
            backend: actual,
            fallbackReason: reason,
            nodeCount: snapshot.nodes.count,
            iterations: configuration.iterations,
            computeSeconds: elapsed,
            totalSeconds: elapsed,
            gpuSeconds: gpu,
            deviceName: device,
            cpuPreparationSeconds: cpuPreparation,
            cpuStages: reason == .noWork
                ? ["no-work preservation"]
                : (actual == .cpu
                    ? ["organic placement"]
                    : ["initialization, topology and coordinate reconstruction"]
                        + (snapshot.nodes.count >= 64 ? ["Barnes–Hut topology rebuild between iterations"] : []))
                    + (configuration.quality == .quality ? ["candidate cleanup and quality scoring"] : []),
            metalStages: gpu != nil
                ? [
                    actual == .metal
                        ? "organic force iterations" : "organic force iterations discarded after precision fallback"
                ] : []
        )
    }
}

/// Async-only operation. Its graph and this operation stay on the caller's actor across suspension.
public final class OrganicLayoutOperation: AsyncLayoutAlgorithm {
    public var configuration: OrganicLayoutConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public private(set) var lastDiagnostics: OrganicLayoutDiagnostics?

    public init(
        backend: LayoutBackend,
        executor: LayoutExecutor = .shared,
        configuration: OrganicLayoutConfiguration = .init()
    ) {
        self.backend = backend
        self.executor = executor
        self.configuration = configuration
    }

    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        lastDiagnostics = nil
        let start = ContinuousClock.now
        let configuration = self.configuration
        try Task.checkCancellation()
        try configuration.validate()
        let checkpoint = try GraphCheckpoint(graph)
        let result = try await executor.organic(checkpoint.snapshot, configuration: configuration, backend: backend)
        try Task.checkCancellation()
        guard checkpoint.matches(graph) else { throw LayoutExecutionError.staleGraph }
        for i in graph.nodes.indices where !result.fixed[i] && configuration.iterations > 0 {
            graph.nodes[i].center = result.centers[i]
        }
        var metrics = result.metrics
        metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics
        lastDiagnostics = result.diagnostics
    }
}
