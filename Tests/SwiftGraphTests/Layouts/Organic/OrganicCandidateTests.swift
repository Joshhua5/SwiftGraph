import Foundation
import Testing

@testable import GraphEvaluationSupport
@testable import SwiftGraph

@Suite struct OrganicCandidateTests {
    // MARK: - Candidate count

    @Test func candidateCountFallsWithGraphSize() {
        let expected = [(1, 12), (64, 12), (256, 12), (300, 12), (301, 4), (1_000, 4), (1_001, 2), (10_000, 2)]
        for (nodeCount, count) in expected {
            let plan = OrganicQualitySearch.plan(nodeCount: nodeCount)
            #expect(plan.starts * plan.strengths.count == count, "\(nodeCount) nodes")
        }
    }

    @Test(arguments: [(300, 12), (301, 4), (1_001, 2)])
    func searchSolvesThePlannedCandidates(_ input: (nodeCount: Int, count: Int)) throws {
        let graph = VisualGraphs.graph(input.nodeCount, shape: "tree")
        let snapshot = try GraphCheckpoint(graph).snapshot
        let automatic = try OrganicQualitySearch(snapshot, OrganicLayoutConfiguration())
        #expect(automatic.candidates().count == input.count)
        // The input positions are always the first start, solved at every planned strength.
        let original = snapshot.nodes.map { $0.bounds.center }
        #expect(automatic.candidates().first?.start == original)
        var configuration = OrganicLayoutConfiguration()
        configuration.initialization = .current
        let current = try OrganicQualitySearch(snapshot, configuration)
        #expect(current.candidates().count == OrganicQualitySearch.plan(nodeCount: input.nodeCount).strengths.count)
    }

    // MARK: - Determinism

    @Test(arguments: [24, 65])
    func concurrentSearchMatchesSequentialSearch(_ count: Int) throws {
        let graph = VisualGraphs.graph(count, shape: "dense")
        var configuration = OrganicLayoutConfiguration()
        configuration.iterations = 12
        let snapshot = try GraphCheckpoint(graph).snapshot
        let sequential = try Self.sequentialSearch(snapshot, configuration)
        for _ in 0..<3 {
            let other = VisualGraphs.graph(count, shape: "dense")
            let algorithm = OrganicLayoutAlgorithm()
            algorithm.iterations = 12
            try algorithm.applyLayout(other)
            #expect(other.nodes.map(\.center) == sequential.best)
            #expect(algorithm.lastDiagnostics?.selectedCandidate == sequential.diagnostics.selectedCandidate)
            #expect(algorithm.lastDiagnostics?.final == sequential.diagnostics.final)
            #expect(algorithm.lastDiagnostics?.candidateCount == sequential.diagnostics.candidateCount)
        }
    }

    /// The executor's CPU path runs candidates concurrently too, and must stop at the same candidate.
    @Test func executorSearchMatchesSequentialSearch() async throws {
        var configuration = OrganicLayoutConfiguration()
        configuration.iterations = 40
        let sequential = try Self.sequentialSearch(
            GraphCheckpoint(VisualGraphs.graph(40, shape: "tree")).snapshot,
            configuration
        )
        for _ in 0..<3 {
            let other = VisualGraphs.graph(40, shape: "tree")
            let operation = OrganicLayoutOperation(backend: .cpu, configuration: configuration)
            try await operation.applyLayoutAsync(other)
            #expect(other.nodes.map(\.center) == sequential.best)
            #expect(operation.lastDiagnostics?.candidateCount == sequential.diagnostics.candidateCount)
            #expect(operation.lastDiagnostics?.selectedCandidate == sequential.diagnostics.selectedCandidate)
        }
    }

    /// Solves and adopts candidates one at a time, in order, stopping where the search's rule says.
    private static func sequentialSearch(
        _ snapshot: GeometrySnapshot,
        _ configuration: OrganicLayoutConfiguration
    ) throws -> OrganicQualitySearch {
        var search = try OrganicQualitySearch(snapshot, configuration)
        var scores: [OrganicQualityMeasurements] = []
        for entry in search.candidates() {
            let (input, candidate) = search.candidate(entry.start, strength: entry.strength)
            let evaluation = try search.evaluate(input.cpuOrganic(candidate))
            search.adopt(evaluation)
            scores.append(evaluation.score)
            if OrganicQualitySearch.stopsAfter(scores) { break }
        }
        return search
    }

    // MARK: - Early stop

