import Foundation

/// Selects CPU, Metal, or per-operation automatic backend selection.
public enum LayoutBackend: String, Sendable { case cpu, metal, automatic }
public enum LayoutFallbackReason: String, Sendable {
    case belowThreshold, metalUnavailable, precisionLimit, noWork
}
public enum LayoutExecutionError: Error, Equatable, Sendable {
    case invalidInput(String)
    case precisionLimit
    case staleGraph
}

public struct OrganicLayoutConfiguration: Sendable {
    public let quality: OrganicLayoutQuality
    public var initialization: OrganicInitialization = .automatic
    public var nodeSeparation: Double = 20
    public var scope: OrganicScope = .all
    private var storedIterationBudget: Double = 0
    /// Compatibility step count. Setting it replaces any fractional budget.
    public var iterations: Int {
        get {
            guard storedIterationBudget.isFinite, storedIterationBudget >= 0,
                  storedIterationBudget < Double(Int.max / 16) else { return 0 }
            return Int(ceil(storedIterationBudget))
        }
        set { storedIterationBudget = Double(newValue) }
    }
    /// Legacy mode executes ceil(budget) steps and cools using the original fractional
    /// divisor. Quality mode retains its CPU contract of rounding the budget up first.
    public var iterationBudget: Double {
        get { storedIterationBudget }
        set { storedIterationBudget = newValue }
    }
    public var initialTemperature: Double = 100
    /// Nominal strength; quality mode compares half, nominal and double strength.
    public var repulsionForce: Double
    public var attractionForce: Double = 0.05
    var preparedPositions = false
    public init(quality: OrganicLayoutQuality = .quality) {
        self.quality = quality
        storedIterationBudget = quality == .quality ? 600 : 100
        repulsionForce = quality == .quality ? 100 : 2000
    }
    func validate() throws {
        guard iterationBudget.isFinite, iterationBudget >= 0, iterationBudget < Double(Int.max / 16),
              [initialTemperature, repulsionForce, attractionForce, nodeSeparation].allSatisfy({ $0.isFinite && $0 >= 0 }),
              (repulsionForce * repulsionForce * 4).isFinite else {
            throw LayoutExecutionError.invalidInput("Iterations, temperature, forces and separation must be finite, nonnegative and within numerical range.")
        }
    }
}

/// Conservative, configurable heuristics; automatic selection is opt-in, not a universal crossover.
public struct MetalLayoutOptions: Sendable {
    public var minimumNodeCount = 1_024
    public var minimumIterations = 10
    public var minimumBundlingEdgeCount = 256
    /// Radial layouts are selected by within-ring pair count, independent of iteration thresholds.
    public var minimumRadialPairCount = 131_072
    public var iterationsPerBatch = 8
    /// Float precision allowance: coordinate ULP for forces/averaging, and pair-ranking error for radial clearance.
    public var maximumCoordinateError: Double = 0.01
    public init() {}
    func validate() throws {
        guard minimumNodeCount >= 0, minimumIterations >= 0, minimumBundlingEdgeCount >= 0, minimumRadialPairCount >= 0, iterationsPerBatch > 0,
              maximumCoordinateError.isFinite, maximumCoordinateError > 0 else {
            throw LayoutExecutionError.invalidInput("Invalid Metal selection, batch or precision options.")
        }
    }
}

