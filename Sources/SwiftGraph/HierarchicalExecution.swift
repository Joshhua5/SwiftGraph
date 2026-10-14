import Foundation

public struct HierarchicalLayoutConfiguration: Sendable {
    public var layerSeparation: Float = 50
    public var nodeSeparation: Float = 50
    public var maxNodesPerRank: Int?
    public var routesEdges = true
    public var rankSeparation: Float { get { layerSeparation } set { layerSeparation = newValue } }
    public init() {}
    func validate() throws {
        guard layerSeparation.isFinite, nodeSeparation.isFinite else {
            throw LayoutExecutionError.invalidInput("Hierarchy spacing must be finite.")
        }
    }
}

/// Rank construction stays on CPU. Metal performs ordering and weighted isotonic
/// block decisions; Float reconstruction preserves the synchronous coordinate precision.
public final class HierarchicalLayoutOperation: LayoutExecutionReporting {
    public var configuration: HierarchicalLayoutConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
    let transpose: Bool
    public init(backend: LayoutBackend, executor: LayoutExecutor = .shared,
                configuration: HierarchicalLayoutConfiguration = .init()) {
        self.backend = backend; self.executor = executor; self.configuration = configuration; transpose = false
    }
    init(backend: LayoutBackend, executor: LayoutExecutor, configuration: HierarchicalLayoutConfiguration, transpose: Bool) {
        self.backend = backend; self.executor = executor; self.configuration = configuration; self.transpose = transpose
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now, configuration = self.configuration
        try configuration.validate(); try Task.checkCancellation()
        let transaction = try LayoutTransaction(graph)
        let snapshot = try GraphCheckpoint(transaction.working).snapshot
        guard snapshot.edges.count == transaction.working.edges.count else {
            throw LayoutExecutionError.invalidInput("Hierarchy edge endpoints must belong to the graph.")
        }
        let result = try await executor.hierarchical(snapshot,
            configuration: configuration, transpose: transpose, backend: backend)
        for (node, bounds) in zip(transaction.working.nodes, result.bounds) { node.bounds = bounds }
        if configuration.routesEdges {
            for (edge, path) in zip(transaction.working.edges, result.paths) { edge.path = path }
        }
        try transaction.commit(to: graph)
        var metrics = result.metrics; metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics
    }
}

public final class SeriesParallelLayoutOperation: LayoutExecutionReporting {
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
    public init(backend: LayoutBackend, executor: LayoutExecutor = .shared) { self.backend = backend; self.executor = executor }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let operation = HierarchicalLayoutOperation(backend: backend, executor: executor, configuration: .init(), transpose: true)
        try await operation.applyLayoutAsync(graph); lastMetrics = operation.lastMetrics
    }
}

public extension LayoutBuilder {
    @discardableResult func useHierarchical(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout HierarchicalLayoutConfiguration) -> Void = { _ in }) -> Self {
        var configuration = HierarchicalLayoutConfiguration(); configure(&configuration)
        return useAsyncAlgorithm(HierarchicalLayoutOperation(backend: backend, executor: executor, configuration: configuration))
    }
    @discardableResult func useSeriesParallel(backend: LayoutBackend, executor: LayoutExecutor = .shared) -> Self {
        useAsyncAlgorithm(SeriesParallelLayoutOperation(backend: backend, executor: executor))
    }
    @discardableResult func useStandardHierarchical(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout HierarchicalLayoutConfiguration) -> Void = { _ in }) -> Self {
        useHierarchical(backend: backend, executor: executor, configure: configure).routeSelfLoops(backend: backend, executor: executor)
    }
}

struct HierarchicalResult: Sendable {
    var bounds: [Rect]
    var paths: [[Point]]
    var metrics: LayoutExecutionMetrics
}

