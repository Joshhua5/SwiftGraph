import Foundation

/// The CPU algorithms retain their ordered searches, port rules and hierarchy behavior. Metal
/// accelerates geometry stages; it does not replace them with a different routing algorithm.
public enum RoutingKind: String, CaseIterable, Sendable {
    case polyline, channel, bus, octilinear, bsp, orthogonalGrouped, parallelEdges
    case edgeSeparation, selfLoops, curveFitting, endpointClipping, labelPlacement, labelLayout, givenCoordinates
}
public struct RoutingConfiguration: Sendable {
    public var kind: RoutingKind
    public var padding: Double = 10
    public var edgeSpacing: Double = 10
    public var gridSize: Int = 20
    public var channelBendPenalty: Int {
        get { Int(exactly: bendPenalty) ?? 0 }
        set { bendPenalty = Double(newValue) }
    }
    public var congestionPenalty: Int = 2
    public var busSpacing: Double = 20
    public var margin: Double = 20
    public var bendPenalty: Double = 40
    public var bundleSpacing: Double = 10
    public var obstacleMargin: Double = 10
    public var parallelEdgeSpacing: Double {
        get { edgeSpacing }
        set { edgeSpacing = newValue }
    }
    public var spacing: Double {
        get { edgeSpacing }
        set { edgeSpacing = newValue }
    }
    public var loopSize: Double = 16
    public var curveIterations: Int = 2
    public var labelIterations: Int = 200
    public var iterations: Int {
        get { kind == .curveFitting ? curveIterations : labelIterations }
        set { if kind == .curveFitting { curveIterations = newValue } else { labelIterations = newValue } }
    }
    /// Automatic selection uses edge count; routing has no organic iteration threshold.
    public var minimumMetalEdgeCount: Int = 256
    public init(_ kind: RoutingKind) {
        self.kind = kind
        if kind == .orthogonalGrouped { bendPenalty = 100 }
        if kind == .channel { bendPenalty = 2 }
        if kind == .parallelEdges { edgeSpacing = 20 }
    }
    func validate() throws {
        let values: [Double]
        switch kind {
        case .polyline, .givenCoordinates: values = [padding, edgeSpacing]
        case .channel:
            guard gridSize > 0, Int(exactly: bendPenalty) != nil else {
                throw LayoutExecutionError.invalidInput("Channel grid size must be positive and bend penalty integral.")
            }
            values = []
        case .bus: values = [busSpacing]
        case .bsp: values = [margin, bendPenalty, edgeSpacing]
        case .orthogonalGrouped: values = [bundleSpacing, obstacleMargin, bendPenalty]
        case .parallelEdges, .edgeSeparation: values = [edgeSpacing]
        case .selfLoops: values = [loopSize]
        case .curveFitting:
            guard curveIterations >= 0 else { throw LayoutExecutionError.invalidInput("Curve iterations must be nonnegative.") }
            values = []
        case .labelLayout:
            guard labelIterations >= 0 else { throw LayoutExecutionError.invalidInput("Label iterations must be nonnegative.") }
            values = []
        case .octilinear, .endpointClipping, .labelPlacement: values = []
        }
        guard values.allSatisfy(\.isFinite), minimumMetalEdgeCount >= 0 else {
            throw LayoutExecutionError.invalidInput("Routing parameters must be finite.")
        }
    }
}
public final class RoutingLayoutOperation: AsyncLayoutAlgorithm, LayoutExecutionReporting {
    public var configuration: RoutingConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public private(set) var unroutableEdgeIndices: [Int] = []
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
    /// Evaluated on the graph's owner before suspension, never transferred to a compute queue.
    public var labelProvider: (LayoutEdge) -> String? = LabelPlacementAlgorithm().labelProvider
    public init(_ kind: RoutingKind, backend: LayoutBackend, executor: LayoutExecutor = .shared,
                configure: (inout RoutingConfiguration) -> Void = { _ in }) {
        var configuration = RoutingConfiguration(kind); configure(&configuration)
        self.configuration = configuration; self.backend = backend; self.executor = executor
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil; unroutableEdgeIndices = []
        let start = ContinuousClock.now, configuration = self.configuration
        try Task.checkCancellation(); try configuration.validate()
        let readsLabelText = configuration.kind == .labelPlacement
        let labelTexts = readsLabelText ? graph.edges.map(labelProvider) : Array<String?>(repeating: nil, count: graph.edges.count)
        let checkpoint = try RoutingCheckpoint(graph, labels: labelTexts)
        if configuration.kind == .bsp {
            guard checkpoint.snapshot.hierarchy.allSatisfy({ [ $0.bounds.x, $0.bounds.y, $0.bounds.right, $0.bounds.bottom ].allSatisfy { abs($0) < Double(Int64.max) * 1e-4 / 8 } }) else {
                throw LayoutExecutionError.invalidInput("BSP coordinates exceed quantized indexing range.")
            }
        }
        if configuration.kind == .orthogonalGrouped || configuration.kind == .edgeSeparation {
            let coordinates = checkpoint.related.flatMap { [$0.x, $0.y, $0.bounds.right, $0.bounds.bottom] }
                + graph.edges.flatMap { $0.path.flatMap { [$0.x, $0.y] } }
            guard coordinates.allSatisfy({ abs($0) < Double(Int.max / 8) }) else {
                throw LayoutExecutionError.invalidInput("Routing coordinates exceed integer indexing range.")
            }
        }
        if configuration.kind == .channel, !graph.nodes.isEmpty {
            let origin = Point(x: graph.nodes.map(\.x).min()! - 50, y: graph.nodes.map(\.y).min()! - 50)
            let spans = graph.nodes.flatMap { [$0.x - origin.x, $0.bounds.right - origin.x, $0.y - origin.y, $0.bounds.bottom - origin.y] }
            guard spans.allSatisfy({ $0.isFinite && abs($0) < Double(Int.max / 64) }),
                  configuration.gridSize < Int.max / 1_024,
                  abs(configuration.bendPenalty) < Double(Int.max / 64),
                  configuration.congestionPenalty < Int.max / max(64, graph.edges.count * 8) else {
                throw LayoutExecutionError.invalidInput("Channel local grid or costs exceed integer indexing range.")
            }
        }
        let result = try await executor.routing(checkpoint.snapshot, configuration: configuration, backend: backend)
        try Task.checkCancellation()
        guard checkpoint.matches(graph, labels: readsLabelText ? graph.edges.map(labelProvider) : Array<String?>(repeating: nil, count: graph.edges.count)) else { throw LayoutExecutionError.staleGraph }
        guard result.bounds.count == checkpoint.related.count else { throw LayoutExecutionError.invalidInput("Routing hierarchy result size changed.") }
        for i in checkpoint.related.indices { checkpoint.related[i].bounds = result.bounds[i] }
        graph.root.bounds = result.rootBounds
        for i in graph.edges.indices { graph.edges[i].path = result.paths[i]; graph.edges[i].labelBounds = result.labels[i] }
        var metrics = result.metrics; metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = metrics; unroutableEdgeIndices = result.unroutable
    }
}
public extension LayoutBuilder {
    @discardableResult func routeEdges(_ kind: RoutingKind, backend: LayoutBackend, executor: LayoutExecutor = .shared,
        configure: (inout RoutingConfiguration) -> Void = { _ in }) -> Self {
        useAsyncAlgorithm(RoutingLayoutOperation(kind, backend: backend, executor: executor, configure: configure))
    }
}

