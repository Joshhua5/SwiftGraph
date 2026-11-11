import Foundation

public final class OrganicLayoutAlgorithm: LayoutAlgorithm {
    public typealias OrganicScope = SwiftGraph.OrganicScope
    public let quality: OrganicLayoutQuality
    public var initialization: OrganicInitialization = .automatic
    public var nodeSeparation: Float = 20
    public var scope: OrganicScope = .all
    public var iterations: Float
    public var initialTemperature: Float = 100
    public var repulsionForce: Float
    public var attractionForce: Float = 0.05
    public private(set) var lastDiagnostics: OrganicLayoutDiagnostics?
    var preparedPositions = false

    public init(quality: OrganicLayoutQuality = .quality) {
        self.quality = quality
        iterations = quality == .quality ? 600 : 100
        repulsionForce = quality == .quality ? 100 : 2000
    }

    public func applyLayout(_ graph: LayoutGraph) throws {
        lastDiagnostics = nil
        try OrganicCandidateRunner.checkCancellation()
        if quality == .quality {
            var configuration = OrganicLayoutConfiguration()
            guard iterations.isFinite, iterations >= 0, Double(iterations) < Double(Int.max / 16) else {
                throw LayoutExecutionError.invalidInput("Iterations must be finite and nonnegative.")
            }
            configuration.iterations = Int(ceil(iterations))
            configuration.scope = scope
            configuration.initialization = initialization
            configuration.nodeSeparation = nodeSeparation
            configuration.initialTemperature = initialTemperature
            configuration.repulsionForce = repulsionForce
            configuration.attractionForce = attractionForce
            try configuration.validate()
            let checkpoint = try GraphCheckpoint(graph)
            var search = try OrganicQualitySearch(checkpoint.snapshot, configuration)
            if configuration.iterations > 0 && search.fixed.contains(false) {
                let candidates = search.candidates()
                let plan = search
                let evaluations = try OrganicCandidateRunner.map(
                    candidates.count,
                    stage: { "Candidate \($0 + 1)/\(candidates.count)" },
                    stopsAfter: { OrganicQualitySearch.stopsAfter($0.map(\.score)) }
                ) { index in
                    let (input, candidate) = plan.candidate(
                        candidates[index].start,
                        strength: candidates[index].strength
                    )
                    let positions = try LayoutStageScope.run("Force simulation", to: 0.85) {
                        try input.cpuOrganic(candidate)
                    }
                    return try LayoutStageScope.run("Evaluate", from: 0.85) { try plan.evaluate(positions) }
                }
                for evaluation in evaluations { search.adopt(evaluation) }
            }
            try OrganicCandidateRunner.checkCancellation()
            for i in graph.nodes.indices where !search.fixed[i] && configuration.iterations > 0 {
                graph.nodes[i].center = search.best[i]
            }
            lastDiagnostics = search.diagnostics
            return
        }
        let a = Adjacency(graph)
        let nodes = a.nodes
        guard !nodes.isEmpty, iterations > 0, iterations.isFinite else { return }
        let fixed = nodes.map {
            ($0.metadata[GraphMetadataKeys.fixed] as? Bool == true)
                || (scope == .subset && $0.metadata[GraphMetadataKeys.layoutSubset] as? Bool != true)
        }
        var positions = nodes.map(\.center)
        var random = SeededRandom()
        if !preparedPositions && nodes.allSatisfy({ $0.x == 0 && $0.y == 0 }) {
            for i in nodes.indices where !fixed[i] {
                positions[i] = Point(
                    x: Float(random.next() * 1000) + nodes[i].width / 2,
                    y: Float(random.next() * 1000) + nodes[i].height / 2
                )
            }
        }
        // `positions` maps `nodes`, which the guard above leaves non-empty.
        let minX = positions.map(\.x).min()!
        let maxX = positions.map(\.x).max()!
        let minY = positions.map(\.y).min()!
        let maxY = positions.map(\.y).max()!
        let origin = Point(x: minX + (maxX - minX) / 2, y: minY + (maxY - minY) / 2)
        positions = positions.map { $0 - origin }
        let tree = ForceQuadTree()
        let repulsionSquared = repulsionForce * repulsionForce
        let totalIterations = Int(ceil(iterations))
        let treeStride = (preparedPositions && totalIterations >= 60) ? 15 : 1
        for iteration in 0..<totalIterations {
            try OrganicCandidateRunner.checkCancellation()
            LayoutStageScope.tick(iteration, of: totalIterations)
            var displacement = Array(repeating: Point.zero, count: nodes.count)
            if nodes.count >= 64 {
                if iteration % treeStride == 0 { tree.build(positions) }
                for i in nodes.indices where !fixed[i] {
                    displacement[i] = tree.computeForce(
                        nodeIndex: i,
                        position: positions[i],
                        repulsionSquared: repulsionSquared
                    )
                }
            } else {
                for i in nodes.indices where !fixed[i] {
                    for j in nodes.indices where i != j {
                        var delta = positions[i] - positions[j]
                        var squared = delta.lengthSquared
                        if squared < 0.01 {
                            let sign: Float = i > j ? 0.1 : -0.1
                            delta = Point(x: sign, y: sign)
                            squared = 0.02
                        }
                        if squared <= 250_000 {
                            displacement[i] = displacement[i] + delta * (repulsionSquared / squared)
                        }
                    }
                }
            }
            for i in nodes.indices where !fixed[i] {
                for j in a.neighbors[i] {
                    displacement[i] = displacement[i] + (positions[j] - positions[i]) * attractionForce
                }
            }
            let temperature = max(0, initialTemperature * (1 - Float(iteration) / iterations))
            for i in nodes.indices where !fixed[i] {
                let length = displacement[i].length
                if length > 0.1 { positions[i] = positions[i] + displacement[i] * (min(length, temperature) / length) }
            }
        }
        try OrganicCandidateRunner.checkCancellation()
        if fixed.contains(true) {
            for i in nodes.indices where !fixed[i] { nodes[i].center = positions[i] + origin }
        } else {
            // `positions` maps the non-empty `nodes`, so both minima have a value.
            let outMinX = positions.map(\.x).min()!
            let outMinY = positions.map(\.y).min()!
            for i in nodes.indices where !fixed[i] {
                nodes[i].center = Point(x: positions[i].x - outMinX, y: positions[i].y - outMinY)
            }
        }
    }
}
