import Foundation

public struct EdgeBundlingConfiguration: Sendable {
    public var iterations = 30
    public var segments = 10
    public var k: Double = 0.1
    public var compatibilityThreshold: Double = 0.6
    public var bundlingDistance: Double = 500
    /// Clearance kept between bundled control points and other nodes.
    public var nodePadding: Double = 8
    /// Lateral gap between edges joining the same two nodes.
    public var edgeSpacing: Double = 8
    public var simplifyTolerance: Double = 2
    public init() {}
    var settings: BundlingSettings {
        BundlingSettings(iterations: iterations, segments: segments, k: k, compatibilityThreshold: compatibilityThreshold, bundlingDistance: bundlingDistance,
                         nodePadding: nodePadding, edgeSpacing: edgeSpacing, simplifyTolerance: simplifyTolerance)
    }
    func validate() throws {
        guard iterations >= 0, segments >= 0, k.isFinite, k >= 0, compatibilityThreshold.isFinite,
              (0...1).contains(compatibilityThreshold), bundlingDistance.isFinite, bundlingDistance >= 0,
              nodePadding.isFinite, nodePadding >= 0, edgeSpacing.isFinite, edgeSpacing >= 0, simplifyTolerance.isFinite, simplifyTolerance >= 0 else {
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
        let result = try await executor.bundle(checkpoint.snapshot, paths: paths, configuration: configuration, backend: backend)
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

/// Metal runs the iteration kernel once per subdivision cycle; compatibility, resampling, node clearance, edge
/// fanning and simplification are the same CPU code the synchronous router uses.
extension LayoutExecutor {
    func bundle(_ snapshot: GeometrySnapshot, paths existing: [[Point]], configuration: EdgeBundlingConfiguration, backend: LayoutBackend) async throws -> BundlingResult {
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
                var (state, bundler) = try snapshot.prepareBundling(configuration, paths: existing, tolerance: options.maximumCoordinateError)
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                if metal == nil { metal = try MetalForceSolver() }
                var seconds = 0.0
                for cycle in bundler.schedule.indices {
                    if cycle > 0 { state = bundler.state(cycle: cycle) }
                    let result = try await metal!.bundleAsync(state, iterations: bundler.schedule[cycle].iterations, batchSize: options.iterationsPerBatch)
                    seconds += result.gpuSeconds
                    guard result.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw OrganicLayoutError.metalFailure("Non-finite bundle coordinates") }
                    bundler.finish(cycle: cycle, positions: result.positions.map { Point(x: Double($0.x), y: Double($0.y)) })
                }
                device = metal!.deviceName; gpuTime = seconds
                paths = zip(edges, bundler.paths()).map { BundledPath(index: $0.index, points: $1) }
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu; reason = .precisionLimit; paths = try snapshot.cpuBundle(configuration, paths: existing)
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu; reason = .metalUnavailable; paths = try snapshot.cpuBundle(configuration, paths: existing)
            }
        } else { paths = try snapshot.cpuBundle(configuration, paths: existing) }
        try Task.checkCancellation()
        guard paths.allSatisfy({ $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else {
            throw LayoutExecutionError.invalidInput("Non-finite bundle coordinates")
        }
        let elapsed = start.duration(to: .now).seconds
        return BundlingResult(paths: paths, metrics: LayoutExecutionMetrics(requestedBackend: backend, backend: chosen,
            fallbackReason: reason, nodeCount: snapshot.nodes.count, iterations: configuration.iterations,
            computeSeconds: elapsed, totalSeconds: elapsed, gpuSeconds: gpuTime, deviceName: device,
            cpuStages: chosen == .metal ? ["compatibility construction", "route resampling and subdivision", "node clearance, edge fanning and simplification"] : ["edge bundling"],
            metalStages: chosen == .metal ? ["bundling iterations"] : (gpuTime == nil ? [] : ["discarded bundling iterations before CPU fallback"])))
    }
}

extension GeometrySnapshot {
    func bundler(_ configuration: EdgeBundlingConfiguration, paths: [[Point]]) -> EdgeBundler {
        EdgeBundler(configuration.settings, nodes: nodes.map(\.bounds), solid: nodes.map { !$0.isGroup },
            edges: edges.filter { $0.source != $0.target }.map {
                .init(source: $0.source, target: $0.target, from: nodes[$0.source].bounds.center, to: nodes[$0.target].bounds.center,
                      path: $0.index < paths.count ? paths[$0.index] : [])
            })
    }
    func cpuBundle(_ configuration: EdgeBundlingConfiguration, paths: [[Point]]) throws -> [BundledPath] {
        var bundler = bundler(configuration, paths: paths)
        guard bundler.runCPU() else { throw CancellationError() }
        try Task.checkCancellation()
        return zip(edges.filter { $0.source != $0.target }, bundler.paths()).map { BundledPath(index: $0.index, points: $1) }
    }
    /// The first cycle's kernel input, after the precision and size checks Metal needs before any submission.
    func prepareBundling(_ configuration: EdgeBundlingConfiguration, paths: [[Point]] = [], tolerance: Double) throws -> (state: BundlingState, bundler: EdgeBundler) {
        var bundler = bundler(configuration, paths: paths)
        guard !bundler.schedule.isEmpty else { throw LayoutExecutionError.invalidInput("Bundling has no iterations to run.") }
        guard bundler.edges.count < Int(UInt32.max), configuration.segments < Int(UInt32.max) / max(1, bundler.edges.count) - 1 else {
            throw LayoutExecutionError.invalidInput("Too many bundle points for Metal indices.")
        }
        let extent = bundler.normalisedExtent
        guard extent.isFinite, Float(extent).isFinite, Double(Float(extent).ulp) * bundler.unit <= tolerance, configuration.k <= 1e6 else { throw LayoutExecutionError.precisionLimit }
        guard bundler.compatible.count < 8_388_608 else { throw LayoutExecutionError.invalidInput("Metal bundling compatibility exceeds the 64 MiB limit.") }
        return (bundler.state(cycle: 0), bundler)
    }
}