struct RoutingSnapshot: Sendable {
    var geometry: GeometrySnapshot
    struct Node: Sendable {
        var id: String; var bounds: Rect; var isGroup: Bool
        var parent: Int?; var children: [Int]
    }
    /// Related hierarchy nodes are distinct from obstacle/routing graph membership.
    /// Index zero is the local graph's root; external ancestor roots remain separate nodes.
    var hierarchy: [Node]
    var members: [Int]
    struct Edge: Sendable, Equatable {
        var path: [Point]; var labelBounds: Rect; var label: String?
        var sourcePort: PortConstraint; var targetPort: PortConstraint
        var sourceCandidates: [PortConstraint]; var targetCandidates: [PortConstraint]
    }
    var edges: [Edge]
    func makeGraph() -> (LayoutGraph, [LayoutNode]) {
        let graph = LayoutGraph()
        let nodes = hierarchy.enumerated().map { i, state in
            let node = i == 0 ? graph.root : LayoutNode(id: state.id, width: state.bounds.width, height: state.bounds.height)
            node.bounds = state.bounds; node.isGroup = state.isGroup
            return node
        }
        for i in nodes.indices {
            nodes[i].parent = hierarchy[i].parent.map { nodes[$0] }
            nodes[i].children = hierarchy[i].children.map { nodes[$0] }
        }
        graph.nodes = members.map { nodes[$0] }
        for (i, pair) in geometry.edges.enumerated() {
            let edge = LayoutEdge(source: graph.nodes[pair.source], target: graph.nodes[pair.target], data: edges[i].label)
            let state = edges[i]
            edge.path = state.path; edge.labelBounds = state.labelBounds
            edge.sourcePort = state.sourcePort; edge.targetPort = state.targetPort
            edge.sourcePortCandidates = state.sourceCandidates; edge.targetPortCandidates = state.targetCandidates
            graph.addEdge(edge)
        }
        return (graph, nodes)
    }
}
struct RoutingCheckpoint {
    let graph: GraphCheckpoint
    let snapshot: RoutingSnapshot
    let related: [LayoutNode]
    private let relatedStates: [NodeState]
    private struct NodeState: Equatable {
        var bounds: Rect; var isGroup: Bool; var parent: LayoutNode?; var children: [LayoutNode]
        var frame: GroupFrameOptions?; var content: Rect?; var header: Rect?
        init(_ node: LayoutNode) {
            bounds = node.bounds; isGroup = node.isGroup; parent = node.parent; children = node.children
            frame = node.groupFrame; content = node.groupContentBounds; header = node.groupHeaderBounds
        }
    }
    init(_ input: LayoutGraph, labels: [String?]) throws {
        graph = try GraphCheckpoint(input)
        guard graph.snapshot.edges.count == input.edges.count else { throw LayoutExecutionError.invalidInput("Every routed edge must belong to the graph.") }
        // Temporary component/group graphs deliberately retain original parent references.
        // Snapshot those relationships without widening graph.nodes or its obstacle membership.
        var nodes = [input.root], seen: Set<LayoutNode> = [input.root]
        var pending = input.nodes + input.root.children
        if let parent = input.root.parent { pending.append(parent) }
        while let node = pending.popLast() {
            guard seen.insert(node).inserted else { continue }
            nodes.append(node); pending.append(contentsOf: node.children)
            if let parent = node.parent { pending.append(parent) }
        }
        guard nodes.count < Int(UInt32.max), nodes.allSatisfy({ node in
            [node.x, node.y, node.width, node.height, node.bounds.right, node.bounds.bottom].allSatisfy(\.isFinite) && node.width >= 0 && node.height >= 0
        }) else { throw LayoutExecutionError.invalidInput("Finite routing hierarchy is required.") }
        // Child cycles would form unreleasable strong cycles in the detached clone.
        var visited = Set<LayoutNode>(), active = Set<LayoutNode>()
        for seed in nodes where !visited.contains(seed) {
            var stack = [(seed, false)]
            while let (node, post) = stack.popLast() {
                if post { active.remove(node); visited.insert(node); continue }
                guard !active.contains(node) else { throw LayoutExecutionError.invalidInput("Routing child hierarchy must be acyclic.") }
                if visited.contains(node) { continue }
                active.insert(node); stack.append((node, true))
                for child in node.children.reversed() { stack.append((child, false)) }
            }
        }
        for node in nodes {
            var ancestors = Set<LayoutNode>(), current: LayoutNode? = node
            while let member = current {
                guard ancestors.insert(member).inserted else { throw LayoutExecutionError.invalidInput("Routing parent hierarchy must be acyclic.") }
                current = member.parent
            }
        }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, $0.offset) })
        let edges = input.edges.enumerated().map { i, edge in Self.state(edge, label: labels[i]) }
        guard edges.allSatisfy({ $0.path.allSatisfy { $0.x.isFinite && $0.y.isFinite } && [$0.labelBounds.x, $0.labelBounds.y, $0.labelBounds.width, $0.labelBounds.height].allSatisfy(\.isFinite) }) else {
            throw LayoutExecutionError.invalidInput("Finite route and label geometry is required.")
        }
        related = nodes; relatedStates = nodes.map(NodeState.init)
        snapshot = RoutingSnapshot(geometry: graph.snapshot,
            hierarchy: nodes.map { .init(id: $0.id, bounds: $0.bounds, isGroup: $0.isGroup, parent: $0.parent.flatMap { index[$0] }, children: $0.children.map { index[$0]! }) },
            members: input.nodes.map { index[$0]! }, edges: edges)
    }
    private static func state(_ edge: LayoutEdge, label: String?) -> RoutingSnapshot.Edge {
        .init(path: edge.path, labelBounds: edge.labelBounds, label: label, sourcePort: edge.sourcePort, targetPort: edge.targetPort, sourceCandidates: edge.sourcePortCandidates, targetCandidates: edge.targetPortCandidates)
    }
    func matches(_ input: LayoutGraph, labels: [String?]) -> Bool {
        graph.matches(input) && related.map(NodeState.init) == relatedStates && input.edges.enumerated().map { Self.state($0.element, label: labels[$0.offset]) } == snapshot.edges
    }
}
struct RoutingResult: Sendable {
    var bounds: [Rect]; var rootBounds: Rect; var paths: [[Point]]; var labels: [Rect]; var unroutable: [Int]
    var metrics: LayoutExecutionMetrics
}
final class RoutingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { if isCancelled { throw CancellationError() } }
}
/// A serial queue owns all routing compute resources. Awaiting callers transfer only values;
/// synchronous command draining happens on this dedicated queue, never a cooperative executor.
final class RoutingComputeWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SwiftGraph.routing.compute")
    private var solver: MetalForceSolver?
    private let lock = NSLock()
    private var statistics = LayoutExecutorStatistics(pipelineBuilds: 0, bufferAllocations: 0, bufferReuses: 0, submittedBatches: 0, completedBatches: 0, cachedBufferBytes: 0)
    func statisticsSnapshot() -> LayoutExecutorStatistics { lock.lock(); defer { lock.unlock() }; return statistics }
    private func updateStatistics() {
        guard let solver else { return }
        let value = LayoutExecutorStatistics(pipelineBuilds: solver.pipelineBuilds, bufferAllocations: solver.bufferAllocations, bufferReuses: solver.bufferReuses, submittedBatches: solver.submittedBatches, completedBatches: solver.completedBatches, cachedBufferBytes: solver.cachedBufferBytes)
        lock.lock(); statistics = value; lock.unlock()
    }
    func releaseCachedBuffers() async {
        await withCheckedContinuation { continuation in
            queue.async { self.solver?.releaseCachedBuffers(); self.updateStatistics(); continuation.resume() }
        }
    }
    func run(_ snapshot: RoutingSnapshot, configuration: RoutingConfiguration, backend: LayoutBackend, enabled: Bool, tolerance: Double) async throws -> RoutingResult {
        let cancellation = RoutingCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let result = try RoutingCompute.$cancellation.withValue(cancellation) {
                            try routingTransaction(snapshot, configuration: configuration, backend: backend, enabled: enabled, tolerance: tolerance) {
                                if self.solver == nil { self.solver = try MetalForceSolver() }
                                self.updateStatistics()
                                return RoutingCompute(solver: self.solver!, tolerance: tolerance, statisticsChanged: self.updateStatistics)
                            }
                        }
                        self.updateStatistics(); try cancellation.check(); continuation.resume(returning: result)
                    } catch { self.updateStatistics(); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}
