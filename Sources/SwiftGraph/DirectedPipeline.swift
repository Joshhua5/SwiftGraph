import Foundation

/// Everything the backends share about one request: the work graph, port-sized nodes and components.
final class DirectedPlan {
    let graph: LayoutGraph, nodes: [LayoutNode], edges: [LayoutEdge]
    let edgeIndex: [LayoutEdge: Int], pitch: Double, components: [[Int]]
    /// Feedback routed as top lanes outside the ranks; `reversed` feedback is laid out and routed between them like any edge.
    let feedback: Set<LayoutEdge>, reversed: Set<LayoutEdge>
    let start: ContinuousClock.Instant, original: LayoutGraph
    var diagnostics: DirectedLayoutDiagnostics
    var placementTime = 0.0, routingTime = 0.0
    var drawings: [(nodes: [LayoutNode], edges: [LayoutEdge], bounds: Rect)] = []
    init(graph: LayoutGraph, nodes: [LayoutNode], edges: [LayoutEdge], edgeIndex: [LayoutEdge: Int], feedback: Set<LayoutEdge>, reversed: Set<LayoutEdge>, pitch: Double,
         components: [[Int]], diagnostics: DirectedLayoutDiagnostics, start: ContinuousClock.Instant, original: LayoutGraph) {
        self.graph = graph; self.nodes = nodes; self.edges = edges; self.edgeIndex = edgeIndex; self.feedback = feedback; self.reversed = reversed; self.pitch = pitch
        self.components = components; self.diagnostics = diagnostics; self.start = start; self.original = original
    }
}

/// One component's candidate search. The CPU and async backends drive the same steps; they differ only in
/// how `DirectedHierarchy` is applied to `sub` and how a drawing is scored (`measure()` or the GPU kernel).
final class DirectedComponentRun {
    let operation: DirectedLayoutOperation, plan: DirectedPlan
    let members: [LayoutNode], edges: [LayoutEdge], sub = LayoutGraph()
    let preserve: Bool, trials: Int, variants: Int, key: DirectedComponentKey
    private(set) var cached: Bool
    private var best: DirectedComponentDrawing?, legacyBest: DirectedComponentDrawing?, incumbent: DirectedComponentDrawing?
    private var refinedBest: DirectedComponentDrawing?, guides: [[Point]] = []
    private var placementStart = ContinuousClock.now, routingStart = ContinuousClock.now, refinementStart = ContinuousClock.now
    private var configuration: DirectedLayoutConfiguration { operation.configuration }

    init(_ operation: DirectedLayoutOperation, _ plan: DirectedPlan, _ component: [Int]) {
        self.operation = operation; self.plan = plan
        let configuration = operation.configuration
        members = component.map { plan.nodes[$0] }
        let memberSet = Set(members)
        edges = plan.edges.filter { memberSet.contains($0.source) }
        members.forEach(sub.addNodeDetached); sub.edges = edges
        preserve = configuration.mode != .fresh && members.contains { configuration.previousBounds[$0.id] != nil }
        let budget = edges.count > 180 || members.count > 180 ? 2 : 5
        trials = preserve ? 1 : max(1, min(budget, configuration.candidateCount))
        // The ordering score excludes ports and obstacles. On ordinary components, also evaluate the
        // terminal sweep so the final routed score breaks the tie; large ones keep the two-candidate bound.
        variants = !preserve && budget == 5 ? 2 : 1
        var keyConfig = configuration
        // Geometry outside a component cannot influence a fresh component drawing.
        if configuration.mode == .fresh { keyConfig.previousBounds = [:]; keyConfig.insertionOrigins = [:] }
        key = DirectedComponentKey(nodes: members.map { .init(id: $0.id, width: $0.width, height: $0.height) },
            edges: edges.map { .init(source: $0.source.id, target: $0.target.id, sourcePort: $0.sourcePort, targetPort: $0.targetPort, index: plan.edgeIndex[$0]!) },
            configuration: keyConfig)
        best = operation.cache?.drawing(for: key)
        cached = best != nil
        if cached { plan.diagnostics.cachedComponents += 1 }
    }

    var candidateCount: Int { cached ? 0 : trials * variants }
    func measure() throws -> DirectedGeometry.Score {
        try DirectedGeometry.measure(nodes: members, edges: edges, spacing: configuration.edgeSpacing)
    }
    private func router() -> DirectedRouter {
        DirectedRouter(nodes: members, edges: edges, feedback: plan.feedback, edgeIndices: plan.edgeIndex, configuration: configuration, pitch: plan.pitch)
    }
    private func drawing(_ score: DirectedGeometry.Score) -> DirectedComponentDrawing {
        DirectedComponentDrawing(bounds: members.map(\.bounds), paths: edges.map(\.path), score: score)
    }
    private func load(_ d: DirectedComponentDrawing) {
        for (node, rect) in zip(members, d.bounds) { node.bounds = rect }
        for (edge, path) in zip(edges, d.paths) { edge.path = path }
    }

