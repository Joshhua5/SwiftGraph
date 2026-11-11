import Foundation

/// Port assignment and corridor candidates share obstacle geometry for the whole component.
/// The exact-coordinate search is a repair path, not the common case for every edge.
final class DirectedRouter {
    typealias Ports = (Point, Point, Point, Point)

    /// Positions in `nodes` of an edge's source and target, whose padded obstacles its own route may enter.
    typealias Endpoints = (source: Int, target: Int)
    let nodes: [LayoutNode]
    let edges: [LayoutEdge]
    let feedback: Set<LayoutEdge>
    let edgeIndices: [LayoutEdge: Int]
    let configuration: DirectedLayoutConfiguration
    let pitch: Float
    private(set) var bodies: [Rect] = []
    private(set) var obstacles: [Rect] = []

    /// `bodies` and `obstacles`, indexed so a clearance test visits only nearby nodes.
    private(set) var bodyIndex = DirectedObstacleIndex([])
    private(set) var obstacleIndex = DirectedObstacleIndex([])
    private let nodeIndices: [LayoutNode: Int]

    /// Each node's edges in edge order, for scans that concern only that node's ports.
    let incidentEdges: [LayoutNode: [LayoutEdge]]
    let occupied = DirectedSegmentGrid()
    var ports: [LayoutEdge: Ports] = [:]
    let clearance: Float

    /// Strokes must never touch: the hard floor beneath `edgeSpacing`.
    let trackClearance: Float

    /// Preferred separation between parallel runs; routing relaxes to `trackClearance` only as a last resort.
    let edgeSpacing: Float
    var spacing: Float
    var coordinated = false
    var retained: Set<LayoutEdge> = []

    /// False until a polishing pass first loads `occupied`; see `load(excluding:)`.
    private var isOccupancyCurrent = false

    /// The route a polishing pass has taken out of `occupied` while it works on it.
    private var unindexedEdge: LayoutEdge?
    var costs: [Float] = []
    var previous: [Int] = []
    var closed: [Bool] = []