    @Test func earlyStopComparesSolvedCandidatesOnly() {
        func score(_ violations: Int, _ hits: Int, _ crossings: Int, length: Float = 1) -> OrganicQualityMeasurements {
            OrganicQualityMeasurements(
                clearanceViolations: violations,
                edgeNodeIntersections: hits,
                crossings: crossings,
                edgeLength: length,
                drawingArea: 1
            )
        }
        // The first candidate never stops the search, however good.
        #expect(!OrganicQualitySearch.stopsAfter([score(0, 0, 0)]))
        #expect(!OrganicQualitySearch.stopsAfter([]))
        // Clear, and no worse on either count than the best earlier candidate.
        #expect(OrganicQualitySearch.stopsAfter([score(0, 3, 5), score(0, 3, 5, length: 9)]))
        #expect(OrganicQualitySearch.stopsAfter([score(0, 9, 1), score(0, 2, 7), score(0, 2, 7)]))
        // Worse on either count, or not clear.
        #expect(!OrganicQualitySearch.stopsAfter([score(0, 3, 5), score(0, 4, 1)]))
        #expect(!OrganicQualitySearch.stopsAfter([score(0, 3, 5), score(0, 1, 6)]))
        #expect(!OrganicQualitySearch.stopsAfter([score(2, 3, 5), score(1, 0, 0)]))
        // The best earlier candidate is the best by score, not by either count alone.
        #expect(!OrganicQualitySearch.stopsAfter([score(1, 0, 0), score(0, 5, 5), score(0, 5, 6)]))
    }

    @Test func tiesGoToTheEarlierCandidate() throws {
        let graph = VisualGraphs.graph(4, shape: "chain")
        var search = try OrganicQualitySearch(GraphCheckpoint(graph).snapshot, OrganicLayoutConfiguration())
        let score = OrganicQualityMeasurements(
            clearanceViolations: 0,
            edgeNodeIntersections: 0,
            crossings: 0,
            edgeLength: 1,
            drawingArea: 1
        )
        let first = OrganicQualitySearch.Evaluation(positions: graph.nodes.map { $0.center }, score: score)
        let second = OrganicQualitySearch.Evaluation(positions: graph.nodes.map { $0.center * 2 }, score: score)
        search.adopt(first)
        search.adopt(second)
        #expect(search.diagnostics.selectedCandidate == 1)
        #expect(search.best == first.positions)
    }

    // MARK: - Scoring

