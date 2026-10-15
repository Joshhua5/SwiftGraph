import Foundation

public enum RadialLayoutStyle: String, CaseIterable, Sendable { case radial, star, tree }

public struct RadialLayoutConfiguration: Sendable {
    /// Minimum spacing between rings (the star's minimum radius).
    public var spacing: Float
    public init(spacing: Float = 100) { self.spacing = spacing }
    func validate() throws {
        guard spacing.isFinite, spacing >= 0 else {
            throw LayoutExecutionError.invalidInput("Radial spacing must be finite and nonnegative.")
        }
    }
}

/// Accelerates pairwise ring clearance. Traversal, component packing and obstacle
/// repair retain CPU semantics, including the synchronous formats' treatment of groups.
public final class RadialLayoutOperation: LayoutExecutionReporting {
    public let style: RadialLayoutStyle
    public var configuration: RadialLayoutConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
    public init(style: RadialLayoutStyle = .radial, backend: LayoutBackend,
                executor: LayoutExecutor = .shared, configuration: RadialLayoutConfiguration? = nil) {
        self.style = style; self.backend = backend; self.executor = executor
        self.configuration = configuration ?? .init(spacing: style == .star ? 200 : 100)
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now, configuration = self.configuration
        try Task.checkCancellation(); try configuration.validate()
        let transaction = try LayoutTransaction(graph)
        let result = try await executor.radial(try GraphCheckpoint(transaction.working).snapshot,
            style: style, configuration: configuration, backend: backend)
        for (node, bounds) in zip(transaction.working.nodes, result.bounds) { node.bounds = bounds }
        if result.routeEdges {
            straightEdges(transaction.working)
            ObstaclePolyline.repair(transaction.working)
        }
        try transaction.commit(to: graph)
        var metrics = result.metrics; metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics
    }
}

public extension LayoutBuilder {
    @discardableResult func useRadial(backend: LayoutBackend, executor: LayoutExecutor = .shared,
                                      configure: (inout RadialLayoutConfiguration) -> Void = { _ in }) -> Self {
        var configuration = RadialLayoutConfiguration(); configure(&configuration)
        return useAsyncAlgorithm(RadialLayoutOperation(backend: backend, executor: executor, configuration: configuration))
    }
    @discardableResult func useRadialStar(backend: LayoutBackend, executor: LayoutExecutor = .shared,
                                          configure: (inout RadialLayoutConfiguration) -> Void = { _ in }) -> Self {
        var configuration = RadialLayoutConfiguration(spacing: 200); configure(&configuration)
        return useAsyncAlgorithm(RadialLayoutOperation(style: .star, backend: backend, executor: executor, configuration: configuration))
    }
    @discardableResult func useRadialTree(backend: LayoutBackend, executor: LayoutExecutor = .shared,
                                          configure: (inout RadialLayoutConfiguration) -> Void = { _ in }) -> Self {
        var configuration = RadialLayoutConfiguration(); configure(&configuration)
        return useAsyncAlgorithm(RadialLayoutOperation(style: .tree, backend: backend, executor: executor, configuration: configuration))
    }
    @discardableResult func applyMindMap(backend: LayoutBackend, executor: LayoutExecutor = .shared,
                                         layerDistance: Float = 100) -> Self {
        let configuration = RadialLayoutConfiguration(spacing: layerDistance)
        let core = RadialLayoutOperation(style: .tree, backend: backend, executor: executor, configuration: configuration)
        return groupedPreset(core, routing: .polyline, backend: backend, executor: executor)
    }
}

struct RadialResult: Sendable {
    var bounds: [Rect]
    var routeEdges: Bool
    var metrics: LayoutExecutionMetrics
}

/// Ring membership and angles are determined in Double on CPU. The GPU finds the
/// tightest pair for each node; those candidate pairs are re-evaluated on CPU.
struct RadialRing: Sendable {
    var indices: [Int]
    var angles: [Double]
    var diameters: [Float]
    var depth: Int
    var minimumChord: Double {
        guard angles.count > 1 else { return 2 }
        let sorted = angles.sorted()
        var result = 2 * abs(sin((sorted.last! - sorted.first!) / 2))
        for i in 1..<sorted.count { result = min(result, 2 * abs(sin((sorted[i] - sorted[i - 1]) / 2))) }
        return result
    }
    mutating func normalizeCollapsedAngles() {
        // The smallest circular gap is between sorted neighbors, including the
        // wraparound pair. This is the same collapse test as the CPU pair scan.
        if angles.count > 1 && minimumChord < 2e-12 {
            angles = angles.indices.map { Double($0) * 2 * .pi / Double(angles.count) }
        }
    }
    func clearance(_ i: Int, _ j: Int) -> Float {
        ((diameters[i] + diameters[j]) / 2 + 20) / Float(2 * abs(sin((angles[i] - angles[j]) / 2)))
    }
    func cpuClearance() throws -> Float {
        var radius: Float = 0.0
        for i in indices.indices {
            if i % 128 == 0 { try Task.checkCancellation() }
            for j in (i + 1)..<indices.count { radius = max(radius, clearance(i, j)) }
        }
        return radius
    }
}