    init(
        nodes: [LayoutNode],
        edges: [LayoutEdge],
        feedback: Set<LayoutEdge>,
        edgeIndices: [LayoutEdge: Int],
        configuration: DirectedLayoutConfiguration,
        pitch: Float
    ) {
        self.nodes = nodes
        self.edges = edges
        self.feedback = feedback
        self.edgeIndices = edgeIndices
        self.configuration = configuration
        self.pitch = pitch
        trackClearance = (configuration.edgeWidths.max() ?? 1) + 1
        edgeSpacing = max(configuration.edgeSpacing, trackClearance)
        spacing = edgeSpacing
        clearance = max(configuration.clearance, ((configuration.edgeWidths.max() ?? 1) * 2.5 + 4) / 2 + 2)
        nodeIndices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, $0.offset) })
        var incident: [LayoutNode: [LayoutEdge]] = [:]
        for edge in edges {
            incident[edge.source, default: []].append(edge)
            if edge.target !== edge.source { incident[edge.target, default: []].append(edge) }
        }
        incidentEdges = incident
        indexNodes()
    }

    /// Reads the node geometry every clearance test is made against; called again whenever nodes move.
    private func indexNodes() {
        bodies = nodes.map(\.bounds)
        obstacles = bodies.map { $0.inflated(by: clearance) }
        bodyIndex = DirectedObstacleIndex(bodies)
        obstacleIndex = DirectedObstacleIndex(obstacles)
    }

    func endpoints(of edge: LayoutEdge) -> Endpoints {
        (nodeIndices[required: edge.source], nodeIndices[required: edge.target])
    }

    /// A stroke of `endpoints`' route must clear every node body and every other node's padded obstacle.
    func isClear(_ a: Point, _ b: Point, besides endpoints: Endpoints) -> Bool {
        bodyIndex.clear(a, b) && obstacleIndex.clear(a, b, skipping: endpoints.source, endpoints.target)
    }

    func route(coordinated: Bool = true) throws {
        self.coordinated = coordinated && configuration.mode == .fresh
        assignPorts()
        var channels: [LayoutEdge: [Point]]
        if self.coordinated {
            let priorX = Dictionary(uniqueKeysWithValues: nodes.map { ($0, $0.center.x) })
            let plan = DirectedChannelPlan(
                nodes: nodes,
                edges: edges,
                feedback: feedback,
                ports: ports,
                edgeIndices: edgeIndices,
                clearance: clearance,
                spacing: edgeSpacing
            )
            channels = try plan.apply(minimumGap: configuration.layerSpacing)
            for edge in edges {
                var p = ports[required: edge]
                p.0.x += edge.source.center.x - priorX[required: edge.source]
                p.1.x += edge.target.center.x - priorX[required: edge.target]
                ports[edge] = p
            }
            indexNodes()
        } else {
            channels = hierarchyPaths()
        }
        let guides = edges.map(\.path)
        let basePorts = ports
        try routePass(reverse: false, channelPaths: channels)
        let missing = edges.filter { $0.path.isEmpty }.count
        if missing > 0 {
            let first = edges.map(\.path)
            let firstPorts = ports
            for (edge, guide) in zip(edges, guides) { edge.path = guide }
            ports = basePorts
            try routePass(reverse: true, channelPaths: channels)
            if edges.filter({ $0.path.isEmpty }).count > missing {
                for (edge, path) in zip(edges, first) { edge.path = path }
                ports = firstPorts
            }
        }
        try separateProximateRuns()
        try polish()
        // Incremental drawings keep their retained routes; only the new ones are improved.
        if configuration.mode != .fresh {
            try refine()
            try improveWorstRoutes()
            try polish()
        }
    }

    /// Makes `occupied` hold every route but `skipped`'s. Within a pass only the route being worked
    /// on changes, so after the pass's first full load this swaps one route in and one out.
    func load(excluding skipped: LayoutEdge?) {
        guard isOccupancyCurrent else {
            occupied.removeAll()
            for edge in edges where edge !== skipped { occupied.insert(edge.path, owner: edgeIndices[required: edge]) }
            isOccupancyCurrent = true
            unindexedEdge = skipped
            return
        }
        guard skipped !== unindexedEdge else { return }
        if let unindexedEdge { occupied.insert(unindexedEdge.path, owner: edgeIndices[required: unindexedEdge]) }
        if let skipped { occupied.remove(owner: edgeIndices[required: skipped]) }
        unindexedEdge = skipped
    }

    /// Routes may change between passes (strategy restores, callers, compaction), so each pass
    /// starts from a full load.
    func beginOccupancyPass() {
        isOccupancyCurrent = false
        unindexedEdge = nil
    }

    func axis(_ direction: Point) -> Int { direction.x != 0 ? 1 : 2 }

    /// A route is accepted only when every stroke clears node bodies and the other nodes' padded obstacles.
    private func validated(_ start: Point, _ middle: [Point], _ end: Point, besides endpoints: Endpoints) -> [Point]? {
        let path = DirectedGeometry.compact([start] + middle + [end])
        guard path.count >= 2,
            zip(path, path.dropFirst()).allSatisfy({ isClear($0, $1, besides: endpoints) }),
            zip(middle, middle.dropFirst()).allSatisfy({ obstacleIndex.clear($0, $1) })
        else { return nil }
        return path
    }

    private func routePass(reverse: Bool, channelPaths: [LayoutEdge: [Point]]) throws {
        retained = []
        beginOccupancyPass()
        occupied.removeAll()
        func record(_ edge: LayoutEdge) { occupied.insert(edge.path, owner: edgeIndices[required: edge]) }
        if configuration.mode != .fresh {
            for edge in edges {
                guard let old = configuration.previousPaths[edgeIndices[required: edge]], old.count >= 2 else {
                    continue
                }
                let (start, end, sd, td) = ports[required: edge]
                // The guard above ensured `old.count >= 2`.
                guard (old[0] - start).length < 0.001, (old.last! - end).length < 0.001 else { continue }
                var path = old
                path[0] = start
                path[path.count - 1] = end
                if sd.x != 0 { path[1].y = start.y } else { path[1].x = start.x }
                if td.x != 0 { path[path.count - 2].y = end.y } else { path[path.count - 2].x = end.x }
                let ends = endpoints(of: edge)
                if zip(path, path.dropFirst()).allSatisfy({ isClear($0, $1, besides: ends) })
                    && pathCost(path).isFinite
                {
                    edge.path = path
                    retained.insert(edge)
                    record(edge)
                }
            }
        }
        var order = edges.sorted {
            let a = abs($0.source.center.x - $0.target.center.x)
            let b = abs($1.source.center.x - $1.target.center.x)
            return a == b ? edgeIndices[required: $0] < edgeIndices[required: $1] : a < b
        }
        if reverse { order.reverse() }
        let trackOrder = edges.sorted {
            let a = ports[required: $0]
            let b = ports[required: $1]
            let ad = a.1.y >= a.0.y
            let bd = b.1.y >= b.0.y
            if ad != bd { return ad }
            let ay = a.0.y + a.1.y
            let by = b.0.y + b.1.y
            if ay == by { return edgeIndices[required: $0] < edgeIndices[required: $1] }
            return ad ? ay > by : ay < by
        }
        let trackIndex = Dictionary(uniqueKeysWithValues: trackOrder.enumerated().map { ($0.element, $0.offset) })
        // The channel plan's tracks are mutually separated by construction, so they are
        // committed first and mark the space occupied; greedy routing then works around them.
        var committed: Set<LayoutEdge> = []
        if coordinated {
            for edge in edges.sorted(by: { edgeIndices[required: $0] < edgeIndices[required: $1] })
            where !retained.contains(edge) {
                guard let guide = channelPaths[edge] else { continue }
                let (start, end, _, _) = ports[required: edge]
                if let path = validated(start, guide, end, besides: endpoints(of: edge)) {
                    edge.path = path
                    committed.insert(edge)
                    record(edge)
                }
            }
        }
        for (position, edge) in order.enumerated() {
            try Task.checkCancellation()
            if position & 31 == 0 { LayoutStageScope.tick(position, of: order.count) }
            if retained.contains(edge) || committed.contains(edge) { continue }
            let base = ports[required: edge]
            let fraction = (Float(trackIndex[required: edge]) + 1) / Float(edges.count + 1)
            var result: [Point]?
            var used = base
            var alternatives: [Ports]?
            levels: for floor in spacingLevels {
                spacing = floor
                result = try attempt(edge, base, guide: channelPaths[edge], fraction: fraction)
                if result != nil { break }
                if alternatives == nil { alternatives = alternatePorts(for: edge) }
                // Assigned on the line above when it was still nil.
                for candidate in alternatives! {
                    if let path = try attempt(edge, candidate, guide: nil, fraction: fraction) {
                        result = path
                        used = candidate
                        break levels
                    }
                }
            }
            spacing = edgeSpacing
            if result != nil { ports[edge] = used }
            edge.path = result ?? []
            record(edge)
        }
    }

    /// Preferred spacing first; the hard stroke floor is used only when nothing else routes.
    private var spacingLevels: [Float] { edgeSpacing > trackClearance ? [edgeSpacing, trackClearance] : [edgeSpacing] }

    /// Candidate shapes, then the exact-coordinate repair, for one edge with fixed ports.
    private func attempt(_ edge: LayoutEdge, _ ports: Ports, guide: [Point]?, fraction: Float) throws -> [Point]? {
        let (start, end, sd, td) = ports
        let escape = start + sd * clearance
        let entry = end + td * clearance
        // Endpoints are never exempted from body validation (including self-loops).
        guard bodyIndex.clear(start, escape), bodyIndex.clear(entry, end) else { return nil }
        let ends = endpoints(of: edge)
        var candidates: [[Point]] = []
        func add(_ middle: [Point]) {
            if let path = validated(start, middle, end, besides: ends) { candidates.append(path) }
        }
        if let guide { add(guide) }
        let guided = candidates.first.flatMap { pathCost($0).isFinite ? $0 : nil }
        let xs = [
            escape.x + (entry.x - escape.x) * (0.2 + fraction * 0.6),
            escape.x + (entry.x - escape.x) * (0.8 - fraction * 0.6),
        ]
        for x in xs { add([escape, Point(x: x, y: escape.y), Point(x: x, y: entry.y), entry]) }
        let ys = [
            escape.y + (entry.y - escape.y) * (0.2 + fraction * 0.6),
            escape.y + (entry.y - escape.y) * (0.8 - fraction * 0.6),
        ]
        for y in ys { add([escape, Point(x: escape.x, y: y), Point(x: entry.x, y: y), entry]) }
        // Feedback and loops get independent exterior lanes; no diagonal loop shortcut.
        if sd.y != 0 || td.y != 0 || candidates.isEmpty {
            for y in exteriorLanes(from: escape, to: entry) {
                add([escape, Point(x: escape.x, y: y), Point(x: entry.x, y: y), entry])
            }
        }
        if !coordinated, let guided { candidates = [guided] }
        var best: [Point]?
        var bestCost = Float.infinity
        for candidate in candidates {
            let cost = pathCost(candidate)
            if cost < bestCost {
                best = candidate
                bestCost = cost
            }
        }
        if best == nil {
            var repaired = try search(from: escape, to: entry, startAxis: axis(sd), endAxis: axis(td))
            if repaired == nil {
                repaired = try search(
                    from: escape,
                    to: entry,
                    startAxis: axis(sd),
                    endAxis: axis(td),
                    occupiedCoordinates: true
                )
            }
            if let repaired {
                add(repaired)
                best = candidates.last.flatMap { pathCost($0).isFinite ? $0 : nil }
            }
        }
        return best
    }

}