    @Test func sweepMeasurementsMatchAllPairs() throws {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func next(_ range: Float) -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) * range
        }
        for trial in 0..<40 {
            let count = 2 + trial * 3
            let graph = VisualGraphs.graph(count, shape: trial.isMultiple(of: 2) ? "dense" : "tree")
            let snapshot = try GraphCheckpoint(graph).snapshot
            // Crowded and sparse spreads, plus coincident nodes.
            let spread: Float = trial.isMultiple(of: 3) ? 80 : 800
            let positions = snapshot.nodes.indices.map { i in
                i.isMultiple(of: 7) ? Point(x: 5, y: 5) : Point(x: next(spread), y: next(spread))
            }
            for separation: Float in [0, 20] {
                let measured = try OrganicQualitySearch.measure(positions, snapshot, separation: separation)
                let reference = Self.allPairs(positions, snapshot, separation: separation)
                #expect(measured == reference, "trial \(trial), separation \(separation)")
            }
        }
    }

    // MARK: - Separation

    @Test func gridPushApartMatchesAllPairs() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ range: Float) -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) * range
        }
        for trial in 0..<30 {
            let count = 2 + trial * 4
            let graph = VisualGraphs.graph(count, shape: trial.isMultiple(of: 2) ? "dense" : "tree")
            // Some trials pin nodes, so fixed-fixed pairs are skipped and fixed-movable pairs push one side only.
            if trial.isMultiple(of: 3) {
                for node in graph.nodes.prefix(count / 4) { node.metadata[GraphMetadataKeys.fixed] = true }
            }
            var configuration = OrganicLayoutConfiguration()
            configuration.nodeSeparation = trial.isMultiple(of: 5) ? 0 : 20
            let search = try OrganicQualitySearch(GraphCheckpoint(graph).snapshot, configuration)
            // Crowded heaps, sparse spreads, coincident nodes and far-flung coordinates.
            let spread: Float = trial.isMultiple(of: 4) ? 60 : (trial.isMultiple(of: 7) ? 40_000 : 600)
            let start = graph.nodes.indices.map { i in
                i.isMultiple(of: 5) ? Point(x: 7, y: 7) : Point(x: next(spread) - spread / 2, y: next(spread))
            }
            for rounds in [1, 4, 32] {
                var grid = start
                var reference = start
                let gridSettled = try search.pushApart(&grid, gap: configuration.nodeSeparation, rounds: rounds)
                let referenceSettled = Self.allPairsPushApart(
                    &reference,
                    search,
                    gap: configuration.nodeSeparation,
                    rounds: rounds
                )
                #expect(gridSettled == referenceSettled, "trial \(trial), rounds \(rounds)")
                #expect(grid == reference, "trial \(trial), rounds \(rounds)")
            }
        }
    }

    /// The separation sweep the grid replaced: every pair, in index order.
    private static func allPairsPushApart(
        _ positions: inout [Point],
        _ search: OrganicQualitySearch,
        gap: Float,
        rounds: Int
    ) -> Bool {
        let fixed = search.fixed
        for _ in 0..<rounds {
            var moved = false
            var bounds = search.rectangles(positions)
            for i in positions.indices {
                for j in positions.indices where j > i && !(fixed[i] && fixed[j]) {
                    guard OrganicQualitySearch.conflict(bounds[i], bounds[j], gap) else { continue }
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
                    moved = true
                }
            }
            if !moved { return true }
        }
        return false
    }

    /// The scoring this suite replaced: every node pair, every edge-node pair and every edge pair.
    private static func allPairs(
        _ positions: [Point],
        _ snapshot: GeometrySnapshot,
        separation: Float
    ) -> OrganicQualityMeasurements {
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
        var length: Float = 0
        for i in rects.indices {
            for j in rects.indices where j > i && OrganicQualitySearch.conflict(rects[i], rects[j], separation) {
                overlaps += 1
            }
        }
        let edges = snapshot.edges.filter { $0.source != $0.target }
        for (index, e) in edges.enumerated() {
            let a = positions[e.source]
            let b = positions[e.target]
            length += (b - a).length
            for i in rects.indices where i != e.source && i != e.target && rects[i].intersectsLine(a, b) { hits += 1 }
            for f in edges[(index + 1)...] {
                guard e.source != f.source && e.source != f.target && e.target != f.source && e.target != f.target
                else {
                    continue
                }
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
        let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        return OrganicQualityMeasurements(
            clearanceViolations: overlaps,
            edgeNodeIntersections: hits,
            crossings: crossings,
            edgeLength: length,
            drawingArea: bounds.width * bounds.height
        )
    }

    // MARK: - Runner

    @Test func runnerReturnsResultsInIndexOrder() throws {
        let values = try OrganicCandidateRunner.map(32, stage: { "Item \($0)" }) { index in
            // Later items finish first.
            Thread.sleep(forTimeInterval: Double(32 - index) * 0.0005)
            return index * index
        }
        #expect(values == (0..<32).map { $0 * $0 })
    }

    /// Callers block their threads while candidates run. With every cooperative thread blocked that way, the candidates
    /// must still get a thread to run on.
    @Test func runnerCompletesWhenEveryCooperativeThreadIsWaiting() async throws {
        let callers = ProcessInfo.processInfo.activeProcessorCount * 2
        let totals = try await withThrowingTaskGroup(of: Int.self) { group in
            for caller in 0..<callers {
                group.addTask {
                    try OrganicCandidateRunner.map(4, stage: { "Item \($0)" }) { index in
                        Thread.sleep(forTimeInterval: 0.01)
                        return caller + index
                    }
                    .reduce(0, +)
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(totals.sorted() == (0..<callers).map { $0 * 4 + 6 })
    }

    @Test func runnerRethrowsTheLowestIndexedFailure() {
        struct Failure: Error, Equatable { let index: Int }
        #expect(throws: Failure(index: 3)) {
            try OrganicCandidateRunner.map(8, stage: { "Item \($0)" }) { index -> Int in
                if index == 3 || index == 6 { throw Failure(index: index) }
                return index
            }
        }
    }

    /// Cancellation is raised only once a worker is known to be running, and workers wait for it with no deadline, so
    /// the outcome does not depend on how quickly a loaded machine schedules either side.
    @Test func runnerForwardsTaskCancellationToWorkers() async throws {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task.detached { () -> Bool in
            do {
                _ = try OrganicCandidateRunner.map(4, stage: { "Item \($0)" }) { _ -> Int in
                    signal.yield()
                    while true { try OrganicCandidateRunner.checkCancellation() }
                }
                return false
            } catch is CancellationError {
                return true
            }
        }
        for await _ in started { break }
        task.cancel()
        #expect(try await task.value)
    }

    @Test func runnerStopsAtTheFirstStoppingIndex() throws {
        for _ in 0..<5 {
            let values = try OrganicCandidateRunner.map(
                12,
                stage: { "Item \($0)" },
                stopsAfter: { $0.reduce(0, +) >= 6 }
            ) { index in
                // Later items finish first, so the stop is found after higher indices have finished.
                Thread.sleep(forTimeInterval: Double(12 - index) * 0.001)
                return index
            }
            #expect(values == [0, 1, 2, 3])
        }
    }

    @Test func runnerCancelsItemsAboveTheStop() throws {
        let values = try OrganicCandidateRunner.map(
            8,
            stage: { "Item \($0)" },
            stopsAfter: { $0.count == 2 }
        ) { index -> Int in
            // Items above the stop never finish on their own.
            while index > 1 { try OrganicCandidateRunner.checkCancellation() }
            return index
        }
        #expect(values == [0, 1])
    }

    @Test func runnerIgnoresFailuresAboveTheStop() throws {
        struct Failure: Error {}
        let values = try OrganicCandidateRunner.map(
            8,
            stage: { "Item \($0)" },
            stopsAfter: { $0.count == 3 }
        ) { index -> Int in
            if index == 5 { throw Failure() }
            Thread.sleep(forTimeInterval: 0.005)
            return index
        }
        #expect(values == [0, 1, 2])
    }
}
