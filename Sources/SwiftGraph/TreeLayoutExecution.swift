import Foundation

public enum TreeLayoutStyle: String, CaseIterable, Sendable { case tree, balloon, orgChart, treeMap }
public struct TreeLayoutConfiguration: Sendable {
    public var nodeSeparation: Double = 50
    public var levelSeparation: Double = 50
    public var minRadius: Double = 50
    public var layerDistance: Double = 80
    public var siblingDistance: Double = 40
    public var padding: Double = 5
    public init() {}
    func validate(_ style: TreeLayoutStyle) throws {
        let values: [Double]
        switch style {
        case .tree: values = [nodeSeparation, levelSeparation]
        case .balloon: values = [minRadius]
        case .orgChart: values = [layerDistance, siblingDistance]
        case .treeMap: values = [padding]
        }
        guard values.allSatisfy(\.isFinite) else { throw LayoutExecutionError.invalidInput("Tree layout parameters must be finite.") }
    }
    func algorithm(_ style: TreeLayoutStyle) -> any LayoutAlgorithm {
        switch style {
        case .tree: let a = TreeLayoutAlgorithm(); a.nodeSeparation = nodeSeparation; a.levelSeparation = levelSeparation; return a
        case .balloon: let a = BalloonLayoutAlgorithm(); a.minRadius = minRadius; return a
        case .orgChart: let a = OrgChartLayoutAlgorithm(); a.layerDistance = layerDistance; a.siblingDistance = siblingDistance; return a
        case .treeMap: let a = TreeMapLayoutAlgorithm(); a.padding = padding; return a
        }
    }
}
public final class TreeLayoutOperation: LayoutExecutionReporting {
    public let style: TreeLayoutStyle
    public var configuration: TreeLayoutConfiguration
    public let backend: LayoutBackend
    public let executor: LayoutExecutor
    public private(set) var lastMetrics: LayoutExecutionMetrics?
    public var lastExecutionMetrics: [LayoutExecutionMetrics] { lastMetrics.map { [$0] } ?? [] }
    public init(style: TreeLayoutStyle, backend: LayoutBackend, executor: LayoutExecutor = .shared,
                configuration: TreeLayoutConfiguration = .init()) {
        self.style = style; self.backend = backend; self.executor = executor; self.configuration = configuration
    }
    public func applyLayoutAsync(_ graph: LayoutGraph) async throws {
        lastMetrics = nil
        let start = ContinuousClock.now, configuration = self.configuration
        try Task.checkCancellation(); try configuration.validate(style)
        let assistantInput = graph.nodes.map { ($0.data as? String)?.lowercased() == "assistant" }
        let transaction = try LayoutTransaction(graph)
        let computeStart = ContinuousClock.now
        let plan = try treePlacementPlan(transaction.working, style: style, configuration: configuration)
        var result = try await executor.placement(plan.state, backend: backend)
        if let bounds = result.bounds {
            for (node, bound) in zip(plan.targets, bounds) { node.bounds = bound }
            if style != .treeMap { straightEdges(transaction.working) }
            result.metrics.metalStages = [style == .treeMap ? "subtree weights and rectangle partition" : "ordered tree placement"]
            result.metrics.cpuStages = [style == .treeMap ? "snapshot, forest traversal and orientation precision analysis" : "snapshot and forest traversal"]
            if style != .treeMap { result.metrics.cpuStages.append("edge routing") }
        } else {
            try configuration.algorithm(style).applyLayout(transaction.working)
            result.metrics.cpuStages = ["tree placement"]
            if style != .treeMap { result.metrics.cpuStages.append("edge routing") }
        }
        result.metrics.computeSeconds = computeStart.duration(to: .now).seconds
        if style == .orgChart && assistantInput != graph.nodes.map({ ($0.data as? String)?.lowercased() == "assistant" }) {
            throw LayoutExecutionError.staleGraph
        }
        try transaction.commit(to: graph)
        result.metrics.totalSeconds = start.duration(to: .now).seconds
        lastMetrics = result.metrics
    }
}
/// Node references are retained only on the caller and never passed to the executor.
struct TreePlacementPlan {
    var targets: [LayoutNode]
    var state: MetalPlacementState
}
func treePlacementPlan(_ graph: LayoutGraph, style: TreeLayoutStyle, configuration c: TreeLayoutConfiguration) throws -> TreePlacementPlan {
    var targets = graph.nodes, ordered: [Int] = [], lists = Array(repeating: [Int](), count: targets.count)
    var records = Array(repeating: SIMD4<Int32>(0, -1, 0, 0), count: targets.count)
    var flags = targets.map { UInt32(($0.isGroup ? 1 : 0) | (($0.data as? String)?.lowercased() == "assistant" ? 2 : 0)) }
    let index = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($0.element, $0.offset) })
    var mode: UInt32 = 0, scalars: [Double]
    if style == .treeMap {
        mode = 3; scalars = [c.padding]
        var children: [LayoutNode: [LayoutNode]] = [:]
        if graph.root.children.count == graph.nodes.count && !graph.edges.isEmpty {
            let a = Adjacency(graph), f = Forest(a)
            children[graph.root] = f.roots.map { a.nodes[$0] }
            for i in a.nodes.indices { children[a.nodes[i]] = f.children[i].map { a.nodes[$0] } }
        }
        var indices = index, seen = Set<LayoutNode>(), stack = [graph.root]
        while let node = stack.popLast() {
            try Task.checkCancellation()
            guard seen.insert(node).inserted else { continue }
            if indices[node] == nil {
                indices[node] = targets.count; targets.append(node); lists.append([]); records.append(SIMD4(0, -1, 0, 0)); flags.append(node.isGroup ? 1 : 0)
            }
            let list = (children[node] ?? node.children).filter { !seen.contains($0) }
            children[node] = list; ordered.append(indices[node]!); stack.append(contentsOf: list.reversed())
        }
        for node in seen { lists[indices[node]!] = (children[node] ?? []).compactMap { indices[$0] } }
        if let root = indices[graph.root] { records[root].z = 1 }
    } else {
        let a = Adjacency(graph, excludingGroups: style == .balloon)
        let f = Forest(a, undirected: style == .balloon, degreeRoots: style == .balloon)
        let global = a.nodes.map { index[$0]! }
        for i in a.nodes.indices {
            lists[global[i]] = f.children[i].map { global[$0] }; records[global[i]].x = Int32(f.depth[i])
            for j in f.children[i] { records[global[j]].y = Int32(global[i]) }
        }
        if style == .balloon {
            mode = 1; scalars = [c.minRadius]; ordered = f.order.map { global[$0] }
            for (component, root) in f.roots.enumerated() {
                var stack = [root]
                while let i = stack.popLast() { records[global[i]].z = Int32(component); stack.append(contentsOf: f.children[i]) }
            }
        } else {
            mode = style == .tree ? 0 : 2
            scalars = style == .tree ? [c.nodeSeparation, c.levelSeparation] : [c.layerDistance, c.siblingDistance]
            for root in f.roots {
                var stack = [(root, false)]
                while let (i, post) = stack.popLast() {
                    let regular = style == .orgChart ? f.children[i].filter { flags[global[$0]] & 2 == 0 } : f.children[i]
                    if !post {
                        stack.append((i, true))
                        let hasAssistants = regular.count != f.children[i].count
                        for j in regular.reversed() {
                            if style == .orgChart { records[global[j]].x = records[global[i]].x + (hasAssistants ? 2 : 1) }
                            stack.append((j, false))
                        }
                    } else { ordered.append(global[i]); if i == root { records[global[i]].z = 1 } }
                }
                try Task.checkCancellation()
            }
            if style == .orgChart {
                for i in ordered { for j in lists[i] where flags[j] & 2 != 0 { flags[j] |= 8 } }
            }
        }
    }
    for i in ordered { flags[i] |= 8 }
    var childOffsets: [UInt32] = [0], children: [UInt32] = []
    for list in lists { children.append(contentsOf: list.map(UInt32.init)); childOffsets.append(UInt32(children.count)) }
    let size = targets.map { max($0.width, $0.height) }.max() ?? 0
    let magnitude: Double
    if style == .treeMap { magnitude = 4_000 + abs(c.padding) * Double(targets.count) * 4 }
    else if style == .orgChart {
        let assistants = flags.filter { $0 & 10 == 10 }.count
        let horizontal = Double(targets.count) * (size + abs(c.siblingDistance)) + Double(assistants) * (size + 20)
        let vertical = Double(records.map { max(0, $0.x) }.max() ?? 0) * abs(c.layerDistance) + Double(assistants) * (size + 30)
        magnitude = (max(horizontal, vertical) + size) * 4
    } else {
        magnitude = (size + (scalars.map(abs).max() ?? 0) + 1) * Double(max(1, targets.count)) * 4
    }
    var orientationSafe = true
    if style == .treeMap {
        // Precision analysis propagates dimensions only, never final positions.
        // GPU still computes subtree weights, rectangle sizes and coordinates.
        var weights = Array(repeating: 0.0, count: targets.count)
        var exact = targets.map { SIMD2<Double>($0.width, $0.height) }
        var approximate = exact.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        for i in ordered.reversed() { weights[i] = max(1, lists[i].reduce(0) { $0 + weights[$1] }) }
        for i in ordered {
            if records[i].z == 1 { exact[i] = SIMD2(1000, 1000); approximate[i] = SIMD2(1000, 1000) }
            let e = exact[i], a = approximate[i], vertical = e.x > e.y, floatVertical = a.x > a.y
            if lists[i].count > 1 {
                let nearBoundary = e.x != e.y && abs(Double(a.x) - Double(a.y)) <= Double(max(a.x.ulp, a.y.ulp)) * 8
                if vertical != floatVertical || nearBoundary { orientationSafe = false }
            }
            let inner = SIMD2(max(0, e.x - 2 * c.padding), max(0, e.y - 2 * c.padding))
            let fInner = SIMD2(max(0, a.x - 2 * Float(c.padding)), max(0, a.y - 2 * Float(c.padding)))
            let total = max(1, lists[i].reduce(0) { $0 + weights[$1] })
            let fTotal = max(1, lists[i].reduce(Float(0)) { $0 + Float(weights[$1]) })
            for child in lists[i] {
                let ratio = weights[child] / total, fRatio = Float(weights[child]) / fTotal
                exact[child] = vertical ? SIMD2(inner.x * ratio, inner.y) : SIMD2(inner.x, inner.y * ratio)
                approximate[child] = floatVertical ? SIMD2(fInner.x * fRatio, fInner.y) : SIMD2(fInner.x, fInner.y * fRatio)
            }
        }
    }
    let state = MetalPlacementState(bounds: targets.map(\.bounds), flags: flags, records: records,
        order: ordered.map(UInt32.init), childOffsets: childOffsets, children: children,
        scalars: scalars, mode: mode, resource: "TreeLayouts", conservativeMagnitude: magnitude, serial: true, nodeCount: graph.nodes.count, discreteGeometrySafe: orientationSafe)
    return TreePlacementPlan(targets: targets, state: state)
}

