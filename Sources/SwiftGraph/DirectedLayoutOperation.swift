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
    /// Preferred separation between parallel edge runs. Strokes never touch below it, but parallel
    /// runs closer than this are avoided, tracks keep this spacing, and compaction never goes below it.
    public var edgeSpacing: Double = 10
    public var candidateCount: Int = 5
    /// Indices into the original edge array. A fresh layout ranks and routes these as reversed edges between the ranks.
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
    /// Near-parallel route pairs closer than `edgeSpacing`.
    public var proximateRuns = 0
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
        if let constrained = constrainedConfiguration(for: original) {
            return try DirectedLayoutOperation(configuration: constrained, cache: cache).apply(original)
        }
        guard let plan = try prepare(original) else { return .init() }
        for component in plan.components {
            try Task.checkCancellation()
            let run = DirectedComponentRun(self, plan, component)
            for candidate in 0..<run.candidateCount {
                try Task.checkCancellation()
                if let placement = try run.place(candidate) { try placement.applyLayout(run.sub) }
                run.placed()
                try run.routeIncumbent()
                let first = try run.measure()
                let score = try run.routeCoordinated(after: first) ? try run.measure() : first
                if run.settle(score) { break }
            }
            for candidate in run.refinementCandidates {
                try run.refine(candidate)
                run.keepRefined(try run.measure())
            }
            run.finishRefinement()
            try run.publish()
        }
        pack(plan)
        return try finish(plan, try DirectedGeometry.measure(nodes: plan.nodes, edges: plan.edges, spacing: configuration.edgeSpacing))
    }

    /// Requests that depend on supplied geometry are first expressed as the equivalent constrained request.
    func constrainedConfiguration(for original: LayoutGraph) -> DirectedLayoutConfiguration? {
        var constrained = configuration
        if configuration.mode == .routesOnly && original.nodes.contains(where: { configuration.previousBounds[$0.id] == nil }) {
            for node in original.nodes where constrained.previousBounds[node.id] == nil { constrained.previousBounds[node.id] = node.bounds }
            return constrained
        }
        if configuration.mode == .fresh && !configuration.fixedNodeIDs.isEmpty {
            constrained.mode = .incremental
            for node in original.nodes where constrained.fixedNodeIDs.contains(node.id) && constrained.previousBounds[node.id] == nil {
                constrained.previousBounds[node.id] = node.bounds
            }
            return constrained
        }
        return nil
    }

    /// Copies the caller's graph, classifies feedback, reserves port capacity and splits components.
    func prepare(_ original: LayoutGraph) throws -> DirectedPlan? {
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
        guard !nodes.isEmpty else { return nil }
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
        // A fresh layout ranks feedback edges as reversed edges and routes them between the ranks, from the
        // source's near side to the target's, unless reversing one would close a cycle (a caller-supplied
        // feedback set need not break every cycle). Every other mode keeps feedback in lanes above the drawing.
        var reversed: Set<LayoutEdge> = []
        if configuration.mode == .fresh {
            var successors: [LayoutNode: [LayoutNode]] = [:]
            for edge in allEdges where !feedback.contains(edge) && edge.source !== edge.target { successors[edge.source, default: []].append(edge.target) }
            func reaches(_ from: LayoutNode, _ to: LayoutNode) -> Bool {
                var stack = [from], seen: Set<LayoutNode> = [from]
                while let node = stack.popLast() {
                    if node === to { return true }
                    for next in successors[node] ?? [] where seen.insert(next).inserted { stack.append(next) }
                }
                return false
            }
            for edge in feedback.sorted(by: { edgeIndex[$0]! < edgeIndex[$1]! }) where edge.source !== edge.target && !reaches(edge.source, edge.target) {
                reversed.insert(edge); successors[edge.target, default: []].append(edge.source)
            }
        }
        // Reserve capacity on the sides each end will use (as `DirectedRouter` assigns them), before ranking.
        // Lane feedback and loops use top ports; explicit port constraints rule an ordinary or reversed edge.
        var sideCounts: [LayoutNode: [PortConstraint: Int]] = [:]
        for edge in allEdges {
            let sides: (PortConstraint, PortConstraint)
            if edge.source === edge.target || (feedback.contains(edge) && !reversed.contains(edge)) { sides = (.top, .top) }
            else if edge.sourcePort != .none && edge.targetPort != .none { sides = (edge.sourcePort, edge.targetPort) }
            else { sides = reversed.contains(edge) ? (.left, .right) : (.right, .left) }
            sideCounts[edge.source, default: [:]][sides.0, default: 0] += 1
            sideCounts[edge.target, default: [:]][sides.1, default: 0] += 1
        }
        let widest = configuration.edgeWidths.max() ?? 1
        let pitch = max(configuration.portSpacing, widest * 2.5 + 6)
        for node in nodes {
            let c = sideCounts[node] ?? [:]
            let center = configuration.previousBounds[node.id]?.center ?? node.center
            node.height = max(node.height, Double(max(c[.left] ?? 0, c[.right] ?? 0) - 1) * pitch + 24)
            node.width = max(node.width, Double(max(c[.top] ?? 0, c[.bottom] ?? 0) - 1) * pitch + 24)
            node.center = center
        }
        var diagnostics = DirectedLayoutDiagnostics()
        diagnostics.feedbackEdgeIndices = feedback.compactMap { edgeIndex[$0] }.sorted()
        diagnostics.stageMilliseconds["sizing"] = milliseconds(sizingStart.duration(to: .now))
        return DirectedPlan(graph: graph, nodes: nodes, edges: allEdges, edgeIndex: edgeIndex, feedback: feedback.subtracting(reversed), reversed: reversed, pitch: pitch,
            components: configuration.mode == .fresh ? Adjacency(graph).components() : [Array(nodes.indices)],
            diagnostics: diagnostics, start: start, original: original)
    }

    /// Fills the diagnostics and publishes geometry to the caller's graph.
    func finish(_ plan: DirectedPlan, _ score: DirectedGeometry.Score) throws -> DirectedLayoutDiagnostics {
        var diagnostics = plan.diagnostics
        let nodes = plan.nodes, allEdges = plan.edges
        diagnostics.stageMilliseconds["placement"] = plan.placementTime
        diagnostics.stageMilliseconds["routing"] = plan.routingTime
        // Restore input order; ranking candidates never affect identity or edge order.
        plan.graph.nodes = nodes; plan.graph.edges = allEdges
        diagnostics.unroutableEdges = allEdges.indices.filter { allEdges[$0].path.count < 2 }
        diagnostics.crossings = score.crossings; diagnostics.sharedRuns = score.shared; diagnostics.proximateRuns = score.proximity
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
        for (target, source) in zip(plan.original.nodes, nodes) { target.bounds = source.bounds }
        for (target, source) in zip(plan.original.edges, allEdges) { target.path = source.path }
        let elapsed = plan.start.duration(to: .now).components
        diagnostics.stageMilliseconds["total"] = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        return diagnostics
    }

    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    func ordered(_ nodes: [LayoutNode], edges: [LayoutEdge], trial: Int) -> [LayoutNode] {
        let counts = Dictionary(grouping: edges, by: { trial == 2 ? $0.target : $0.source }).mapValues(\.count)
        return nodes.sorted {
            if trial == 0 { return $0.id < $1.id }
            if trial == 4 { return $0.id > $1.id }
            let a = counts[$0] ?? 0, b = counts[$1] ?? 0
            return a == b ? $0.id < $1.id : (trial == 3 ? a < b : a > b)
        }
    }

    func placeIncrementally(_ nodes: [LayoutNode], edges: [LayoutEdge], pitch: Double) {
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

    /// A direct edge runs straight when its endpoints' side ranges overlap (ports slide along the sides). Where they miss
    /// by less than `nodeSpacing`, one endpoint slides within its rank's free interval, clear of other nodes and
    /// virtual-node tracks, as long as that reduces the misses and their total distance.
    func straightenDoglegs(_ nodes: [LayoutNode], edges: [LayoutEdge], feedback: Set<LayoutEdge>) {
        var incident: [LayoutNode: [LayoutEdge]] = [:]
        var tracks: [Double: [Double]] = [:]
        for edge in edges where !feedback.contains(edge) && edge.source !== edge.target {
            if edge.path.count == 2 && edge.source.center.x != edge.target.center.x {
                incident[edge.source, default: []].append(edge); incident[edge.target, default: []].append(edge)
            }
            for p in edge.path.dropFirst().dropLast() { tracks[p.x, default: []].append(p.y) }
        }
        let ranks = Dictionary(grouping: nodes, by: { $0.center.x })
        let reach = configuration.nodeSpacing, margin = 4.0
        for _ in 0..<8 {
            var moved = false
            for node in nodes.sorted(by: { ($0.center.x, $0.center.y, $0.id) < ($1.center.x, $1.center.y, $1.id) }) {
                guard let list = incident[node] else { continue }
                func range(_ n: LayoutNode, _ shift: Double = 0) -> (lo: Double, hi: Double) {
                    let r = DirectedRouter.sideRange(n.bounds); return (r.lo + shift, r.hi + shift)
                }
                // (edges that miss, total miss distance): a slide must improve this pair, so passes terminate.
                func cost(_ shift: Double) -> (Int, Double) {
                    list.reduce((0, 0.0)) { total, edge in
                        let a = range(node, shift), b = range(edge.source === node ? edge.target : edge.source)
                        let gap = max(a.lo, b.lo) - min(a.hi, b.hi)
                        return gap > 0 ? (total.0 + 1, total.1 + gap) : total
                    }
                }
                let current = cost(0)
                guard current.0 > 0 else { continue }
                var below = Double.infinity, above = -Double.infinity
                for other in ranks[node.center.x] ?? [] where other !== node {
                    if other.center.y < node.center.y { above = max(above, other.bounds.bottom + configuration.nodeSpacing) }
                    else { below = min(below, other.bounds.top - configuration.nodeSpacing) }
                }
                for y in tracks[node.center.x] ?? [] {
                    if y < node.center.y { above = max(above, y + 4 + configuration.nodeSpacing / 2) }
                    else { below = min(below, y - 4 - configuration.nodeSpacing / 2) }
                }
                var best: (shift: Double, cost: (Int, Double))?
                for edge in list {
                    let a = range(node), b = range(edge.source === node ? edge.target : edge.source)
                    guard max(a.lo, b.lo) > min(a.hi, b.hi) else { continue }
                    let shift = a.hi < b.lo ? b.lo - a.hi + margin : b.hi - a.lo - margin
                    guard abs(shift) <= reach, node.bounds.top + shift >= above, node.bounds.bottom + shift <= below else { continue }
                    let next = cost(shift)
                    if next < current, best == nil || next < best!.cost || (next == best!.cost && abs(shift) < abs(best!.shift)) { best = (shift, next) }
                }
                if let best { node.center = node.center + Point(x: 0, y: best.shift); moved = true }
            }
            if !moved { break }
        }
        for edge in edges where edge.path.count >= 2 && !feedback.contains(edge) && edge.source !== edge.target {
            edge.path[0] = edge.source.center; edge.path[edge.path.count - 1] = edge.target.center
        }
    }

    func widenCorridors(_ nodes: [LayoutNode], edges: [LayoutEdge], feedback: Set<LayoutEdge>) {
        let ranks = Array(Set(nodes.map { $0.center.x })).sorted()
        guard ranks.count > 1 else { return }
        let rankIndex = Dictionary(uniqueKeysWithValues: ranks.enumerated().map { ($0.element, $0.offset) })
        var traffic = Array(repeating: 0, count: ranks.count - 1)
        for edge in edges where !feedback.contains(edge) {
            let a = rankIndex[edge.source.center.x]!, b = rankIndex[edge.target.center.x]!
            if a != b { for rank in min(a, b)..<max(a, b) { traffic[rank] += 1 } }
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

    func pack(_ plan: DirectedPlan) {
        guard configuration.mode == .fresh else { return }
        let drawings = plan.drawings
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
