import Foundation

public struct EdgeBundlingConfiguration: Sendable {
    public var iterations = 30
    public var segments = 10
    public var k: Double = 0.1
    public var compatibilityThreshold: Double = 0.6
    public var bundlingDistance: Double = 500
    public init() {}
    func validate() throws {
        guard iterations >= 0, segments >= 0, k.isFinite, k >= 0, compatibilityThreshold.isFinite,
              (0...1).contains(compatibilityThreshold), bundlingDistance.isFinite, bundlingDistance >= 0 else {
            throw LayoutExecutionError.invalidInput("Invalid edge bundling configuration.")
        }
    }
}

/// Async routing operation; self-loops and node geometry are preserved.
public final class EdgeBundlingOperation: AsyncLayoutAlgorithm {
    public var configuration: EdgeBundlingConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public init(backend: LayoutBackend, executor: LayoutExecutor = .shared, configuration: EdgeBundlingConfiguration = .init()) {
        self.backend = backend; self.executor = executor; self.configuration = configuration
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now, configuration = self.configuration
        try Task.checkCancellation(); try configuration.validate()
        let checkpoint = try GraphCheckpoint(graph), paths = graph.edges.map(\.path)
        let result = try await executor.bundle(checkpoint.snapshot, configuration: configuration, backend: backend)
        try Task.checkCancellation()
        guard checkpoint.matches(graph), graph.edges.map(\.path) == paths else { throw LayoutExecutionError.staleGraph }
        for edge in result.paths { graph.edges[edge.index].path = edge.points }
        var metrics = result.metrics; metrics.totalSeconds = start.duration(to: .now).seconds; lastMetrics = metrics
    }
}
public extension LayoutBuilder {
    @discardableResult func routeWithBundling(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout EdgeBundlingConfiguration) -> Void = { _ in }) -> Self {
        var configuration = EdgeBundlingConfiguration(); configure(&configuration)
        return useAsyncAlgorithm(EdgeBundlingOperation(backend: backend, executor: executor, configuration: configuration))
    }
}
struct BundledPath: Sendable { var index: Int; var points: [Point] }
struct BundlingResult: Sendable { var paths: [BundledPath]; var metrics: LayoutExecutionMetrics }
struct BundlingState: Sendable {
    var positions: [SIMD2<Float>]
    var offsets: [UInt32]
    var compatible: [SIMD2<UInt32>]
    var springs: [Float]
    var segments: Int
}