extension LayoutExecutor {
    func routing(_ snapshot: RoutingSnapshot, configuration: RoutingConfiguration, backend: LayoutBackend) async throws -> RoutingResult {
        try configuration.validate(); try options.validate(); try Task.checkCancellation()
        if routingWorker == nil { routingWorker = RoutingComputeWorker() }
        return try await routingWorker!.run(snapshot, configuration: configuration, backend: backend, enabled: metalEnabled, tolerance: options.maximumCoordinateError)
    }
}
private func routingTransaction(_ snapshot: RoutingSnapshot, configuration: RoutingConfiguration, backend: LayoutBackend, enabled: Bool, tolerance: Double, makeCompute: () throws -> RoutingCompute) throws -> RoutingResult {
    let start = ContinuousClock.now
    var actual = backend, reason: LayoutFallbackReason?
    if snapshot.geometry.edges.isEmpty { actual = .cpu; reason = .noWork }
    else if backend == .automatic {
        if snapshot.edges.count < configuration.minimumMetalEdgeCount { actual = .cpu; reason = .belowThreshold }
        else if !enabled || !LayoutExecutor.isMetalAvailable { actual = .cpu; reason = .metalUnavailable }
        else { actual = .metal }
    }
    func run(_ compute: RoutingCompute?) throws -> RoutingResult {
        if backend == .automatic { compute?.minimumPairs = RoutingCompute.automaticPairs; compute?.minimumElements = RoutingCompute.automaticElements }
        let (graph, relatedNodes) = snapshot.makeGraph()
        let initialSubmissions = compute?.solver.submittedBatches ?? 0
        var unroutable: [LayoutEdge] = []
        RoutingCompute.$current.withValue(compute) {
            switch configuration.kind {
            case .polyline:
                let r = PolylineEdgeRouter(); r.padding = configuration.padding; r.edgeSpacing = configuration.edgeSpacing; r.routeEdges(graph); unroutable = r.unroutableEdges
            case .channel:
                let r = ChannelEdgeRouter(); r.gridSize = configuration.gridSize; r.bendPenalty = configuration.channelBendPenalty; r.congestionPenalty = configuration.congestionPenalty; r.routeEdges(graph); unroutable = r.unroutableEdges
            case .bus:
                let r = BusEdgeRouter(); r.busSpacing = configuration.busSpacing; r.routeEdges(graph)
            case .octilinear: OctilinearEdgeRouter().routeEdges(graph)
            case .bsp:
                let r = BspEdgeRouter(); r.margin = configuration.margin; r.bendPenalty = configuration.bendPenalty; r.edgeSpacing = configuration.edgeSpacing; r.routeEdges(graph); unroutable = r.unroutableEdges
            case .orthogonalGrouped:
                let r = OrthogonalGroupedEdgeRouter(); r.bundleSpacing = configuration.bundleSpacing; r.obstacleMargin = configuration.obstacleMargin; r.bendPenalty = configuration.bendPenalty; r.routeEdges(graph); unroutable = r.unroutableEdges
            case .parallelEdges:
                let r = ParallelEdgeRouter(); r.edgeSpacing = configuration.parallelEdgeSpacing; r.routeEdges(graph)
            case .edgeSeparation:
                let r = EdgeSeparator(); r.spacing = configuration.edgeSpacing; r.routeEdges(graph)
            case .selfLoops:
                let r = SelfLoopRouter(); r.loopSize = configuration.loopSize; r.routeEdges(graph); unroutable = r.unroutableEdges
            case .curveFitting:
                let r = CurveFittingEdgeRouter(); r.iterations = configuration.curveIterations; r.routeEdges(graph)
            case .endpointClipping: EdgeEndpointClipper.clipToNodeBounds(graph)
            case .labelPlacement: LabelPlacementAlgorithm().applyLabelPlacement(graph)
            case .labelLayout:
                let r = LabelLayoutAlgorithm(); r.iterations = configuration.labelIterations; r.applyLabelLayout(graph)
            case .givenCoordinates:
                let r = PolylineEdgeRouter(); r.padding = configuration.padding; r.edgeSpacing = configuration.edgeSpacing; r.routeEdges(graph); unroutable = r.unroutableEdges
            }
        }
        try RoutingCompute.cancellation?.check()
        if let failure = compute?.failure { throw failure }
        guard relatedNodes.allSatisfy({ [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width >= 0 && $0.height >= 0 }),
              graph.edges.allSatisfy({ $0.path.allSatisfy { $0.x.isFinite && $0.y.isFinite } && [$0.labelBounds.x, $0.labelBounds.y, $0.labelBounds.width, $0.labelBounds.height].allSatisfy(\.isFinite) }) else {
            throw LayoutExecutionError.invalidInput("Routing produced non-finite geometry.")
        }
        let submitted = (compute?.solver.submittedBatches ?? 0) - initialSubmissions
        let elapsed = start.duration(to: .now).seconds
        return RoutingResult(bounds: relatedNodes.map(\.bounds), rootBounds: graph.root.bounds, paths: graph.edges.map(\.path), labels: graph.edges.map(\.labelBounds), unroutable: unroutable.compactMap { graph.edges.firstIndex(of: $0) }, metrics: LayoutExecutionMetrics(requestedBackend: backend, backend: submitted == 0 ? .cpu : actual, fallbackReason: submitted == 0 && actual == .metal ? .noWork : reason, nodeCount: graph.nodes.count, iterations: configuration.kind == .labelLayout ? configuration.labelIterations : configuration.kind == .curveFitting ? min(5, configuration.curveIterations) : 1, computeSeconds: elapsed, totalSeconds: elapsed, gpuSeconds: submitted == 0 ? nil : compute?.gpuSeconds, deviceName: submitted == 0 ? nil : compute?.solver.deviceName, cpuStages: (actual == .cpu ? ["CPU \(configuration.kind.rawValue) routing and finishing"] : routingCPUStages(configuration.kind)) + (compute?.fallbacks ?? []), metalStages: submitted == 0 ? [] : compute?.stages ?? []))
    }
    if actual != .metal { return try run(nil) }
    do {
        guard enabled else { throw OrganicLayoutError.metalUnavailable }
        return try run(makeCompute())
    } catch LayoutExecutionError.precisionLimit where backend == .automatic {
        actual = .cpu; reason = .precisionLimit; return try run(nil)
    } catch OrganicLayoutError.metalUnavailable where backend == .automatic {
        actual = .cpu; reason = .metalUnavailable; return try run(nil)
    }
}

private func routingCPUStages(_ kind: RoutingKind) -> [String] {
    switch kind {
    case .polyline, .givenCoordinates: ["visibility vertices and ordered shortest-path search", "exact Double obstacle predicates and safe lane assignment"]
    case .channel: ["port selection, ordered A* search and congestion updates"]
    case .bsp: ["BSP hierarchy and ordered visibility search", "exact Double segment predicates and safe lane assignment"]
    case .orthogonalGrouped: ["hierarchy channels, ordered A* search, node nudge ordering and shared lanes", "exact Double blockers and endpoint clipping reconstruction"]
    case .selfLoops: ["corner generation, ordered corner ranking and exact Double clearance/crossings"]
    case .edgeSeparation: ["shared-line grouping, lane ordering and shifted-line intersections", "exact Double no-new-obstacle predicate"]
    case .curveFitting: ["subdivision iteration scheduling and exact endpoint preservation"]
    case .endpointClipping: ["exact containment, boundary intersection and path compaction"]
    case .labelPlacement: ["label text sizing, midpoint placement, candidate ranking and exact collision refinement"]
    case .labelLayout: ["seeded annealing, exact energy accumulation and candidate ranking"]
    case .parallelEdges: ["edge grouping, lane ordering and exact endpoint preservation"]
    case .bus: ["hub selection, bus axis selection and edge orientation"]
    case .octilinear: ["near-endpoint bend suppression and exact endpoint preservation"]
    }
}