public struct LayoutExecutionMetrics: Sendable {
    public let requestedBackend: LayoutBackend
    public let backend: LayoutBackend
    public let fallbackReason: LayoutFallbackReason?
    public let nodeCount: Int
    public let iterations: Int
    /// Compute-side preparation, lazy pipeline creation, submission, waiting and readback.
    public internal(set) var computeSeconds: Double
    /// Includes snapshot capture, executor queueing and graph write-back when obtained from an operation.
    public internal(set) var totalSeconds: Double
    public let gpuSeconds: Double?
    public let deviceName: String?
    /// CPU tree rebuilding and upload within organic Metal solves; included in computeSeconds.
    public internal(set) var cpuPreparationSeconds: Double = 0
    /// Stages executed on CPU, including preparation or exact reconstruction in hybrid operations.
    public internal(set) var cpuStages: [String] = []
    /// Stages that actually submitted computation to Metal; empty for CPU/no-work execution.
    public internal(set) var metalStages: [String] = []
    /// Organic quality CPU preparation, candidate solves and CPU quality cleanup/scoring.
    /// Nil for operations that do not run a candidate search. Solver time includes
    /// backend preparation, submission and readback, not just GPU execution.
    public internal(set) var qualityPhases: OrganicQualityTimings? = nil
}
public struct OrganicQualityTimings: Sendable {
    public let preparationSeconds: Double
    public let solverSeconds: Double
    public let evaluationSeconds: Double
}
/// Execution records for successfully completed backend-aware operations.
/// Composite operations report each child separately, in execution order.
public protocol LayoutExecutionReporting: AsyncLayoutAlgorithm {
    var lastExecutionMetrics: [LayoutExecutionMetrics] { get }
}
extension OrganicLayoutOperation: LayoutExecutionReporting {
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
}
extension EdgeBundlingOperation: LayoutExecutionReporting {
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
}
extension BarycenterLayoutOperation: LayoutExecutionReporting {
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
}
public struct LayoutExecutorStatistics: Sendable {
    public let pipelineBuilds: Int
    public let bufferAllocations: Int
    public let bufferReuses: Int
    public let submittedBatches: Int
    public let completedBatches: Int
    public let cachedBufferBytes: Int
}

