import Foundation

/// The quality-oriented directed pipeline is separate from the parity-preserving routers.
public enum DirectedLayoutMode: Hashable, Sendable { case fresh, incremental, routesOnly }

public struct DirectedLayoutConfiguration: Hashable, Sendable {
    public var mode: DirectedLayoutMode = .fresh
    public var canvasAspectRatio: Double = 1.6
    public var nodeSpacing: Double = 32
    public var layerSpacing: Double = 100
    public var componentSpacing: Double = 60
    public var portSpacing: Double = 12
    public var clearance: Double = 10
    public var candidateCount: Int = 5
    /// Indices into the original edge array. Feedback participates in connectivity, not ranking.
    public var feedbackEdges: Set<Int> = []
    public var edgeWidths: [Double] = []
    public var fixedNodeIDs: Set<String> = []
    public var previousPaths: [Int: [Point]] = [:]
    public var previousBounds: [String: Rect] = [:]
    /// Placement hints for newly expanded/collapsed nodes, not constraints.
    public var insertionOrigins: [String: Point] = [:]
    public init() {}
}

public struct DirectedLayoutDiagnostics: Sendable {
    public var unroutableEdges: [Int] = []
    public var overlappingNodeIDs: [[String]] = []
    public var fixedNodeConflicts: [[String]] = []
    public var crossings = 0
    public var sharedRuns = 0
    public var bends = 0
    public var routeLength = 0.0
    public var displacement = 0.0
    public var cachedComponents = 0
    public var feedbackEdgeIndices: [Int] = []
    public var bounds = Rect()
    public var stageMilliseconds: [String: Double] = [:]
    public init() {}
}

/// A task-confined operation. Cancellation never publishes a partially calculated drawing.
/// Node bounds may grow to accommodate distinct ports; callers must render returned bounds.
public struct DirectedLayoutOperation {
    public var configuration: DirectedLayoutConfiguration
    public var cache: DirectedLayoutCache?
    public init(configuration: DirectedLayoutConfiguration = .init(), cache: DirectedLayoutCache? = nil) {
        self.configuration = configuration; self.cache = cache
    }