extension LayoutExecutor {
    func hierarchical(_ snapshot: GeometrySnapshot, configuration: HierarchicalLayoutConfiguration,
                      transpose: Bool, backend: LayoutBackend) async throws -> HierarchicalResult {
        let start = ContinuousClock.now
        try Task.checkCancellation(); try configuration.validate(); try options.validate()
        let graph = snapshot.makeGraph()
        if transpose { for node in graph.nodes { let width = node.width; node.width = node.height; node.height = width } }
        var chosen = backend, reason: LayoutFallbackReason?, gpu: Double?, device: String?
        var metalWork = false
        if graph.nodes.isEmpty { chosen = .cpu; reason = .noWork }
        else if backend == .automatic {
            if graph.nodes.count < options.minimumNodeCount { chosen = .cpu; reason = .belowThreshold }
            else if !metalEnabled || !Self.isMetalAvailable { chosen = .cpu; reason = .metalUnavailable }
            else { chosen = .metal }
        }
        if chosen == .metal {
            do {
                let plan = try HierarchyPlacementPlan(graph, configuration: configuration)
                try plan.validateMetal(tolerance: options.maximumCoordinateError)
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                if metal == nil { metal = try MetalForceSolver() }
                let result = try await metal!.hierarchyAsync(plan, directed: false, retainBest: false)
                metalWork = true; gpu = result.gpuSeconds; device = metal!.deviceName
                try plan.apply(result, to: graph)
            } catch LayoutExecutionError.precisionLimit where backend == .automatic {
                chosen = .cpu; reason = .precisionLimit
            } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
                chosen = .cpu; reason = .metalUnavailable
            }
        }
        if chosen == .cpu {
            let algorithm = HierarchicalLayoutAlgorithm()
            algorithm.layerSeparation = configuration.layerSeparation; algorithm.nodeSeparation = configuration.nodeSeparation
            algorithm.maxNodesPerRank = configuration.maxNodesPerRank
            algorithm.routesEdges = configuration.routesEdges
            try algorithm.applyLayout(graph)
        }
        if transpose {
            for node in graph.nodes { node.bounds = Rect(x: node.y, y: node.x, width: node.height, height: node.width) }
            for edge in graph.edges { edge.path = edge.path.map { Point(x: $0.y, y: $0.x) } }
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).seconds
        var metrics = LayoutExecutionMetrics(requestedBackend: backend, backend: chosen, fallbackReason: reason,
                nodeCount: graph.nodes.count, iterations: graph.nodes.isEmpty ? 0 : 3, computeSeconds: elapsed,
                totalSeconds: elapsed, gpuSeconds: gpu, deviceName: device)
        metrics.cpuStages = chosen == .metal ? ["rank-construction", "virtual-edge-construction", "Double-geometry-reconstruction"] : ["hierarchy-layout"]
        metrics.metalStages = metalWork ? ["hierarchy-ordering", "weighted-isotonic-block-decisions"] : []
        return HierarchicalResult(bounds: graph.nodes.map(\.bounds), paths: graph.edges.map(\.path), metrics: metrics)
    }
}

struct HierarchyPlacementOutput: Sendable {
    var layers: [UInt32]
    /// The last position of each fitted block, indexed by pass and vertex.
    var blockEnds: [UInt32]
    /// Merge count after inserting each vertex, retaining PAV's binary sum association.
    var mergeCounts: [UInt32]
    var gpuSeconds: Double
}