/// Reusable compute owner. Only immutable, Sendable snapshots/results cross this actor boundary.
public actor LayoutExecutor {
    public static let shared = LayoutExecutor()
    public nonisolated static var isMetalAvailable: Bool { MetalForceSolver.isAvailable }
    public let options: MetalLayoutOptions
    var metal: MetalForceSolver?
    var routingWorker: RoutingComputeWorker?
    let metalEnabled: Bool
    public init(options: MetalLayoutOptions = .init()) { self.options = options; metalEnabled = true }
    // Deterministic unavailable-device testing, without a public "pretend Metal" backend.
    init(options: MetalLayoutOptions = .init(), metalEnabled: Bool) { self.options = options; self.metalEnabled = metalEnabled }

    public func statistics() -> LayoutExecutorStatistics {
        let routing = routingWorker?.statisticsSnapshot()
        return LayoutExecutorStatistics(pipelineBuilds: (metal?.pipelineBuilds ?? 0) + (routing?.pipelineBuilds ?? 0),
                                 bufferAllocations: (metal?.bufferAllocations ?? 0) + (routing?.bufferAllocations ?? 0),
                                 bufferReuses: (metal?.bufferReuses ?? 0) + (routing?.bufferReuses ?? 0),
                                 submittedBatches: (metal?.submittedBatches ?? 0) + (routing?.submittedBatches ?? 0),
                                 completedBatches: (metal?.completedBatches ?? 0) + (routing?.completedBatches ?? 0),
                                 cachedBufferBytes: (metal?.cachedBufferBytes ?? 0) + (routing?.cachedBufferBytes ?? 0))
    }
    /// Releases idle buffers only; resources belonging to in-flight requests remain retained.
    public func releaseCachedBuffers() async {
        metal?.releaseCachedBuffers()
        await routingWorker?.releaseCachedBuffers()
    }

    func organic(_ snapshot: GeometrySnapshot, configuration: OrganicLayoutConfiguration, backend: LayoutBackend) async throws -> OrganicResult {
        let start = ContinuousClock.now
        try Task.checkCancellation(); try configuration.validate(); try options.validate()
        let fixed = snapshot.nodes.map { $0.fixed || (configuration.scope == .subset && !$0.selected) }
        var chosen = backend, reason: LayoutFallbackReason?
        if snapshot.nodes.isEmpty || configuration.iterations == 0 || fixed.allSatisfy({ $0 }) {
            return OrganicResult(centers: snapshot.nodes.map { $0.bounds.center }, fixed: fixed,
                                 metrics: metrics(backend, .cpu, .noWork, snapshot, configuration, start),
                                 diagnostics: configuration.quality == .quality ? try OrganicQualitySearch(snapshot, configuration).diagnostics : nil)
        }
        if backend == .automatic {
            if snapshot.nodes.count < options.minimumNodeCount || configuration.iterations < options.minimumIterations {
                chosen = .cpu; reason = .belowThreshold
            } else if !metalEnabled || !Self.isMetalAvailable {
                chosen = .cpu; reason = .metalUnavailable
            } else { chosen = .metal }
        }
        if configuration.quality == .quality {
            do {
                return try await qualityOrganic(snapshot, configuration: configuration, requested: backend, actual: chosen, reason: reason, start: start)
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                return try await qualityOrganic(snapshot, configuration: configuration, requested: backend, actual: .cpu, reason: .precisionLimit, start: start)
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                return try await qualityOrganic(snapshot, configuration: configuration, requested: backend, actual: .cpu, reason: .metalUnavailable, start: start)
            }
        }
        var centers: [Point]
        var cpuPreparation = 0.0
        var gpuTime: Double?
        var deviceName: String?
        if chosen == .metal {
            // Check precision before compiling or allocating GPU resources.
            do {
                let prepared = try snapshot.prepareMetal(configuration: configuration, fixed: fixed, tolerance: options.maximumCoordinateError)
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                if metal == nil { metal = try MetalForceSolver() }
                let solver = metal!
                // Node-count-dependent batch bound keeps large dispatches more cancellable.
                let n = Double(snapshot.nodes.count)
                let workBound = max(1, Int(min(64, 16_777_216 / max(1, n * n))))
                let result = try await solver.solveAsync(prepared.state, iterations: configuration.iterations,
                    temperature: Float(configuration.initialTemperature),
                    parameters: ForceParameters(repulsionSquared: Float(configuration.repulsionForce * configuration.repulsionForce), attraction: Float(configuration.attractionForce)),
                    batchSize: min(options.iterationsPerBatch, workBound),
                    coolingIterationBudget: configuration.iterationBudget)
                gpuTime = result.gpuSeconds; deviceName = solver.deviceName
                cpuPreparation += result.cpuPreparationSeconds
                guard result.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                    throw OrganicLayoutError.metalFailure("Non-finite output coordinates")
                }
                guard result.positions.allSatisfy({ Double(max(abs($0.x), abs($0.y)).ulp) <= options.maximumCoordinateError }) else {
                    throw LayoutExecutionError.precisionLimit
                }
                if fixed.contains(true) {
                    centers = result.positions.map { Point(x: Double($0.x) + prepared.origin.x, y: Double($0.y) + prepared.origin.y) }
                } else {
                    let minX = result.positions.map(\.x).min()!, minY = result.positions.map(\.y).min()!
                    centers = result.positions.map { Point(x: Double($0.x - minX), y: Double($0.y - minY)) }
                }
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu; reason = .precisionLimit
                centers = try snapshot.cpuOrganic(configuration)
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu; reason = .metalUnavailable
                centers = try snapshot.cpuOrganic(configuration)
            }
        } else { centers = try snapshot.cpuOrganic(configuration) }
        try Task.checkCancellation()
        guard centers.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw LayoutExecutionError.invalidInput("Force calculation produced non-finite coordinates.")
        }
        return OrganicResult(centers: centers, fixed: fixed,
            metrics: metrics(backend, chosen, reason, snapshot, configuration, start, gpu: gpuTime, device: deviceName, cpuPreparation: cpuPreparation))
    }
    private func qualityOrganic(_ snapshot: GeometrySnapshot, configuration: OrganicLayoutConfiguration,
                                requested: LayoutBackend, actual: LayoutBackend, reason: LayoutFallbackReason?,
                                start: ContinuousClock.Instant) async throws -> OrganicResult {
        let preparationStart = ContinuousClock.now
        var search = try OrganicQualitySearch(snapshot, configuration)
        let starts = search.starts()
        // Reject predictable precision failures before submitting any candidate. Automatic
        // fallback therefore does not discard successful GPU solves from timing/iteration totals.
        if actual == .metal {
            for positions in starts {
                for strength in [0.5, 1.0, 2.0] {
                    try Task.checkCancellation()
                    let (input, candidate) = search.candidate(positions, strength: strength)
                    _ = try input.prepareMetal(configuration: candidate, fixed: search.fixed, tolerance: options.maximumCoordinateError)
                }
            }
        }
        let preparationSeconds = preparationStart.duration(to: .now).seconds
        var solverSeconds = 0.0, evaluationSeconds = 0.0, cpuPreparation = 0.0
        var gpu: Double?, device: String?
        for positions in starts {
            for strength in [0.5, 1.0, 2.0] {
                try Task.checkCancellation()
                let (input, candidate) = search.candidate(positions, strength: strength)
                let solveStart = ContinuousClock.now
                let result = try await organic(input, configuration: candidate, backend: actual)
                solverSeconds += solveStart.duration(to: .now).seconds
                cpuPreparation += result.metrics.cpuPreparationSeconds
                if let seconds = result.metrics.gpuSeconds { gpu = (gpu ?? 0) + seconds }
                device = result.metrics.deviceName
                let evaluationStart = ContinuousClock.now
                try search.consider(result.centers)
                evaluationSeconds += evaluationStart.duration(to: .now).seconds
            }
        }
        try Task.checkCancellation()
        var executionMetrics = metrics(requested, actual, reason, snapshot, configuration, start, gpu: gpu, device: device, cpuPreparation: cpuPreparation)
        executionMetrics.qualityPhases = OrganicQualityTimings(preparationSeconds: preparationSeconds,
            solverSeconds: solverSeconds, evaluationSeconds: evaluationSeconds)
        return OrganicResult(centers: search.best, fixed: search.fixed,
                             metrics: executionMetrics,
                             diagnostics: search.diagnostics)
    }
    private func metrics(_ requested: LayoutBackend, _ actual: LayoutBackend, _ reason: LayoutFallbackReason?,
                         _ snapshot: GeometrySnapshot, _ configuration: OrganicLayoutConfiguration, _ start: ContinuousClock.Instant,
                         gpu: Double? = nil, device: String? = nil, cpuPreparation: Double = 0) -> LayoutExecutionMetrics {
        let elapsed = start.duration(to: .now).seconds
        return LayoutExecutionMetrics(requestedBackend: requested, backend: actual, fallbackReason: reason,
            nodeCount: snapshot.nodes.count, iterations: configuration.iterations, computeSeconds: elapsed,
            totalSeconds: elapsed, gpuSeconds: gpu, deviceName: device, cpuPreparationSeconds: cpuPreparation,
            cpuStages: reason == .noWork ? ["no-work preservation"] :
                (actual == .cpu ? ["organic placement"] : ["initialization, topology and coordinate reconstruction"] +
                    (snapshot.nodes.count >= 64 ? ["Barnes–Hut topology rebuild between iterations"] : [])) +
                (configuration.quality == .quality ? ["candidate cleanup and quality scoring"] : []),
            metalStages: gpu != nil ? [actual == .metal ? "organic force iterations" : "organic force iterations discarded after precision fallback"] : [])
    }
}