struct RadialPlacementPlan {
    struct Component { var indices: [Int]; var rings: Range<Int> }
    var rings: [RadialRing] = []
    var components: [Component] = []
    let style: RadialLayoutStyle
    var pairCount: Double { rings.reduce(0) { $0 + Double($1.indices.count) * Double(max(0, $1.indices.count - 1)) / 2 } }

    init(_ graph: LayoutGraph, style: RadialLayoutStyle) throws {
        self.style = style
        let a = Adjacency(graph, excludingGroups: style != .tree)
        let global = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element, $0.offset) })
        func append(_ indices: [Int], depth: [Int], angles: [Double]) {
            let firstRing = rings.count
            let byDepth = Dictionary(grouping: indices, by: { depth[$0] })
            for d in byDepth.keys.sorted() {
                let members = byDepth[d]!
                var ring = RadialRing(indices: members.map { global[a.nodes[$0]]! }, angles: members.map { angles[$0] },
                    diameters: members.map { hypot(a.nodes[$0].width, a.nodes[$0].height) }, depth: d)
                ring.normalizeCollapsedAngles(); rings.append(ring)
            }
            components.append(Component(indices: indices.map { global[a.nodes[$0]]! }, rings: firstRing..<rings.count))
        }
        if style == .tree {
            let forest = Forest(a)
            for root in forest.roots {
                try Task.checkCancellation()
                var indices: [Int] = [], angles = Array(repeating: 0.0, count: a.nodes.count)
                var stack = [(root, 0.0, 2 * Double.pi)]
                while let (i, start, end) = stack.popLast() {
                    angles[i] = (start + end) / 2; indices.append(i)
                    let children = forest.children[i], sweep = (end - start) / Double(max(1, children.count))
                    for (j, child) in children.enumerated().reversed() {
                        stack.append((child, start + Double(j) * sweep, start + Double(j + 1) * sweep))
                    }
                }
                append(indices, depth: forest.depth, angles: angles)
            }
        } else if let root = a.nodes.indices.max(by: {
            a.neighbors[$0].count == a.neighbors[$1].count ? $0 > $1 : a.neighbors[$0].count < a.neighbors[$1].count
        }) {
            var depth = Array(repeating: style == .star ? 1 : -1, count: a.nodes.count)
            depth[root] = 0
            if style == .radial {
                var queue = [root], cursor = 0
                while cursor < queue.count {
                    if cursor % 128 == 0 { try Task.checkCancellation() }
                    let i = queue[cursor]; cursor += 1
                    for j in a.neighbors[i] where depth[j] < 0 { depth[j] = depth[i] + 1; queue.append(j) }
                }
                let outer = (depth.max() ?? 0) + 1
                for i in depth.indices where depth[i] < 0 { depth[i] = outer }
            }
            var angles = Array(repeating: 0.0, count: a.nodes.count)
            for (d, members) in Dictionary(grouping: Array(a.nodes.indices), by: { depth[$0] }) where d > 0 {
                for (j, i) in members.enumerated() { angles[i] = Double(j) * 2 * .pi / Double(members.count) }
            }
            append(Array(a.nodes.indices), depth: depth, angles: angles)
        }
    }
    func apply(_ clearances: [Float], to graph: LayoutGraph, spacing: Float) throws {
        for component in components {
            var previousRadius: Float = 0.0, previousHalf: Float = 0.0
            var placed: [Rect] = []
            for index in component.rings {
                try Task.checkCancellation()
                let ring = rings[index], half = (ring.diameters.max() ?? 0) / 2
                let base = ring.depth == 0 ? 0 : previousRadius + (style == .tree ? spacing : max(spacing, previousHalf + half + 20))
                var radius = max(base, clearances[index])
                if style == .tree { radius = fittedRadialDepth(ring.indices.map { graph.nodes[$0] }, angles: ring.angles, previous: placed, minimum: radius) }
                for (i, node) in ring.indices.enumerated() {
                    graph.nodes[node].center = Point(x: radius * Float(cos(ring.angles[i])), y: radius * Float(sin(ring.angles[i])))
                }
                placed += ring.indices.map { graph.nodes[$0].bounds }
                previousRadius = radius; previousHalf = half
            }
        }
        if style == .tree { packForest(graph.nodes, components: components.map(\.indices), spacing: max(20, spacing)) }
    }
}