/// CPU topology preparation only: no median ordering or PAV fitting takes place here.
struct HierarchyPlacementPlan: Sendable {
    var originalCount: Int
    var layers: [[Int]]
    var ranks: [Int]
    var widths: [Float]
    var heights: [Float]
    var incoming: [[Int]]
    var outgoing: [[Int]]
    var chains: [[Int]]
    /// Sign of each edge's rank change; nil for self-loops and edges outside the graph, which are not routed between ranks.
    var flows: [Int?]
    var nodeSeparation: Float
    var layerSeparation: Float
    var routesEdges: Bool
    init(_ graph: LayoutGraph, configuration: HierarchicalLayoutConfiguration) throws {
        let adjacency = Adjacency(graph)
        originalCount = adjacency.nodes.count; widths = adjacency.nodes.map(\.width)
        layers = adjacency.layers(maxWidth: configuration.maxNodesPerRank ?? .max)
        ranks = Array(repeating: 0, count: originalCount)
        for (rank, layer) in layers.enumerated() { for vertex in layer { ranks[vertex] = rank } }
        incoming = Array(repeating: [], count: originalCount); outgoing = incoming
        chains = Array(repeating: [], count: graph.edges.count); flows = Array(repeating: nil, count: graph.edges.count)
        for (index, edge) in graph.edges.enumerated() {
            try Task.checkCancellation()
            guard let source = adjacency.index[edge.source], let target = adjacency.index[edge.target], source != target else { continue }
            let delta = ranks[target] - ranks[source], span = abs(delta)
            flows[index] = delta.signum()
            if span > 1 && span - 1 <= 64 {
                for step in 1..<span {
                    let vertex = widths.count, rank = ranks[source] + step * (delta > 0 ? 1 : -1)
                    widths.append(8); ranks.append(rank); incoming.append([]); outgoing.append([])
                    layers[rank].append(vertex); chains[index].append(vertex)
                }
            }
            let path = [source] + chains[index] + [target]
            for (a, b) in zip(path, path.dropFirst()) where abs(ranks[a] - ranks[b]) == 1 {
                let low = ranks[a] < ranks[b] ? a : b, high = ranks[a] < ranks[b] ? b : a
                outgoing[low].append(high); incoming[high].append(low)
            }
        }
        let count = adjacency.nodes.count
        heights = layers.map { layer in layer.map { $0 < count ? adjacency.nodes[$0].height : 0 }.max() ?? 0 }
        nodeSeparation = configuration.nodeSeparation; layerSeparation = configuration.layerSeparation
        routesEdges = configuration.routesEdges
    }
    func validateMetal(tolerance: Float) throws {
        guard widths.count < 4_194_304,
              incoming.reduce(0, { $0 + $1.count }) < Int(UInt32.max),
              outgoing.reduce(0, { $0 + $1.count }) < Int(UInt32.max) else {
            throw LayoutExecutionError.invalidInput("Hierarchy exceeds Metal index capacity.")
        }
        let bound = widths.reduce(0, +) + Float(widths.count) * abs(nodeSeparation)
        // The kernel uses split Float arithmetic, not a single Float coordinate.
        // Bound accumulated error rather than rejecting wide ranks solely for the
        // high component's ULP. The same caller tolerance remains in force.
        let maximumDegree = incoming.indices.map { incoming[$0].count + outgoing[$0].count }.max() ?? 0
        guard maximumDegree < 16_777_216 else { throw LayoutExecutionError.invalidInput("Hierarchy degree exceeds precise Metal count capacity") }
        let errorBound = bound * Float(max(1, widths.count, maximumDegree)) * 1e-13
        guard bound.isFinite, errorBound <= tolerance,
              widths.allSatisfy(\.isFinite), nodeSeparation.isFinite else {
            throw LayoutExecutionError.precisionLimit
        }
    }
    func apply(_ output: HierarchyPlacementOutput, to graph: LayoutGraph) throws {
        guard output.layers.count == widths.count, output.blockEnds.count == widths.count * 3, output.mergeCounts.count == widths.count * 3,
              Set(output.layers).count == widths.count,
              output.layers.allSatisfy({ Int($0) < widths.count }) else {
            throw OrganicLayoutError.metalFailure("Invalid hierarchy permutation")
        }
        var ordered: [[Int]] = [], cursor = 0
        for (rank, layer) in layers.enumerated() {
            let next = output.layers[cursor..<(cursor + layer.count)].map(Int.init)
            guard next.allSatisfy({ ranks[$0] == rank }) else { throw OrganicLayoutError.metalFailure("Invalid hierarchy rank") }
            ordered.append(next); cursor += layer.count
        }
        var xs = Array(repeating: Float(0), count: widths.count)
        for layer in ordered {
            let total = layer.reduce(Float(0)) { $0 + widths[$1] } + Float(max(0, layer.count - 1)) * nodeSeparation
            var x = -total / 2
            for vertex in layer { xs[vertex] = x + widths[vertex] / 2; x += widths[vertex] + nodeSeparation }
        }
        // Reconstruct from GPU decisions. The KKT checks reject Float decisions
        // that would violate isotonic projection, allowing automatic CPU fallback.
        for pass in 0..<3 {
            for rank in (pass % 2 == 0 ? Array(ordered.indices) : Array(ordered.indices.reversed())) {
                try Task.checkCancellation()
                let layer = ordered[rank]
                var desired: [Float] = [], shifts: [Float] = [], distance: Float = 0
                for (position, vertex) in layer.enumerated() {
                    if position > 0 { distance += (widths[layer[position - 1]] + widths[vertex]) / 2 + nodeSeparation }
                    shifts.append(distance)
                    let neighbors = incoming[vertex] + outgoing[vertex]
                    desired.append((neighbors.isEmpty ? xs[vertex] : neighbors.reduce(Float(0)) { $0 + xs[$1] } / Float(neighbors.count)) - distance)
                }
                var blocks: [(start: Int, end: Int, sum: Float, weight: Float)] = []
                for position in layer.indices {
                    let weight: Float = layer[position] < originalCount ? 1.0 : 4.0
                    blocks.append((position, position, desired[position] * weight, weight))
                    let merges = Int(output.mergeCounts[pass * widths.count + layer[position]])
                    guard merges < blocks.count else { throw OrganicLayoutError.metalFailure("Invalid hierarchy merge history") }
                    for _ in 0..<merges {
                        let last = blocks.removeLast(), previous = blocks.removeLast()
                        blocks.append((previous.start, last.end, previous.sum + last.sum, previous.weight + last.weight))
                    }
                }
                var previous = -Float.infinity
                for block in blocks {
                    let position = block.start, end = block.end, mean = block.sum / block.weight
                    let previousAllowance = max(abs(mean), previous.isFinite ? abs(previous) : 0).ulp * 16
                    guard mean.isFinite, mean + previousAllowance >= previous else { throw LayoutExecutionError.precisionLimit }
                    var prefix: Float = 0, prefixWeight: Float = 0
                    for p in position...end {
                        guard output.blockEnds[pass * widths.count + layer[p]] == UInt32(end) else { throw OrganicLayoutError.metalFailure("Inconsistent hierarchy fitted block") }
                        let w: Float = layer[p] < originalCount ? 1.0 : 4.0
                        prefix += desired[p] * w; prefixWeight += w
                        // PAV's merged blocks use a binary merge summation. A tiny
                        // rounding allowance avoids rejecting the same optimum solely for
                        // different association; meaningful grouping differences still fail.
                        let allowance = max(abs(prefix), abs(mean * prefixWeight)).ulp * 16
                        guard p == end || prefix + allowance >= mean * prefixWeight else { throw LayoutExecutionError.precisionLimit }
                        xs[layer[p]] = mean + shifts[p]
                    }
                    previous = mean
                }
            }
        }
        let ys = offsets(heights, gap: layerSeparation)
        for i in 0..<originalCount { graph.nodes[i].center = Point(x: xs[i], y: ys[ranks[i]] + heights[ranks[i]] / 2) }
        guard routesEdges else { return }
        let routed: [[Point]?] = chains.indices.map { i in
            flows[i] == nil ? nil : chains[i].map { Point(x: xs[$0], y: ys[ranks[$0]] + heights[ranks[$0]] / 2) }
        }
        try routeLayeredEdges(graph, chains: routed, flows: flows)
    }
}