extension LayoutExecutor {
    func bundle(_ snapshot: GeometrySnapshot, configuration: EdgeBundlingConfiguration, backend: LayoutBackend) async throws -> BundlingResult {
        let start = ContinuousClock.now
        try Task.checkCancellation(); try configuration.validate(); try options.validate()
        let edges = snapshot.edges.filter { $0.source != $0.target }
        guard edges.isEmpty || max(1, configuration.segments) < 8_388_608 / edges.count else {
            throw LayoutExecutionError.invalidInput("Bundling exceeds the 64 MiB control-point limit.")
        }
        var chosen = backend, reason: LayoutFallbackReason?, gpuTime: Double?, device: String?
        var paths: [BundledPath]
        if edges.isEmpty || configuration.iterations == 0 || configuration.segments <= 1 {
            chosen = .cpu; reason = .noWork
        } else if backend == .automatic {
            if edges.count < options.minimumBundlingEdgeCount || configuration.iterations < options.minimumIterations {
                chosen = .cpu; reason = .belowThreshold
            } else if !metalEnabled || !Self.isMetalAvailable {
                chosen = .cpu; reason = .metalUnavailable
            } else { chosen = .metal }
        }
        if chosen == .metal {
            do {
                let prepared = try snapshot.prepareBundling(configuration, tolerance: options.maximumCoordinateError)
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                if metal == nil { metal = try MetalForceSolver() }
                let result = try await metal!.bundleAsync(prepared.state, iterations: configuration.iterations, batchSize: options.iterationsPerBatch)
                device = metal!.deviceName; gpuTime = result.gpuSeconds
                guard result.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw OrganicLayoutError.metalFailure("Non-finite bundle coordinates") }
                guard result.positions.allSatisfy({ Double(max(abs($0.x), abs($0.y)).ulp) <= options.maximumCoordinateError }) else { throw LayoutExecutionError.precisionLimit }
                let stride = prepared.state.segments + 1
                paths = edges.enumerated().map { i, edge in
                    var points = result.positions[(i * stride)..<((i + 1) * stride)].map {
                        Point(x: Double($0.x) + prepared.origin.x, y: Double($0.y) + prepared.origin.y)
                    }
                    // Exact Double endpoints remain attached even when absolute coordinates are large.
                    points[0] = snapshot.nodes[edge.source].bounds.center
                    points[points.count - 1] = snapshot.nodes[edge.target].bounds.center
                    return BundledPath(index: edge.index, points: points)
                }
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu; reason = .precisionLimit; paths = try snapshot.cpuBundle(configuration)
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu; reason = .metalUnavailable; paths = try snapshot.cpuBundle(configuration)
            }
        } else { paths = try snapshot.cpuBundle(configuration) }
        try Task.checkCancellation()
        guard paths.allSatisfy({ $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else {
            throw LayoutExecutionError.invalidInput("Non-finite bundle coordinates")
        }
        let elapsed = start.duration(to: .now).seconds
        return BundlingResult(paths: paths, metrics: LayoutExecutionMetrics(requestedBackend: backend, backend: chosen,
            fallbackReason: reason, nodeCount: snapshot.nodes.count, iterations: configuration.iterations,
            computeSeconds: elapsed, totalSeconds: elapsed, gpuSeconds: gpuTime, deviceName: device,
            cpuStages: chosen == .metal ? ["compatibility construction", "control point initialization", "exact endpoint reconstruction"] : ["edge bundling"],
            metalStages: chosen == .metal ? ["bundling iterations"] : (gpuTime == nil ? [] : ["discarded bundling iterations before CPU fallback"])))
    }
}

extension GeometrySnapshot {
    func cpuBundle(_ configuration: EdgeBundlingConfiguration) throws -> [BundledPath] {
        let graph = makeGraph(), router = EdgeBundlingRouter()
        router.iterations = configuration.iterations; router.segments = configuration.segments; router.k = configuration.k
        router.compatibilityThreshold = configuration.compatibilityThreshold; router.bundlingDistance = configuration.bundlingDistance
        router.routeEdges(graph)
        try Task.checkCancellation()
        return zip(edges, graph.edges).filter { $0.0.source != $0.0.target }.map { BundledPath(index: $0.0.index, points: $0.1.path) }
    }
    func prepareBundling(_ configuration: EdgeBundlingConfiguration, tolerance: Double) throws -> (state: BundlingState, origin: Point) {
        let edges = edges.filter { $0.source != $0.target }, segments = max(1, configuration.segments)
        guard edges.count < Int(UInt32.max), segments < Int(UInt32.max) / max(1, edges.count) - 1 else {
            throw LayoutExecutionError.invalidInput("Too many bundle points for Metal indices.")
        }
        let starts = edges.map { nodes[$0.source].bounds.center }, ends = edges.map { nodes[$0.target].bounds.center }
        let all = starts + ends
        let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
        let minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
        let origin = Point(x: minX + (maxX - minX) / 2, y: minY + (maxY - minY) / 2)
        let directions = zip(starts, ends).map { $1 - $0 }, lengths = directions.map(\.length)
        // Keep compatibility decisions identical to the synchronous router, including
        // Double midpoint rounding at a bundling-distance threshold.
        let centers = zip(starts, ends).map { ($0 + $1) / 2 }
        let extent = max(maxX - minX, maxY - minY)
        let movement = Double(configuration.iterations) * (Double(edges.count) + configuration.k * max(1, extent) * 40) * 0.1
        let bound = extent + movement
        guard bound.isFinite, Float(bound).isFinite, Double(Float(bound).ulp) <= tolerance,
              configuration.k <= 1e6 else { throw LayoutExecutionError.precisionLimit }
        var positions: [SIMD2<Float>] = [], offsets: [UInt32] = [0], compatible: [SIMD2<UInt32>] = [], springs: [Float] = []
        for i in edges.indices {
            try Task.checkCancellation()
            for p in 0...segments {
                let position = starts[i] - origin + directions[i] * (Double(p) / Double(segments))
                positions.append(SIMD2(Float(position.x), Float(position.y)))
            }
            springs.append(lengths[i] > 0.1 ? Float(configuration.k / (lengths[i] * Double(segments))) : 0)
            if lengths[i] > 0.1 {
                for j in edges.indices where i != j && lengths[j] > 0.1 && (centers[i] - centers[j]).length <= configuration.bundlingDistance {
                    let dot = (directions[i].x * directions[j].x + directions[i].y * directions[j].y) / (lengths[i] * lengths[j])
                    if abs(dot) > configuration.compatibilityThreshold {
                        guard compatible.count < 8_388_608 else { throw LayoutExecutionError.invalidInput("Metal bundling compatibility exceeds the 64 MiB limit.") }
                        compatible.append(SIMD2(UInt32(j), dot < 0 ? 1 : 0))
                    }
                }
            }
            offsets.append(UInt32(compatible.count))
        }
        return (BundlingState(positions: positions, offsets: offsets, compatible: compatible, springs: springs, segments: segments), origin)
    }
}