    /// Orders and orients the component for the hierarchy placement; incremental drawings are placed here instead (returns nil).
    func place(_ candidate: Int) throws -> DirectedHierarchy? {
        placementStart = .now
        if preserve { operation.placeIncrementally(members, edges: edges, pitch: plan.pitch); return nil }
        sub.nodes = operation.ordered(members, edges: edges, trial: candidate / variants)
        sub.edges = edges.filter { !plan.feedback.contains($0) && $0.source !== $0.target }
        for n in members { let w = n.width; n.width = n.height; n.height = w }
        let hierarchy = DirectedHierarchy()
        hierarchy.retainBestSweep = candidate % variants == 0
        hierarchy.layerSeparation = max(configuration.layerSpacing, min(320, Double(edges.count) * 2.5))
        hierarchy.nodeSeparation = configuration.nodeSpacing
        hierarchy.portPitch = plan.pitch
        hierarchy.reversed = plan.reversed
        return hierarchy
    }

    func placed() {
        if !preserve {
            for n in members { n.bounds = Rect(x: n.y, y: n.x, width: n.height, height: n.width) }
            for e in sub.edges { e.path = e.path.map { Point(x: $0.y, y: $0.x) } }
            sub.edges = edges
            operation.straightenDoglegs(members, edges: edges, feedback: plan.feedback)
            operation.widenCorridors(members, edges: edges, feedback: plan.feedback)
        }
        plan.placementTime += operation.milliseconds(placementStart.duration(to: .now))
    }

    /// The previous strategy is kept as an incumbent for each ordering: a more compact channel
    /// arrangement must earn its place on final geometry rather than discard a lower-crossing drawing.
    func routeIncumbent() throws {
        routingStart = .now
        guides = edges.map(\.path)
        try router().route(coordinated: false)
    }

    /// Records the scored incumbent and, for fresh drawings, routes the coordinated strategy (returns whether it did).
    func routeCoordinated(after score: DirectedGeometry.Score) throws -> Bool {
        let first = drawing(score)
        incumbent = first
        guard configuration.mode == .fresh else { plan.routingTime += operation.milliseconds(routingStart.duration(to: .now)); return false }
        if legacyBest == nil || first.score.precedes(legacyBest!.score) { legacyBest = first }
        for (edge, guide) in zip(edges, guides) { edge.path = guide }
        try router().route()
        plan.routingTime += operation.milliseconds(routingStart.duration(to: .now))
        return true
    }

    /// Keeps the better drawing, then reinstates the incumbent: feedback paths seed the next trial's port
    /// order, and the compact trial must not alter the incumbent strategy's inputs. True stops the search early.
    func settle(_ score: DirectedGeometry.Score) -> Bool {
        let result = drawing(score)
        if best == nil || result.score.precedes(best!.score) { best = result }
        load(incumbent!)
        return score.crossings == 0 && score.shared == 0 && score.missing == 0
    }

    /// Refinement can change crossings: the two strategies compete only after both get the same final-geometry optimization.
    var refinementCandidates: [DirectedComponentDrawing] {
        guard !cached, configuration.mode == .fresh else { return [] }
        refinementStart = .now
        if let l = legacyBest, let b = best, l.bounds == b.bounds && l.paths == b.paths { return [b] }
        return [legacyBest, best].compactMap { $0 }
    }
    func refine(_ candidate: DirectedComponentDrawing) throws {
        load(candidate)
        var refinement = router()
        try refinement.refine()
        try DirectedDrawingCompaction.apply(nodes: members, edges: edges, clearance: refinement.clearance, spacing: refinement.edgeSpacing,
            layerSpacing: configuration.layerSpacing, nodeSpacing: configuration.nodeSpacing)
        refinement = router()
        try refinement.refine()
        try refinement.improveWorstRoutes()
        try refinement.polish()
    }
    func keepRefined(_ score: DirectedGeometry.Score) {
        let result = drawing(score)
        if refinedBest == nil || result.score.precedes(refinedBest!.score) { refinedBest = result }
    }
    func finishRefinement() {
        guard !cached, configuration.mode == .fresh else { return }
        best = refinedBest
        plan.routingTime += operation.milliseconds(refinementStart.duration(to: .now))
    }

    /// Applies the winner to the component and stores it in the cache when uncached.
    @discardableResult
    func publish() throws -> Bool {
        if let best {
            try Task.checkCancellation()
            load(best)
            if !cached { operation.cache?.insert(best, for: key) }
        }
        plan.drawings.append((members, edges, DirectedGeometry.bounds(nodes: members, edges: edges)))
        return best != nil && !cached
    }
    func store(_ score: DirectedGeometry.Score) { operation.cache?.insert(drawing(score), for: key) }
}