    @discardableResult
    public func apply(_ original: LayoutGraph) throws -> DirectedLayoutDiagnostics {
        if configuration.mode == .routesOnly && original.nodes.contains(where: { configuration.previousBounds[$0.id] == nil }) {
            var constrained = configuration
            for node in original.nodes where constrained.previousBounds[node.id] == nil { constrained.previousBounds[node.id] = node.bounds }
            return try DirectedLayoutOperation(configuration: constrained, cache: cache).apply(original)
        }
        if configuration.mode == .fresh && !configuration.fixedNodeIDs.isEmpty {
            var constrained = configuration
            constrained.mode = .incremental
            for node in original.nodes where constrained.fixedNodeIDs.contains(node.id) && constrained.previousBounds[node.id] == nil {
                constrained.previousBounds[node.id] = node.bounds
            }
            return try DirectedLayoutOperation(configuration: constrained, cache: cache).apply(original)
        }
        let start = ContinuousClock.now
        let graph = LayoutGraph()
        let nodes = original.nodes.map { LayoutNode(id: $0.id, width: $0.width, height: $0.height) }
        for (copy, source) in zip(nodes, original.nodes) { copy.bounds = source.bounds; graph.addNode(copy) }
        let byNode = Dictionary(uniqueKeysWithValues: original.nodes.enumerated().map { ($0.element, $0.offset) })
        for edge in original.edges {
            let copy = LayoutEdge(source: nodes[byNode[edge.source]!], target: nodes[byNode[edge.target]!])
            copy.sourcePort = edge.sourcePort; copy.targetPort = edge.targetPort
            graph.addEdge(copy)
        }
        guard !nodes.isEmpty else { return .init() }
        let allEdges = graph.edges
        let sizingStart = ContinuousClock.now
        let edgeIndex = Dictionary(uniqueKeysWithValues: allEdges.enumerated().map { ($0.element, $0.offset) })
        var feedback = Set(configuration.feedbackEdges.compactMap { allEdges.indices.contains($0) ? allEdges[$0] : nil })
        // Deterministic back-edge classification makes the ranking graph acyclic. It also
        // reserves the correct sides for reciprocal/cyclic links before measuring capacity.
        let outgoing = Dictionary(grouping: allEdges, by: \.source)
        var colors: [LayoutNode: Int] = [:]
        func visit(_ node: LayoutNode) throws {
            try Task.checkCancellation()
            colors[node] = 1
            let next = (outgoing[node] ?? []).sorted {
                $0.target.id == $1.target.id ? edgeIndex[$0]! < edgeIndex[$1]! : $0.target.id < $1.target.id
            }
            for edge in next where !feedback.contains(edge) && edge.source !== edge.target {
                if colors[edge.target] == 1 { feedback.insert(edge) }
                else if colors[edge.target] == nil { try visit(edge.target) }
            }
            colors[node] = 2
        }
        for node in nodes.sorted(by: { $0.id < $1.id }) where colors[node] == nil { try visit(node) }
        // Reserve capacity before ranking. Directional feedback has independent top ports.
        var sideCounts: [LayoutNode: [Int]] = [:]
        for edge in allEdges {
            if edge.source === edge.target || feedback.contains(edge) {
                sideCounts[edge.source, default: [0, 0, 0]][2] += 1
                sideCounts[edge.target, default: [0, 0, 0]][2] += 1
            } else {
                sideCounts[edge.source, default: [0, 0, 0]][1] += 1
                sideCounts[edge.target, default: [0, 0, 0]][0] += 1
            }
        }
        let widest = configuration.edgeWidths.max() ?? 1
        let pitch = max(configuration.portSpacing, widest * 2.5 + 6)
        for node in nodes {
            let c = sideCounts[node] ?? [0, 0, 0]
            let center = configuration.previousBounds[node.id]?.center ?? node.center
            node.height = max(node.height, Double(max(c[0], c[1]) - 1) * pitch + 24)
            node.width = max(node.width, Double(c[2] - 1) * pitch + 24)
            node.center = center
        }
        var diagnostics = DirectedLayoutDiagnostics()
        diagnostics.feedbackEdgeIndices = feedback.compactMap { edgeIndex[$0] }.sorted()
        let components = configuration.mode == .fresh ? Adjacency(graph).components() : [Array(nodes.indices)]
        let canonicalIndex = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, $0.offset) })
        diagnostics.stageMilliseconds["sizing"] = milliseconds(sizingStart.duration(to: .now))
        var placementTime = 0.0, routingTime = 0.0
        var drawings: [(nodes: [LayoutNode], edges: [LayoutEdge], bounds: Rect)] = []
        for component in components {
            try Task.checkCancellation()
            let members = component.map { nodes[$0] }
            let memberSet = Set(members)
            let edges = allEdges.filter { memberSet.contains($0.source) }
            let sub = LayoutGraph()
            members.forEach(sub.addNodeDetached); sub.edges = edges
            let kept = members.filter { configuration.previousBounds[$0.id] != nil }
            let preserve = configuration.mode != .fresh && !kept.isEmpty
            let trialBudget = edges.count > 180 || members.count > 180 ? 2 : 5
            let trials = preserve ? 1 : max(1, min(trialBudget, configuration.candidateCount))
            var keyConfig = configuration
            // Geometry outside a component cannot influence a fresh component drawing.
            if configuration.mode == .fresh { keyConfig.previousBounds = [:]; keyConfig.insertionOrigins = [:] }
            let key = DirectedComponentKey(nodes: members.map { .init(id: $0.id, width: $0.width, height: $0.height) },
                edges: edges.map { .init(source: $0.source.id, target: $0.target.id, sourcePort: $0.sourcePort, targetPort: $0.targetPort, index: edgeIndex[$0]!) },
                configuration: keyConfig)
            var best = cache?.drawing(for: key)
            let cached = best != nil
            if cached { diagnostics.cachedComponents += 1 }
            // The ordering score excludes ports and obstacles. On ordinary components,
            // also evaluate the terminal sweep so the final routed score breaks the tie.
            // Large components retain the two-candidate responsiveness bound.
            let variants = !preserve && trialBudget == 5 ? 2 : 1
            for candidate in 0..<(cached ? 0 : trials * variants) {
                let trial = candidate / variants
                try Task.checkCancellation()
                let placementStart = ContinuousClock.now
                if preserve {
                    placeIncrementally(members, edges: edges, pitch: pitch)
                } else {
                    sub.nodes = ordered(members, edges: edges, trial: trial)
                    sub.edges = edges.filter { !feedback.contains($0) && $0.source !== $0.target }
                    for n in members { let w = n.width; n.width = n.height; n.height = w }
                    let hierarchy = DirectedHierarchy()
                    hierarchy.retainBestSweep = candidate % variants == 0
                    hierarchy.layerSeparation = max(configuration.layerSpacing, min(320, Double(edges.count) * 2.5))
                    hierarchy.nodeSeparation = configuration.nodeSpacing
                    try hierarchy.applyLayout(sub)
                    for n in members { n.bounds = Rect(x: n.y, y: n.x, width: n.height, height: n.width) }
                    for e in sub.edges { e.path = e.path.map { Point(x: $0.y, y: $0.x) } }
                    // Break exact coordinate coincidences between unrelated ports deterministically.
                    for n in members { n.y += Double(canonicalIndex[n]! % 97) * 0.125 }
                    sub.edges = edges
                    widenCorridors(members, edges: edges, feedback: feedback)
                }
                placementTime += milliseconds(placementStart.duration(to: .now))
                let routingStart = ContinuousClock.now
                let router = DirectedRouter(nodes: members, edges: edges, feedback: feedback,
                                            edgeIndices: edgeIndex, configuration: configuration, pitch: pitch)
                try router.route()
                routingTime += milliseconds(routingStart.duration(to: .now))
                let score = try DirectedGeometry.measure(nodes: members, edges: edges)
                let drawing = DirectedComponentDrawing(bounds: members.map(\.bounds), paths: edges.map(\.path), score: score)
                if best == nil || drawing.score.precedes(best!.score) { best = drawing }
                if score.crossings == 0 && score.shared == 0 && score.missing == 0 { break }
            }
            if let best {
                try Task.checkCancellation()
                for (node, rect) in zip(members, best.bounds) { node.bounds = rect }
                for (edge, path) in zip(edges, best.paths) { edge.path = path }
                if !cached {
                    if configuration.mode == .fresh {
                        let refinementStart = ContinuousClock.now
                        try DirectedRouter(nodes: members, edges: edges, feedback: feedback,
                            edgeIndices: edgeIndex, configuration: configuration, pitch: pitch).refine()
                        routingTime += milliseconds(refinementStart.duration(to: .now))
                    }
                    let refined = DirectedComponentDrawing(bounds: members.map(\.bounds), paths: edges.map(\.path),
                        score: try DirectedGeometry.measure(nodes: members, edges: edges))
                    cache?.insert(refined, for: key)
                }
            }
            drawings.append((members, edges, DirectedGeometry.bounds(nodes: members, edges: edges)))
        }
        diagnostics.stageMilliseconds["placement"] = placementTime
        diagnostics.stageMilliseconds["routing"] = routingTime
        if configuration.mode == .fresh { pack(&drawings) }
        // Restore input order; ranking candidates never affect identity or edge order.
        graph.nodes = nodes; graph.edges = allEdges
        let score = try DirectedGeometry.measure(nodes: nodes, edges: allEdges)
        diagnostics.unroutableEdges = allEdges.indices.filter { allEdges[$0].path.count < 2 }
        diagnostics.crossings = score.crossings; diagnostics.sharedRuns = score.shared
        diagnostics.bends = score.bends; diagnostics.routeLength = score.length
        diagnostics.bounds = DirectedGeometry.bounds(nodes: nodes, edges: allEdges)
        for i in nodes.indices {
            if let prior = configuration.previousBounds[nodes[i].id] { diagnostics.displacement += (nodes[i].center - prior.center).length }
            for j in nodes.indices where j > i && nodes[i].bounds.intersects(nodes[j].bounds) {
                let pair = [nodes[i].id, nodes[j].id]
                diagnostics.overlappingNodeIDs.append(pair)
                if pair.contains(where: configuration.fixedNodeIDs.contains) { diagnostics.fixedNodeConflicts.append(pair) }
            }
        }
        try Task.checkCancellation()
        for (target, source) in zip(original.nodes, nodes) { target.bounds = source.bounds }
        for (target, source) in zip(original.edges, allEdges) { target.path = source.path }
        let elapsed = start.duration(to: .now).components
        diagnostics.stageMilliseconds["total"] = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        return diagnostics
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func ordered(_ nodes: [LayoutNode], edges: [LayoutEdge], trial: Int) -> [LayoutNode] {
        let counts = Dictionary(grouping: edges, by: { trial == 2 ? $0.target : $0.source }).mapValues(\.count)
        return nodes.sorted {
            if trial == 0 { return $0.id < $1.id }
            if trial == 4 { return $0.id > $1.id }
            let a = counts[$0] ?? 0, b = counts[$1] ?? 0
            return a == b ? $0.id < $1.id : (trial == 3 ? a < b : a > b)
        }
    }

    private func placeIncrementally(_ nodes: [LayoutNode], edges: [LayoutEdge], pitch: Double) {
        var placed = nodes.filter { configuration.previousBounds[$0.id] != nil }
        let widest = configuration.edgeWidths.max() ?? 1
        let routeClearance = max(configuration.clearance, (widest * 2.5 + 4) / 2 + 2)
        // Both endpoints need an escape segment. Body separation alone can leave
        // a new node's entry point inside its neighbour's routing obstacle.
        let insertionGap = max(configuration.nodeSpacing, routeClearance * 2 + widest + 1)
        for n in placed { n.center = configuration.previousBounds[n.id]!.center }
        for node in nodes.filter({ configuration.previousBounds[$0.id] == nil }).sorted(by: { $0.id < $1.id }) {
            let neighbors = edges.compactMap { e -> Point? in
                let other = e.source === node ? e.target : (e.target === node ? e.source : nil)
                return other.flatMap { configuration.previousBounds[$0.id]?.center }
            }
            let origin = configuration.insertionOrigins[node.id] ?? (neighbors.isEmpty ? .zero : neighbors.reduce(.zero, +) / Double(neighbors.count))
            let dx = node.width + configuration.nodeSpacing, dy = node.height + configuration.nodeSpacing
            var found = false
            for ring in 0...max(16, nodes.count) {
                for row in -ring...ring {
                    for col in -ring...ring where abs(row) == ring || abs(col) == ring {
                        node.center = origin + Point(x: Double(col) * dx, y: Double(row) * dy)
                        if !placed.contains(where: { $0.bounds.inflated(by: insertionGap).intersects(node.bounds) }) { found = true; break }
                    }
                    if found { break }
                }
                if found { break }
            }
            placed.append(node)
        }
    }

    private func widenCorridors(_ nodes: [LayoutNode], edges: [LayoutEdge], feedback: Set<LayoutEdge>) {
        let ranks = Array(Set(nodes.map { $0.center.x })).sorted()
        guard ranks.count > 1 else { return }
        let rankIndex = Dictionary(uniqueKeysWithValues: ranks.enumerated().map { ($0.element, $0.offset) })
        var traffic = Array(repeating: 0, count: ranks.count - 1)
        for edge in edges where !feedback.contains(edge) {
            let a = rankIndex[edge.source.center.x]!, b = rankIndex[edge.target.center.x]!
            if a < b { for rank in a..<b { traffic[rank] += 1 } }
        }
        let widths = ranks.map { x in nodes.filter { $0.center.x == x }.map(\.width).max() ?? 0 }
        let trackPitch = max(6, (configuration.edgeWidths.max() ?? 1) + 3)
        var coordinates = [ranks[0]]
        for i in traffic.indices {
            let gap = max(configuration.layerSpacing, Double(traffic[i] + 1) * trackPitch + configuration.clearance * 2)
            coordinates.append(coordinates[i] + widths[i] / 2 + gap + widths[i + 1] / 2)
        }
        for node in nodes { node.center = Point(x: coordinates[rankIndex[node.center.x]!], y: node.center.y) }
        for edge in edges {
            edge.path = edge.path.map { p in rankIndex[p.x].map { Point(x: coordinates[$0], y: p.y) } ?? p }
        }
    }

    private func pack(_ drawings: inout [(nodes: [LayoutNode], edges: [LayoutEdge], bounds: Rect)]) {
        let gap = configuration.componentSpacing
        let area = drawings.reduce(0.0) { $0 + ($1.bounds.width + gap) * ($1.bounds.height + gap) }
        let target = max(drawings.map { $0.bounds.width }.max() ?? 0, sqrt(area * max(0.25, configuration.canvasAspectRatio)))
        let order = drawings.indices.sorted {
            drawings[$0].bounds.height == drawings[$1].bounds.height ? $0 < $1 : drawings[$0].bounds.height > drawings[$1].bounds.height
        }
        var x = 0.0, y = 0.0, rowHeight = 0.0
        for i in order {
            let b = drawings[i].bounds
            if x > 0 && x + b.width > target { x = 0; y += rowHeight + gap; rowHeight = 0 }
            let delta = Point(x: x - b.left, y: y - b.top)
            for n in drawings[i].nodes { n.center = n.center + delta }
            for e in drawings[i].edges { e.path = e.path.map { $0 + delta } }
            x += b.width + gap; rowHeight = max(rowHeight, b.height)
        }
        let center = DirectedGeometry.bounds(nodes: drawings.flatMap(\.nodes), edges: drawings.flatMap(\.edges)).center
        for d in drawings {
            for n in d.nodes { n.center = n.center - center }
            for e in d.edges { e.path = e.path.map { $0 - center } }
        }
    }
}