/// Async-only operation. Its graph and this operation stay on the caller's actor across suspension.
public final class OrganicLayoutOperation: AsyncLayoutAlgorithm {
    public var configuration: OrganicLayoutConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public private(set) var lastDiagnostics: OrganicLayoutDiagnostics?
    public init(backend: LayoutBackend, executor: LayoutExecutor = .shared, configuration: OrganicLayoutConfiguration = .init()) {
        self.backend = backend; self.executor = executor; self.configuration = configuration
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil; lastDiagnostics = nil
        let start = ContinuousClock.now
        let configuration = self.configuration
        try Task.checkCancellation(); try configuration.validate()
        let checkpoint = try GraphCheckpoint(graph)
        let result = try await executor.organic(checkpoint.snapshot, configuration: configuration, backend: backend)
        try Task.checkCancellation()
        guard checkpoint.matches(graph) else { throw LayoutExecutionError.staleGraph }
        for i in graph.nodes.indices where !result.fixed[i] && configuration.iterations > 0 {
            graph.nodes[i].center = result.centers[i]
        }
        var metrics = result.metrics; metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics; lastDiagnostics = result.diagnostics
    }
}
public extension LayoutBuilder {
    /// Opt-in execution backend; the existing useOrganic closure keeps its CPU behavior.
    @discardableResult func useOrganic(backend: LayoutBackend, executor: LayoutExecutor = .shared,
                                      configure: (inout OrganicLayoutConfiguration) -> Void = { _ in }) -> Self {
        var configuration = OrganicLayoutConfiguration(); configure(&configuration)
        return useAsyncAlgorithm(OrganicLayoutOperation(backend: backend, executor: executor, configuration: configuration))
    }
}

