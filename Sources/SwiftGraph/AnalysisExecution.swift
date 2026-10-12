import Foundation

public enum AnalysisKind: String, Sendable { case pageRank, clusters }
public struct PageRankConfiguration: Sendable {
    public var dampingFactor: Double = 0.85
    public var iterations: Int = 20
    /// Double-single GPU arithmetic keeps rank errors substantially below Float precision.
    public var maximumRankError: Double = 1e-10
    public var minimumMetalNodeCount: Int = 1_024
    public init() {}
    func validate() throws {
        guard dampingFactor.isFinite, (0...1).contains(dampingFactor), iterations >= 0,
              maximumRankError.isFinite, maximumRankError > 0, minimumMetalNodeCount >= 0 else {
            throw LayoutExecutionError.invalidInput("Invalid PageRank configuration.")
        }
    }
}
public struct ClusterAnalysisConfiguration: Sendable {
    /// The algorithm retains the reference's fixed 20 passes and seeded in-place update order.
    public var minimumMetalNodeCount: Int = 1_024
    public init() {}
    func validate() throws {
        guard minimumMetalNodeCount >= 0 else { throw LayoutExecutionError.invalidInput("Invalid cluster selection threshold.") }
    }
}
public final class AnalysisLayoutOperation: LayoutExecutionReporting {
    public let kind: AnalysisKind
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public var pageRank: PageRankConfiguration
    public var clusters: ClusterAnalysisConfiguration
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
    public init(_ kind: AnalysisKind, backend: LayoutBackend, executor: LayoutExecutor = .shared,
                pageRank: PageRankConfiguration = .init(), clusters: ClusterAnalysisConfiguration = .init()) {
        self.kind = kind; self.backend = backend; self.executor = executor; self.pageRank = pageRank; self.clusters = clusters
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now, pageRank = self.pageRank, clusters = self.clusters
        if kind == .pageRank { try pageRank.validate() } else { try clusters.validate() }
        try Task.checkCancellation()
        let checkpoint = try GraphCheckpoint(graph)
        let ranks = graph.nodes.map { $0.metadata[GraphMetadataKeys.pageRank] as? Double }
        let labels = graph.nodes.map { $0.metadata[GraphMetadataKeys.cluster] as? Int }
        let result = try await executor.analysis(checkpoint.snapshot, kind: kind, pageRank: pageRank, clusters: clusters, backend: backend)
        try Task.checkCancellation()
        guard checkpoint.matches(graph), graph.nodes.map({ $0.metadata[GraphMetadataKeys.pageRank] as? Double }) == ranks,
              graph.nodes.map({ $0.metadata[GraphMetadataKeys.cluster] as? Int }) == labels else { throw LayoutExecutionError.staleGraph }
        if let values = result.ranks {
            guard values.count == graph.nodes.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw OrganicLayoutError.metalFailure("Invalid PageRank output") }
            for i in graph.nodes.indices { graph.nodes[i].metadata[GraphMetadataKeys.pageRank] = values[i] }
        }
        if let values = result.labels {
            guard values.count == graph.nodes.count, values.allSatisfy({ $0 >= 0 && $0 < graph.nodes.count }) else { throw OrganicLayoutError.metalFailure("Invalid cluster labels") }
            for i in graph.nodes.indices { graph.nodes[i].metadata[GraphMetadataKeys.cluster] = values[i] }
        }
        var metrics = result.metrics; metrics.totalSeconds = start.duration(to: .now).seconds; lastMetrics = metrics
    }
}
public extension LayoutBuilder {
    @discardableResult func analyzePageRank(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout PageRankConfiguration) -> Void = { _ in }) -> Self {
        var configuration = PageRankConfiguration(); configure(&configuration)
        return useAsyncAlgorithm(AnalysisLayoutOperation(.pageRank, backend: backend, executor: executor, pageRank: configuration))
    }
    @discardableResult func analyzeClusters(backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout ClusterAnalysisConfiguration) -> Void = { _ in }) -> Self {
        var configuration = ClusterAnalysisConfiguration(); configure(&configuration)
        return useAsyncAlgorithm(AnalysisLayoutOperation(.clusters, backend: backend, executor: executor, clusters: configuration))
    }
}
struct AnalysisState: Sendable {
    var count: Int
    var incomingOffsets: [UInt32]
    var incoming: [UInt32]
    var degree: [UInt32]
    var neighborOffsets: [UInt32]
    var neighbors: [UInt32]
    init(_ snapshot: GeometrySnapshot) throws {
        count = snapshot.nodes.count
        guard snapshot.edges.count <= 8_388_608 else { throw LayoutExecutionError.invalidInput("Analysis adjacency exceeds the 64 MiB limit.") }
        var incoming = Array(repeating: [UInt32](), count: count), neighbors = incoming
        var degree = Array(repeating: UInt32(0), count: count)
        for edge in snapshot.edges where edge.source != edge.target {
            incoming[edge.target].append(UInt32(edge.source)); degree[edge.source] += 1
            neighbors[edge.source].append(UInt32(edge.target)); neighbors[edge.target].append(UInt32(edge.source))
        }
        // PageRank appends self-links after its ordinary adjacency, matching the CPU's summation order.
        for edge in snapshot.edges where edge.source == edge.target { incoming[edge.source].append(UInt32(edge.source)); degree[edge.source] += 1 }
        func flatten(_ values: [[UInt32]]) throws -> ([UInt32], [UInt32]) {
            var flat: [UInt32] = [], offsets: [UInt32] = [0]
            for row in values {
                guard flat.count + row.count <= 16_777_216 else { throw LayoutExecutionError.invalidInput("Analysis adjacency exceeds the 64 MiB limit.") }
                flat.append(contentsOf: row); offsets.append(UInt32(flat.count))
            }
            return (offsets, flat)
        }
        (incomingOffsets, self.incoming) = try flatten(incoming)
        (neighborOffsets, self.neighbors) = try flatten(neighbors)
        self.degree = degree
    }
    func pageRankErrorBound(iterations: Int) -> Double {
        let maximumIncoming = zip(incomingOffsets, incomingOffsets.dropFirst()).map { Int($1 - $0) }.max() ?? 0
        return Double(iterations) * Double(count + maximumIncoming) / Double(max(1, count)) * 64 * pow(Double(Float.ulpOfOne), 2)
    }
    func cpuPageRank(_ configuration: PageRankConfiguration) throws -> [Double] {
        guard count > 0 else { return [] }
        var ranks = Array(repeating: 1 / Double(count), count: count)
        for _ in 0..<configuration.iterations {
            try Task.checkCancellation()
            let dangling = (0..<count).filter { degree[$0] == 0 }.reduce(0.0) { $0 + ranks[$1] }
            ranks = (0..<count).map { i in
                let links = incoming[Int(incomingOffsets[i])..<Int(incomingOffsets[i + 1])].reduce(0.0) { $0 + ranks[Int($1)] / Double(degree[Int($1)]) }
                return (1 - configuration.dampingFactor) / Double(count) + configuration.dampingFactor * (links + dangling / Double(count))
            }
        }
        return ranks
    }
    func cpuClusters() throws -> [Int] {
        var labels = Array(0..<count), order = labels, random = SeededRandom()
        for _ in 0..<20 {
            try Task.checkCancellation()
            shuffle(&order, random: &random)
            var changed = false
            for i in order {
                var counts: [Int: Int] = [:], labelOrder: [Int] = []
                for j in neighbors[Int(neighborOffsets[i])..<Int(neighborOffsets[i + 1])] {
                    if counts[labels[Int(j)]] == nil { labelOrder.append(labels[Int(j)]) }
                    counts[labels[Int(j)], default: 0] += 1
                }
                var best = labels[i], bestCount = counts[best, default: 0]
                for label in labelOrder where counts[label]! > bestCount { best = label; bestCount = counts[label]! }
                if labels[i] != best { changed = true; labels[i] = best }
            }
            if !changed { break }
        }
        return labels
    }
}
func shuffle(_ order: inout [Int], random: inout SeededRandom) {
    if order.count > 1 { for i in stride(from: order.count - 1, through: 1, by: -1) { order.swapAt(i, Int(random.next() * Double(i + 1))) } }
}
struct AnalysisResult: Sendable {
    var ranks: [Double]?
    var labels: [Int]?
    var metrics: LayoutExecutionMetrics
}
extension LayoutExecutor {
    func analysis(_ snapshot: GeometrySnapshot, kind: AnalysisKind, pageRank: PageRankConfiguration,
                  clusters: ClusterAnalysisConfiguration, backend: LayoutBackend) async throws -> AnalysisResult {
        let start = ContinuousClock.now
        try options.validate(); try Task.checkCancellation()
        let state = try AnalysisState(snapshot)
        var actual = backend, reason: LayoutFallbackReason?, ranks: [Double]?, labels: [Int]?, gpu: Double?, device: String?
        var refinedRankOrdering = false
        let iterations = kind == .pageRank ? pageRank.iterations : 20
        if state.count == 0 || iterations == 0 || (kind == .clusters && state.neighbors.isEmpty) { actual = .cpu; reason = .noWork }
        else if backend == .automatic {
            let minimum = kind == .pageRank ? pageRank.minimumMetalNodeCount : clusters.minimumMetalNodeCount
            if state.count < minimum { actual = .cpu; reason = .belowThreshold }
            else if !metalEnabled || !Self.isMetalAvailable { actual = .cpu; reason = .metalUnavailable }
            else { actual = .metal }
        }
        if actual == .metal {
            do {
                guard metalEnabled else { throw OrganicLayoutError.metalUnavailable }
                if metal == nil { metal = try MetalForceSolver() }
                if kind == .pageRank {
                    let result = try await metal!.pageRankAsync(state, configuration: pageRank, batchSize: options.iterationsPerBatch)
                    ranks = result.ranks; gpu = result.gpuSeconds
                    let sorted = result.ranks.sorted(), uncertainty = state.pageRankErrorBound(iterations: pageRank.iterations) * 2
                    if zip(sorted, sorted.dropFirst()).contains(where: { $1 - $0 <= uncertainty }) {
                        // Numerical overlap can change hub selection. Recompute exact Double ranks
                        // together to preserve order and total mass; GPU iterations supplied the
                        // conservative ambiguity decision, so this cost is disclosed in metrics.
                        let refinement = Task.detached { try state.cpuPageRank(pageRank) }
                        ranks = try await withTaskCancellationHandler { try await refinement.value } onCancel: { refinement.cancel() }
                        refinedRankOrdering = true
                    }
                } else {
                    let result = try await metal!.clustersAsync(state)
                    labels = result.labels; gpu = result.gpuSeconds
                }
                device = metal!.deviceName
            } catch LayoutExecutionError.precisionLimit where backend == .automatic { actual = .cpu; reason = .precisionLimit }
            catch OrganicLayoutError.metalUnavailable where backend == .automatic { actual = .cpu; reason = .metalUnavailable }
        }
        if actual == .cpu {
            if kind == .pageRank { ranks = try state.cpuPageRank(pageRank) } else { labels = try state.cpuClusters() }
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).seconds
        return AnalysisResult(ranks: ranks, labels: labels, metrics: LayoutExecutionMetrics(requestedBackend: backend, backend: actual, fallbackReason: reason, nodeCount: state.count, iterations: iterations, computeSeconds: elapsed, totalSeconds: elapsed, gpuSeconds: gpu, deviceName: device,
            cpuStages: actual == .cpu ? [kind == .pageRank ? "PageRank iterations" : "seeded in-place label propagation"] : ["adjacency preparation", kind == .pageRank ? "rank readback" : "seeded shuffle and convergence control"] + (refinedRankOrdering ? ["exact Double PageRank refinement for ambiguous rank ordering"] : []),
            metalStages: actual == .metal ? [kind == .pageRank ? "double-single PageRank dangling reduction and incoming-link iterations" : "ordered in-place cluster voting and label updates"] : []))
    }
}
