import Foundation

public struct BarycenterLayoutConfiguration: Sendable {
    public var iterations = 3
    public var minSpacing: Float = 10
    public init() {}
    func validate() throws {
        guard iterations >= 0, iterations < Int.max / 16, minSpacing.isFinite, minSpacing >= 0 else {
            throw LayoutExecutionError.invalidInput("Barycenter iterations and spacing must be finite and nonnegative.")
        }
    }
}

/// Neighbor averaging on the chosen backend; anchor selection and overlap cleanup
/// use the CPU contract. Even zero iterations perform cleanup and create straight routes.
public final class BarycenterLayoutOperation: AsyncLayoutAlgorithm {
    public var configuration: BarycenterLayoutConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public init(backend: LayoutBackend, executor: LayoutExecutor = .shared, configuration: BarycenterLayoutConfiguration = .init()) {
        self.backend = backend; self.executor = executor; self.configuration = configuration
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now, configuration = self.configuration
        try Task.checkCancellation(); try configuration.validate()
        let transaction = try LayoutTransaction(graph)
        let snapshot = try GraphCheckpoint(transaction.working).snapshot
        let result = try await executor.barycenter(snapshot, configuration: configuration, backend: backend)
        for (node, center) in zip(transaction.working.nodes, result.centers) where node.center != center { node.center = center }
        straightEdges(transaction.working)
        try transaction.commit(to: graph)
        var metrics = result.metrics; metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics
    }
}

public extension LayoutBuilder {
    @discardableResult func useBarycenter(backend: LayoutBackend, executor: LayoutExecutor = .shared,
                                         configure: (inout BarycenterLayoutConfiguration) -> Void = { _ in }) -> Self {
        var configuration = BarycenterLayoutConfiguration(); configure(&configuration)
        return useAsyncAlgorithm(BarycenterLayoutOperation(backend: backend, executor: executor, configuration: configuration))
    }
}

extension LayoutExecutor {
    func barycenter(_ snapshot: GeometrySnapshot, configuration: BarycenterLayoutConfiguration,
                    backend: LayoutBackend) async throws -> OrganicResult {
        let start = ContinuousClock.now
        try Task.checkCancellation(); try configuration.validate(); try options.validate()
        let graph = snapshot.makeGraph(), adjacency = Adjacency(graph), bounds = graph.bounds
        var fixed = snapshot.nodes.map(\.fixed)
        if !fixed.contains(true) {
            fixed = graph.nodes.map { $0.x <= bounds.left + 1 || $0.bounds.right >= bounds.right - 1 ||
                $0.y <= bounds.top + 1 || $0.bounds.bottom >= bounds.bottom - 1 }
        }
        var chosen = backend, reason: LayoutFallbackReason?, gpuTime: Double?, device: String?
        if snapshot.nodes.isEmpty || configuration.iterations == 0 ||
            snapshot.nodes.indices.allSatisfy({ fixed[$0] || adjacency.neighbors[$0].isEmpty }) {
            chosen = .cpu; reason = .noWork
        } else if backend == .automatic {
            if snapshot.nodes.count < options.minimumNodeCount || configuration.iterations < options.minimumIterations {
                chosen = .cpu; reason = .belowThreshold
            } else if !metalEnabled || !Self.isMetalAvailable {
                chosen = .cpu; reason = .metalUnavailable
            } else { chosen = .metal }
        }
        if chosen == .metal {
            do {
                let prepared = try snapshot.prepareBarycenter(fixed: fixed, neighbors: adjacency.neighbors,
                                                              tolerance: options.maximumCoordinateError)
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                if metal == nil { metal = try MetalForceSolver() }
                let workBound = max(1, Int(min(64, 16_777_216 / Double(max(1, prepared.state.neighbors.count)))))
                let result = try await metal!.solveAsync(prepared.state, iterations: configuration.iterations,
                    temperature: 0, parameters: ForceParameters(repulsionSquared: 0, attraction: 0),
                    batchSize: min(options.iterationsPerBatch, workBound), barycenter: true)
                guard result.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                    throw OrganicLayoutError.metalFailure("Non-finite barycenter output")
                }
                guard result.positions.allSatisfy({ max(abs($0.x), abs($0.y)).ulp <= options.maximumCoordinateError }) else {
                    throw LayoutExecutionError.precisionLimit
                }
                gpuTime = result.gpuSeconds; device = metal!.deviceName
                for i in graph.nodes.indices where !fixed[i] && !adjacency.neighbors[i].isEmpty {
                    graph.nodes[i].center = Point(x: result.positions[i].x + prepared.origin.x,
                                                 y: result.positions[i].y + prepared.origin.y)
                }
                _ = try separateOverlaps(graph.nodes, spacing: configuration.minSpacing, movable: fixed.map { !$0 })
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu; reason = .precisionLimit
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu; reason = .metalUnavailable
            }
        }
        if chosen == .cpu {
            let algorithm = BarycenterLayoutAlgorithm()
            algorithm.iterations = configuration.iterations; algorithm.minSpacing = configuration.minSpacing
            try algorithm.applyLayout(graph)
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).seconds
        return OrganicResult(centers: graph.nodes.map(\.center), fixed: fixed,
            metrics: LayoutExecutionMetrics(requestedBackend: backend, backend: chosen, fallbackReason: reason,
                nodeCount: snapshot.nodes.count, iterations: configuration.iterations, computeSeconds: elapsed,
                totalSeconds: elapsed, gpuSeconds: gpuTime, deviceName: device,
                cpuStages: chosen == .metal ? ["anchor selection", "overlap cleanup", "straight edge routing"] : ["barycenter refinement and routing"],
                metalStages: chosen == .metal ? ["neighbor averaging"] : []))
    }
}

extension GeometrySnapshot {
    func prepareBarycenter(fixed: [Bool], neighbors: [[Int]], tolerance: Float) throws -> (state: ForceState, origin: Point) {
        let centers = nodes.map { $0.bounds.center }
        let minX = centers.map(\.x).min()!, maxX = centers.map(\.x).max()!
        let minY = centers.map(\.y).min()!, maxY = centers.map(\.y).max()!
        let origin = Point(x: minX + (maxX - minX) / 2, y: minY + (maxY - minY) / 2)
        let extent = max(maxX - minX, maxY - minY)
        let degree = neighbors.map(\.count).max() ?? 0
        guard extent.isFinite, extent.ulp <= tolerance,
              Double(extent) * Double(max(1, degree)) < Double(Float.greatestFiniteMagnitude) / 4 else {
            throw LayoutExecutionError.precisionLimit
        }
        var flat: [UInt32] = [], offsets: [UInt32] = [0]
        for adjacent in neighbors {
            guard flat.count + adjacent.count < Int(UInt32.max) else { throw LayoutExecutionError.invalidInput("Too many barycenter neighbors.") }
            flat.append(contentsOf: adjacent.map(UInt32.init)); offsets.append(UInt32(flat.count))
        }
        return (ForceState(positions: centers.map { SIMD2($0.x - origin.x, $0.y - origin.y) },
                           fixed: fixed.map { $0 ? 1 : 0 }, offsets: offsets, neighbors: flat), origin)
    }
}