struct OrganicResult: Sendable {
    var centers: [Point]
    var fixed: [Bool]
    var metrics: LayoutExecutionMetrics
    var diagnostics: OrganicLayoutDiagnostics? = nil
}
struct GeometrySnapshot: Sendable {
    struct Node: Sendable, Equatable { var bounds: Rect; var fixed: Bool; var selected: Bool; var isGroup: Bool = false }
    struct Edge: Sendable { var source: Int; var target: Int; var index: Int }
    var nodes: [Node]
    var edges: [Edge]
    func makeGraph() -> LayoutGraph {
        let graph = LayoutGraph()
        for (i, state) in nodes.enumerated() {
            let n = LayoutNode(id: String(i), width: state.bounds.width, height: state.bounds.height)
            n.bounds = state.bounds
            n.isGroup = state.isGroup
            n.metadata[GraphMetadataKeys.fixed] = state.fixed
            n.metadata[GraphMetadataKeys.layoutSubset] = state.selected
            graph.addNode(n)
        }
        for edge in edges { graph.addEdge(LayoutEdge(source: graph.nodes[edge.source], target: graph.nodes[edge.target])) }
        return graph
    }
    func cpuOrganic(_ configuration: OrganicLayoutConfiguration) throws -> [Point] {
        let graph = makeGraph()
        let algorithm = OrganicLayoutAlgorithm(quality: configuration.quality)
        algorithm.preparedPositions = configuration.preparedPositions
        algorithm.initialization = configuration.initialization; algorithm.nodeSeparation = configuration.nodeSeparation
        algorithm.scope = configuration.scope; algorithm.iterations = configuration.quality == .quality ? Double(configuration.iterations) : configuration.iterationBudget
        algorithm.initialTemperature = configuration.initialTemperature
        algorithm.repulsionForce = configuration.repulsionForce; algorithm.attractionForce = configuration.attractionForce
        try algorithm.applyLayout(graph)
        return graph.nodes.map(\.center)
    }
    func prepareMetal(configuration: OrganicLayoutConfiguration, fixed: [Bool], tolerance: Double) throws -> (state: ForceState, origin: Point) {
        var centers = nodes.map { $0.bounds.center }
        if !configuration.preparedPositions && nodes.allSatisfy({ $0.bounds.x == 0 && $0.bounds.y == 0 }) {
            var random = SeededRandom()
            for i in nodes.indices where !fixed[i] {
                centers[i] = Point(x: random.next() * 1_000 + nodes[i].bounds.width / 2,
                                   y: random.next() * 1_000 + nodes[i].bounds.height / 2)
            }
        }
        let minX = centers.map(\.x).min()!, maxX = centers.map(\.x).max()!
        let minY = centers.map(\.y).min()!, maxY = centers.map(\.y).max()!
        let origin = Point(x: minX + (maxX - minX) / 2, y: minY + (maxY - minY) / 2)
        let bound = max(maxX - minX, maxY - minY) / 2 + Double(configuration.iterations) * configuration.initialTemperature
        var neighbors = Array(repeating: [UInt32](), count: nodes.count)
        for e in edges where e.source != e.target {
            neighbors[e.source].append(UInt32(e.target)); neighbors[e.target].append(UInt32(e.source))
        }
        let degree = neighbors.map(\.count).max() ?? 0
        let forceBound = Double(nodes.count) * configuration.repulsionForce * configuration.repulsionForce * 10
            + Double(degree) * bound * 4 * configuration.attractionForce
        guard bound.isFinite, Float(bound).isFinite, Double(Float(bound).ulp) <= tolerance,
              forceBound.isFinite, forceBound < Double(sqrt(Float.greatestFiniteMagnitude)) / 4,
              Float(configuration.initialTemperature).isFinite, Float(configuration.attractionForce).isFinite else {
            throw LayoutExecutionError.precisionLimit
        }
        var flat: [UInt32] = [], offsets: [UInt32] = [0]
        for adjacent in neighbors {
            guard flat.count + adjacent.count < Int(UInt32.max) else { throw LayoutExecutionError.invalidInput("Too many edges for Metal indices.") }
            flat.append(contentsOf: adjacent); offsets.append(UInt32(flat.count))
        }
        return (ForceState(positions: centers.map { SIMD2(Float($0.x - origin.x), Float($0.y - origin.y)) },
                           fixed: fixed.map { $0 ? 1 : 0 }, offsets: offsets, neighbors: flat), origin)
    }
}