public extension LayoutBuilder {
    @discardableResult func useTreeLayout(_ style: TreeLayoutStyle, backend: LayoutBackend, executor: LayoutExecutor = .shared,
                                         configure: (inout TreeLayoutConfiguration) -> Void = { _ in }) -> Self {
        var c = TreeLayoutConfiguration(); configure(&c)
        return useAsyncAlgorithm(TreeLayoutOperation(style: style, backend: backend, executor: executor, configuration: c))
    }
    @discardableResult func useTree(backend: LayoutBackend, executor: LayoutExecutor = .shared, configure: (inout TreeLayoutConfiguration) -> Void = { _ in }) -> Self { useTreeLayout(.tree, backend: backend, executor: executor, configure: configure) }
    @discardableResult func useBalloon(backend: LayoutBackend, executor: LayoutExecutor = .shared, configure: (inout TreeLayoutConfiguration) -> Void = { _ in }) -> Self { useTreeLayout(.balloon, backend: backend, executor: executor, configure: configure) }
    @discardableResult func useOrgChart(backend: LayoutBackend, executor: LayoutExecutor = .shared, configure: (inout TreeLayoutConfiguration) -> Void = { _ in }) -> Self { useTreeLayout(.orgChart, backend: backend, executor: executor, configure: configure) }
    @discardableResult func useTreeMap(backend: LayoutBackend, executor: LayoutExecutor = .shared, configure: (inout TreeLayoutConfiguration) -> Void = { _ in }) -> Self { useTreeLayout(.treeMap, backend: backend, executor: executor, configure: configure) }
}