extension LayoutExecutor {
    func radial(_ snapshot: GeometrySnapshot, style: RadialLayoutStyle, configuration: RadialLayoutConfiguration,
                backend: LayoutBackend) async throws -> RadialResult {
        let start = ContinuousClock.now
        try Task.checkCancellation(); try configuration.validate(); try options.validate()
        let graph = snapshot.makeGraph(), plan = try RadialPlacementPlan(graph, style: style)
        var chosen = backend, reason: LayoutFallbackReason?, gpu: Double?, device: String?
        if plan.pairCount == 0 { chosen = .cpu; reason = .noWork }
        else if backend == .automatic {
            if plan.pairCount < Double(options.minimumRadialPairCount) { chosen = .cpu; reason = .belowThreshold }
            else if !metalEnabled || !Self.isMetalAvailable { chosen = .cpu; reason = .metalUnavailable }
            else { chosen = .metal }
        }
        var clearances: [Float] = []
        if chosen == .metal {
            do {
                let state = try RadialClearanceState(plan.rings, tolerance: options.maximumCoordinateError)
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                if metal == nil { metal = try MetalForceSolver() }
                let result = try await metal!.radialClearanceAsync(state)
                gpu = result.gpuSeconds; device = metal!.deviceName
                var offset = 0
                for ring in plan.rings {
                    var radius: Float = 0.0
                    for i in ring.indices.indices {
                        let j = Int(result.partners[offset + i]) - offset
                        guard j >= i, j < ring.indices.count else { throw OrganicLayoutError.metalFailure("Invalid radial pair index") }
                        if j != i { radius = max(radius, ring.clearance(i, j)) }
                    }
                    clearances.append(radius); offset += ring.indices.count
                }
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu; reason = .precisionLimit
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu; reason = .metalUnavailable
            }
        }
        if chosen == .cpu { clearances = try plan.rings.map { try $0.cpuClearance() } }
        try plan.apply(clearances, to: graph, spacing: configuration.spacing)
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).seconds
        return RadialResult(bounds: graph.nodes.map(\.bounds), routeEdges: style == .tree || !plan.components.isEmpty,
            metrics: LayoutExecutionMetrics(requestedBackend: backend, backend: chosen, fallbackReason: reason,
                nodeCount: snapshot.nodes.count, iterations: plan.pairCount == 0 ? 0 : 1, computeSeconds: elapsed,
                totalSeconds: elapsed, gpuSeconds: gpu, deviceName: device,
                cpuStages: chosen == .metal ? ["traversal and ring planning", "Double radius reconstruction and packing", "obstacle route repair"] : ["radial placement and routing"],
                metalStages: chosen == .metal ? ["ring clearance pair selection"] : []))
    }
}

struct RadialClearanceState: Sendable {
    /// High/low angle splitting preserves narrow tree sectors and the circular seam.
    var angles: [SIMD2<Float>] = []
    var diameters: [Float] = []
    var ends: [UInt32] = []
    var maximumRingSize = 0
    init(_ rings: [RadialRing], tolerance: Float) throws {
        for ring in rings {
            try Task.checkCancellation()
            let end = angles.count + ring.indices.count
            guard end < Int(UInt32.max) else { throw LayoutExecutionError.invalidInput("Too many radial nodes") }
            let chord = ring.minimumChord
            let bound = (Double(ring.diameters.max() ?? 0) + 20) / chord
            // A conservative Float arithmetic allowance for ranking candidate pairs.
            guard bound.isFinite, Float(bound).isFinite, bound * (1e-6 + 4e-14 / chord) <= Double(tolerance),
                  ring.diameters.allSatisfy(\.isFinite) else { throw LayoutExecutionError.precisionLimit }
            angles.append(contentsOf: ring.angles.map { angle in
                let high = Float(angle); return SIMD2(high, Float(angle - Double(high)))
            })
            diameters.append(contentsOf: ring.diameters)
            ends.append(contentsOf: repeatElement(UInt32(end), count: ring.indices.count))
            maximumRingSize = max(maximumRingSize, ring.indices.count)
        }
    }
}