/// Kept on the graph's owner. No graph reference crosses the executor boundary.
struct GraphCheckpoint {
    let nodes: [LayoutNode]
    let edges: [LayoutEdge]
    let parents: [LayoutNode?]
    let children: [[LayoutNode]]
    let groups: [Bool]
    let rootChildren: [LayoutNode]
    let snapshot: GeometrySnapshot
    init(_ graph: LayoutGraph) throws {
        nodes = graph.nodes; edges = graph.edges
        guard Set(nodes).count == nodes.count, nodes.count < Int(UInt32.max) else {
            throw LayoutExecutionError.invalidInput("Node references must be unique and fit in 32-bit indices.")
        }
        guard nodes.allSatisfy({ n in [n.x, n.y, n.width, n.height, n.center.x, n.center.y].allSatisfy(\.isFinite) && n.width >= 0 && n.height >= 0 }) else {
            throw LayoutExecutionError.invalidInput("Finite geometry and nonnegative dimensions are required.")
        }
        parents = nodes.map(\.parent); children = nodes.map(\.children); groups = nodes.map(\.isGroup)
        rootChildren = graph.root.children
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, $0.offset) })
        snapshot = GeometrySnapshot(nodes: nodes.map(Self.state), edges: edges.enumerated().compactMap { i, e in
            guard let s = index[e.source], let t = index[e.target] else { return nil }
            return .init(source: s, target: t, index: i)
        })
    }
    private static func state(_ n: LayoutNode) -> GeometrySnapshot.Node {
        .init(bounds: n.bounds, fixed: n.metadata[GraphMetadataKeys.fixed] as? Bool == true,
              selected: n.metadata[GraphMetadataKeys.layoutSubset] as? Bool == true, isGroup: n.isGroup)
    }
    func matches(_ graph: LayoutGraph) -> Bool {
        graph.nodes == nodes && graph.edges == edges && graph.root.children == rootChildren &&
        nodes.map(Self.state) == snapshot.nodes && nodes.map(\.parent) == parents &&
        nodes.map(\.children) == children && nodes.map(\.isGroup) == groups
    }
}
