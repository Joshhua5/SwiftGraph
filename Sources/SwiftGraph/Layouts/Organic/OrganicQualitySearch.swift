import Foundation

/// Backend-independent candidate preparation, rectangle separation, packing and scoring.
struct OrganicQualitySearch {
    let snapshot: GeometrySnapshot
    let configuration: OrganicLayoutConfiguration
    let fixed: [Bool]
    let components: [[Int]]
    var best: [Point]
    var diagnostics: OrganicLayoutDiagnostics

    init(_ snapshot: GeometrySnapshot, _ configuration: OrganicLayoutConfiguration) throws {
        self.snapshot = snapshot
        self.configuration = configuration
        fixed = snapshot.nodes.map { $0.fixed || (configuration.scope == .subset && !$0.selected) }
        components = Self.components(snapshot)
        best = snapshot.nodes.map { $0.bounds.center }
        let initial = try Self.measure(best, snapshot, separation: configuration.nodeSeparation)
        let bounds = snapshot.nodes.map(\.bounds)
        var conflicts: [[Int]] = []
        for i in bounds.indices where fixed[i] {
            for j in bounds.indices where j > i && fixed[j] {
                if Self.conflict(bounds[i], bounds[j], configuration.nodeSeparation) { conflicts.append([i, j]) }
            }
        }
        diagnostics = OrganicLayoutDiagnostics(
            candidateCount: 1,
            selectedCandidate: 0,
            solverIterations: 0,
            fixedConflicts: conflicts,
            initial: initial,
            final: initial
        )
    }

    func starts() -> [[Point]] {
        let original = snapshot.nodes.map { $0.bounds.center }
        guard configuration.initialization == .automatic else { return [original] }
        let anchors = original.indices.filter { fixed[$0] }
        let center =
            anchors.isEmpty ? Point.zero : anchors.reduce(Point.zero) { $0 + original[$1] } / Float(anchors.count)
        let area = snapshot.nodes.reduce(Float(0)) {
            $0 + ($1.bounds.width + configuration.nodeSeparation) * ($1.bounds.height + configuration.nodeSeparation)
        }
        let side = max(100, sqrt(area) * 2)
        return [original]
            + (42...44)
            .map { seed in
                var random = SeededRandom(state: UInt64(seed))
                var positions = original
                for i in positions.indices where !fixed[i] {
                    positions[i] =
                        center + Point(x: Float(random.next() - 0.5) * side, y: Float(random.next() - 0.5) * side)
                }
                return positions
            }
    }

    /// One force solve: a start and a multiple of the nominal repulsion.
    struct Candidate: Sendable {
        var start: [Point]
        var strength: Float
    }

    /// Repulsion multiples solved from each start.
    static let strengths: [Float] = [0.5, 1.0, 2.0]
    /// Graphs up to this many nodes solve every start at every strength: 12 candidates.
    static let fullSearchNodeLimit = 300
    /// Graphs up to this many nodes solve the input and the first seeded start at half and nominal strength: 4
    /// candidates. Larger graphs solve only the input start at those strengths: 2 candidates.
    static let reducedSearchNodeLimit = 1_000

    /// The starts and strengths solved for a graph of `nodeCount` nodes. Every candidate is a full force solve followed
    /// by quadratic cleanup, so the count falls as the graph grows. Starts are taken in order, so the input positions
    /// are always solved. On dense and tree graphs of 512 to 2,048 nodes, double strength never scored best and the
    /// input start won all but one comparison, so those are what large graphs keep.
    static func plan(nodeCount: Int) -> (starts: Int, strengths: [Float]) {
        if nodeCount <= fullSearchNodeLimit { return (4, strengths) }
        let reduced = Array(strengths.prefix(2))
        if nodeCount <= reducedSearchNodeLimit { return (2, reduced) }
        return (1, reduced)
    }

    /// The candidates to solve, in the order that breaks score ties.
    func candidates() -> [Candidate] {
        let plan = Self.plan(nodeCount: snapshot.nodes.count)
        return starts()
            .prefix(plan.starts)
            .flatMap { start in
                plan.strengths.map { Candidate(start: start, strength: $0) }
            }
    }

    func candidate(_ positions: [Point], strength: Float) -> (GeometrySnapshot, OrganicLayoutConfiguration) {
        var input = snapshot
        for i in input.nodes.indices {
            let r = input.nodes[i].bounds
            input.nodes[i].bounds = Rect(
                x: positions[i].x - r.width / 2,
                y: positions[i].y - r.height / 2,
                width: r.width,
                height: r.height
            )
        }
        var c = OrganicLayoutConfiguration(quality: .legacy)
        c.scope = configuration.scope
        c.iterations = configuration.iterations
        c.initialTemperature = configuration.initialTemperature
        c.repulsionForce = configuration.repulsionForce * strength
        c.attractionForce = configuration.attractionForce
        c.preparedPositions = true
        return (input, c)
    }

    /// A cleaned-up candidate and its score.
    struct Evaluation: Sendable {
        var positions: [Point]
        var score: OrganicQualityMeasurements
    }

    /// Cleans up and scores one solved candidate. It reads only `self`, so candidates can be evaluated concurrently.
    func evaluate(_ raw: [Point]) throws -> Evaluation {
        try OrganicCandidateRunner.checkCancellation()
        guard raw.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw LayoutExecutionError.invalidInput("Non-finite organic candidate.")
        }
        var positions = raw
        // Preserve exact coordinates for fixed pins.
        for i in positions.indices where fixed[i] { positions[i] = snapshot.nodes[i].bounds.center }
        LayoutStageScope.run("Compact", to: 0.2) { compact(&positions) }
        try LayoutStageScope.run("Separate", from: 0.2, to: 0.6) { try separate(&positions) }
        try LayoutStageScope.run("Pack", from: 0.6, to: 0.8) { try pack(&positions) }
        if !fixed.contains(true), let first = rectangles(positions).first {
            let bounds = rectangles(positions).dropFirst().reduce(first) { $0.union($1) }
            positions = positions.map { $0 - Point(x: bounds.x, y: bounds.y) }
        }
        let score = try LayoutStageScope.run("Measure", from: 0.8) {
            try Self.measure(positions, snapshot, separation: configuration.nodeSeparation)
        }
        return Evaluation(positions: positions, score: score)
    }

    /// Records an evaluated candidate. Candidates must be adopted in candidate order: a later one replaces the best only
    /// when it scores strictly better, so ties go to the earlier candidate however the candidates were scheduled.
    mutating func adopt(_ evaluation: Evaluation) {
        let index = diagnostics.candidateCount
        diagnostics.candidateCount += 1
        diagnostics.solverIterations += configuration.iterations
        if evaluation.score.precedes(diagnostics.final) {
            best = evaluation.positions
            diagnostics.final = evaluation.score
            diagnostics.selectedCandidate = index
        }
    }

    mutating func consider(_ raw: [Point]) throws {
        adopt(try evaluate(raw))
    }

    /// Whether the search stops after the last of `scores`, the candidates solved so far in candidate order: the last
    /// one has no clearance violations, and no more edge-node intersections and no more crossings than the best
    /// earlier solved candidate. The two counts are the ones the score ranks first after clearance.
    ///
    /// The input positions are left out of the comparison and the first candidate never stops the search. Input
    /// positions are often arbitrary, so the first solve nearly always beats them: comparing against them stopped
    /// after the first candidate on 12 of 13 probe graphs and missed the full search's choice on 8.
    static func stopsAfter(_ scores: [OrganicQualityMeasurements]) -> Bool {
        guard let last = scores.last, last.clearanceViolations == 0, let first = scores.first, scores.count > 1 else {
            return false
        }
        let best = scores.dropFirst().dropLast().reduce(first) { $1.precedes($0) ? $1 : $0 }
        return last.edgeNodeIntersections <= best.edgeNodeIntersections && last.crossings <= best.crossings
    }

    func rectangles(_ positions: [Point]) -> [Rect] {
        zip(positions, snapshot.nodes)
            .map { p, node in
                Rect(
                    x: p.x - node.bounds.width / 2,
                    y: p.y - node.bounds.height / 2,
                    width: node.bounds.width,
                    height: node.bounds.height
                )
            }
    }

    static func conflict(_ a: Rect, _ b: Rect, _ gap: Float) -> Bool {
        // A tiny tolerance prevents floating-point boundary contact from becoming a conflict.
        a.inflated(by: max(0, gap - 1e-4)).intersects(b)
    }

    /// Movable nodes are spread outward by this factor when pairwise pushing alone cannot clear the overlaps.
    static let separationExpansion: Float = 1.5

    /// Most expansions before falling back to per-node placement (1.5⁶ ≈ 11× the original spread).
    static let maximumSeparationExpansions = 6

    func separate(_ positions: inout [Point]) throws {
        let gap = configuration.nodeSeparation
        // Pairwise pushing clears a nearly converged layout in a few rounds, but a barely-iterated layout can arrive
        // here as one dense heap: each push shoves its pair into their neighbours, and the heap barely spreads (285
        // overlapping pairs fall only to 93 after 129 rounds on a 129-node tree). Spreading the movable nodes outward
        // from their centre keeps the arrangement but lowers the density until pushing converges. The first batch of
        // rounds runs unchanged, so layouts that already converged are untouched.
        let movable = positions.indices.filter { !fixed[$0] }
        for expansion in 0...Self.maximumSeparationExpansions {
            if expansion > 0 {
                guard !movable.isEmpty else { break }
                let centre = movable.reduce(Point.zero) { $0 + positions[$1] } / Float(movable.count)
                for i in movable { positions[i] = centre + (positions[i] - centre) * Self.separationExpansion }
            }
            if try pushApart(&positions, gap: gap, rounds: 32) { return }
        }
        // A finite placement fallback: fixed nodes first, then each movable node in stable order.
        var occupied = rectangles(positions).enumerated().filter { fixed[$0.offset] }.map(\.element)
        for i in positions.indices where !fixed[i] {
            try OrganicCandidateRunner.checkCancellation()
            let r = rectangles([positions[i]], nodes: [snapshot.nodes[i]])[0]
            let offset = try Self.nearestPlacement(r, obstacles: occupied, gap: gap)
            positions[i] = positions[i] + offset
            occupied.append(r.translated(by: offset))
        }
    }

    /// Up to `rounds` sweeps that push every conflicting pair apart along its shallower axis. Returns `true` once a
    /// sweep moves nothing, i.e. no pair conflicts.
    ///
    /// A sweep visits pairs `(i, j)`, `i < j`, in that order, testing each against the bounds as moved by the pushes
    /// before it. Only pushed pairs move anything, so for each `i` the next pair pushed is the lowest `j` above the last
    /// one that conflicts with `i` right now. The grid finds that `j` among `i`'s neighbours instead of testing every
    /// `j`, and is updated after each push, so the pushes, their order and their arithmetic match an all-pairs sweep.
    func pushApart(_ positions: inout [Point], gap: Float, rounds: Int) throws -> Bool {
        let inflation = max(0, gap - 1e-4)
        let cellSize = snapshot.nodes.reduce(Float(0)) { max($0, $1.bounds.width, $1.bounds.height) } + 2 * gap
        for _ in 0..<rounds {
            try OrganicCandidateRunner.checkCancellation()
            var moved = false
            var bounds = rectangles(positions)
            var grid = RectangleGrid(bounds, cellSize: cellSize)
            for i in positions.indices {
                var after = i
                while true {
                    var next: Int?
                    grid.forEachCandidate(near: bounds[i].inflated(by: inflation)) { j in
                        guard j > after, j < next ?? .max, !(fixed[i] && fixed[j]) else { return }
                        if Self.conflict(bounds[i], bounds[j], gap) { next = j }
                    }
                    guard let j = next else { break }
                    let dx = (bounds[i].width + bounds[j].width) / 2 + gap - abs(positions[i].x - positions[j].x)
                    let dy = (bounds[i].height + bounds[j].height) / 2 + gap - abs(positions[i].y - positions[j].y)
                    let shift =
                        dx <= dy
                        ? Point(x: (positions[i].x <= positions[j].x ? -1 : 1) * (dx + 1e-4))
                        : Point(y: (positions[i].y <= positions[j].y ? -1 : 1) * (dy + 1e-4))
                    let left: Float = fixed[i] ? 0.0 : (fixed[j] ? 1.0 : 0.5)
                    let right: Float = fixed[j] ? 0.0 : (fixed[i] ? 1.0 : 0.5)
                    positions[i] = positions[i] + shift * left
                    bounds[i] = bounds[i].translated(by: shift * left)
                    positions[j] = positions[j] - shift * right
                    bounds[j] = bounds[j].translated(by: shift * -right)
                    grid.move(i, to: bounds[i])
                    grid.move(j, to: bounds[j])
                    moved = true
                    after = j
                }
            }
            if !moved { return true }
        }
        return false
    }

    private func rectangles(_ positions: [Point], nodes: [GeometrySnapshot.Node]) -> [Rect] {
        zip(positions, nodes)
            .map { p, n in
                Rect(
                    x: p.x - n.bounds.width / 2,
                    y: p.y - n.bounds.height / 2,
                    width: n.bounds.width,
                    height: n.bounds.height
                )
            }
    }

    static func nearestPlacement(_ rect: Rect, obstacles: [Rect], gap: Float) throws -> Point {
        guard obstacles.contains(where: { conflict(rect, $0, gap) }) else { return .zero }
        guard let offset = try nearestClearOffset(rect, avoiding: obstacles.map { $0.inflated(by: gap + 1e-4) }) else {
            throw LayoutExecutionError.invalidInput("Organic placement exceeded finite coordinates.")
        }
        return offset
    }

    /// Force magnitudes determine the arrangement, not the final world-coordinate scale.
    /// Normalize unanchored components to their measured node sizes before rectangle separation.
    func compact(_ positions: inout [Point]) {
        for component in components where component.count > 1 && !component.contains(where: { fixed[$0] }) {
            let members = Set(component)
            let edges = snapshot.edges.filter {
                $0.source != $0.target && members.contains($0.source) && members.contains($0.target)
            }
            guard !edges.isEmpty else { continue }
            let lengths = edges.map { (positions[$0.source] - positions[$0.target]).length }.sorted()
            let targets =
                edges.map { e in
                    let a = snapshot.nodes[e.source].bounds
                    let b = snapshot.nodes[e.target].bounds
                    return hypot(a.width, a.height) / 2 + hypot(b.width, b.height) / 2 + configuration.nodeSeparation
                }
                .sorted()
            let median = lengths[lengths.count / 2]
            guard median > 1e-6 else { continue }
            let scale = min(1, 2.5 * targets[targets.count / 2] / median)
            let center = component.reduce(Point.zero) { $0 + positions[$1] } / Float(component.count)
            for i in component { positions[i] = center + (positions[i] - center) * scale }
        }
    }

    func pack(_ positions: inout [Point]) throws {
        guard components.count > 1 else { return }
        let rects = rectangles(positions)
        let bounds = components.map { c in c.dropFirst().reduce(rects[c[0]]) { $0.union(rects[$1]) } }
        let anchored = components.indices.filter { c in components[c].contains { fixed[$0] } }
        let free = components.indices.filter { !anchored.contains($0) }
            .sorted {
                bounds[$0].height == bounds[$1].height ? $0 < $1 : bounds[$0].height > bounds[$1].height
            }
        var occupied = anchored.map { bounds[$0] }
        let gap = configuration.nodeSeparation
        let anchorBounds = occupied.dropFirst().reduce(occupied.first ?? Rect()) { $0.union($1) }
        let origin = anchored.isEmpty ? Point.zero : Point(x: anchorBounds.x, y: anchorBounds.bottom + gap)
        let rowWidth = max(
            anchored.isEmpty ? 200 : anchorBounds.width,
            sqrt(bounds.reduce(Float(0)) { $0 + ($1.width + gap) * ($1.height + gap) })
        )
        var x: Float = 0.0
        var y: Float = 0.0
        var rowHeight: Float = 0.0
        for c in free {
            try OrganicCandidateRunner.checkCancellation()
            let r = bounds[c]
            if x > 0 && x + r.width > rowWidth {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            let shelf = Point(x: origin.x + x - r.x, y: origin.y + y - r.y)
            x += r.width + gap
            rowHeight = max(rowHeight, r.height)
            let delta =
                anchored.isEmpty
                ? shelf : shelf + (try Self.nearestPlacement(r.translated(by: shelf), obstacles: occupied, gap: gap))
            for i in components[c] { positions[i] = positions[i] + delta }
            occupied.append(r.translated(by: delta))
        }
    }

    static func components(_ snapshot: GeometrySnapshot) -> [[Int]] {
        var adjacent = Array(repeating: [Int](), count: snapshot.nodes.count)
        for e in snapshot.edges {
            adjacent[e.source].append(e.target)
            adjacent[e.target].append(e.source)
        }
        var seen = Set<Int>()
        var result: [[Int]] = []
        for i in snapshot.nodes.indices where seen.insert(i).inserted {
            var queue = [i]
            var cursor = 0
            while cursor < queue.count {
                let n = queue[cursor]
                cursor += 1
                for next in adjacent[n] where seen.insert(next).inserted { queue.append(next) }
            }
            result.append(queue.sorted())
        }
        return result
    }

    static func measure(
        _ positions: [Point],
        _ snapshot: GeometrySnapshot,
        separation: Float
    ) throws -> OrganicQualityMeasurements {
        let rects = zip(positions, snapshot.nodes)
            .map { p, n in
                Rect(
                    x: p.x - n.bounds.width / 2,
                    y: p.y - n.bounds.height / 2,
                    width: n.bounds.width,
                    height: n.bounds.height
                )
            }
        var overlaps = 0
        var hits = 0
        var crossings = 0
        var length: Float = 0.0
        // Pairs are found by sort-and-sweep along x, so only pairs whose x-extents (nearly) overlap are tested. Each
        // tested pair runs the same predicate, in the same argument order, as an all-pairs scan, so the counts match
        // it. Sweep bounds are widened by a rounding margin; the exact predicate decides every pair that is reached.
        func margin(_ value: Float) -> Float { abs(value) * 1e-5 + 1e-3 }
        let byLeft = rects.indices.sorted {
            rects[$0].left == rects[$1].left ? $0 < $1 : rects[$0].left < rects[$1].left
        }
        for (rank, i) in byLeft.enumerated() {
            if rank % 32 == 0 { try OrganicCandidateRunner.checkCancellation() }
            let reach = rects[i].right + max(0, separation)
            for j in byLeft[(rank + 1)...] {
                guard rects[j].left <= reach + margin(reach) else { break }
                if conflict(rects[min(i, j)], rects[max(i, j)], separation) { overlaps += 1 }
            }
        }
        let edges = snapshot.edges.filter { $0.source != $0.target }
        let edgeBounds = edges.map { e -> (minX: Float, maxX: Float, minY: Float, maxY: Float) in
            let a = positions[e.source]
            let b = positions[e.target]
            return (min(a.x, b.x), max(a.x, b.x), min(a.y, b.y), max(a.y, b.y))
        }
        // A rectangle can reach an edge's box only if its left side lies in [minX - widest, maxX].
        let lefts = byLeft.map { rects[$0].left }
        let widest = rects.map(\.width).max() ?? 0
        func firstRank(withLeftAtLeast value: Float) -> Int {
            var low = 0
            var high = lefts.count
            while low < high {
                let middle = (low + high) / 2
                if lefts[middle] < value { low = middle + 1 } else { high = middle }
            }
            return low
        }
        for (index, e) in edges.enumerated() {
            if index % 32 == 0 { try OrganicCandidateRunner.checkCancellation() }
            let a = positions[e.source]
            let b = positions[e.target]
            let eb = edgeBounds[index]
            length += (b - a).length
            let lowest = eb.minX - widest
            for i in byLeft[firstRank(withLeftAtLeast: lowest - margin(lowest))...] {
                let r = rects[i]
                guard r.left <= eb.maxX else { break }
                guard i != e.source && i != e.target else { continue }
                guard eb.maxX >= r.left && eb.minX <= r.right && eb.maxY >= r.top && eb.minY <= r.bottom else {
                    continue
                }
                if r.intersectsLine(a, b) { hits += 1 }
            }
        }
        let byMinX = edges.indices.sorted {
            edgeBounds[$0].minX == edgeBounds[$1].minX ? $0 < $1 : edgeBounds[$0].minX < edgeBounds[$1].minX
        }
        for (rank, first) in byMinX.enumerated() {
            if rank % 32 == 0 { try OrganicCandidateRunner.checkCancellation() }
            for second in byMinX[(rank + 1)...] {
                guard edgeBounds[second].minX <= edgeBounds[first].maxX else { break }
                let index = min(first, second)
                let otherIndex = max(first, second)
                let eb = edgeBounds[index]
                let fb = edgeBounds[otherIndex]
                guard eb.maxX >= fb.minX && eb.minX <= fb.maxX && eb.maxY >= fb.minY && eb.minY <= fb.maxY else {
                    continue
                }
                let e = edges[index]
                let f = edges[otherIndex]
                guard e.source != f.source && e.source != f.target && e.target != f.source && e.target != f.target
                else { continue }
                let a = positions[e.source]
                let b = positions[e.target]
                let c = positions[f.source]
                let d = positions[f.target]
                let u = b - a
                let v = d - c
                let denominator = u.x * v.y - u.y * v.x
                guard abs(denominator) > 1e-6 else { continue }
                let w = c - a
                let t = (w.x * v.y - w.y * v.x) / denominator
                let s = (w.x * u.y - w.y * u.x) / denominator
                if t > 1e-5 && t < 1 - 1e-5 && s > 1e-5 && s < 1 - 1e-5 { crossings += 1 }
            }
        }
        let bounds = rects.first.map { first in rects.dropFirst().reduce(first) { $0.union($1) } } ?? Rect()
        guard length.isFinite, (bounds.width * bounds.height).isFinite else {
            throw LayoutExecutionError.invalidInput("Organic quality measurements overflowed.")
        }
        return OrganicQualityMeasurements(
            clearanceViolations: overlaps,
            edgeNodeIntersections: hits,
            crossings: crossings,
            edgeLength: length,
            drawingArea: bounds.width * bounds.height
        )
    }
}
