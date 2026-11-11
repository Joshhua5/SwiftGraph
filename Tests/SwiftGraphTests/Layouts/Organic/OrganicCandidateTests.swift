import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

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
        var sequential = try OrganicQualitySearch(snapshot, configuration)
        for entry in sequential.candidates() {
            let (input, candidate) = sequential.candidate(entry.start, strength: entry.strength)
            try sequential.consider(input.cpuOrganic(candidate))
        }
        for _ in 0..<3 {
            let other = VisualGraphs.graph(count, shape: "dense")
            let algorithm = OrganicLayoutAlgorithm()
            algorithm.iterations = 12
            try algorithm.applyLayout(other)
            #expect(other.nodes.map(\.center) == sequential.best)
            #expect(algorithm.lastDiagnostics?.selectedCandidate == sequential.diagnostics.selectedCandidate)
            #expect(algorithm.lastDiagnostics?.final == sequential.diagnostics.final)
        }
    }

    @Test func tiesGoToTheEarlierCandidate() throws {
        let graph = VisualGraphs.graph(4, shape: "chain")
        var search = try OrganicQualitySearch(GraphCheckpoint(graph).snapshot, OrganicLayoutConfiguration())
        let score = OrganicQualityMeasurements(clearanceViolations: 0, edgeNodeIntersections: 0, crossings: 0,
                                               edgeLength: 1, drawingArea: 1)
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
            state = state &* 6364136223846793005 &+ 1442695040888963407
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

    /// The scoring this suite replaced: every node pair, every edge-node pair and every edge pair.
    private static func allPairs(
        _ positions: [Point],
        _ snapshot: GeometrySnapshot,
        separation: Float
    ) -> OrganicQualityMeasurements {
        let rects = zip(positions, snapshot.nodes).map { p, n in
            Rect(x: p.x - n.bounds.width / 2, y: p.y - n.bounds.height / 2, width: n.bounds.width, height: n.bounds.height)
        }
        var overlaps = 0, hits = 0, crossings = 0, length: Float = 0
        for i in rects.indices {
            for j in rects.indices where j > i && OrganicQualitySearch.conflict(rects[i], rects[j], separation) {
                overlaps += 1
            }
        }
        let edges = snapshot.edges.filter { $0.source != $0.target }
        for (index, e) in edges.enumerated() {
            let a = positions[e.source], b = positions[e.target]
            length += (b - a).length
            for i in rects.indices where i != e.source && i != e.target && rects[i].intersectsLine(a, b) { hits += 1 }
            for f in edges[(index + 1)...] {
                guard e.source != f.source && e.source != f.target && e.target != f.source && e.target != f.target else {
                    continue
                }
                let c = positions[f.source], d = positions[f.target], u = b - a, v = d - c
                let denominator = u.x * v.y - u.y * v.x
                guard abs(denominator) > 1e-6 else { continue }
                let w = c - a
                let t = (w.x * v.y - w.y * v.x) / denominator, s = (w.x * u.y - w.y * u.x) / denominator
                if t > 1e-5 && t < 1 - 1e-5 && s > 1e-5 && s < 1 - 1e-5 { crossings += 1 }
            }
        }
        let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        return OrganicQualityMeasurements(clearanceViolations: overlaps, edgeNodeIntersections: hits, crossings: crossings,
                                          edgeLength: length, drawingArea: bounds.width * bounds.height)
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

    @Test func runnerForwardsTaskCancellationToWorkers() async throws {
        let task = Task.detached { () -> Bool in
            let start = ContinuousClock.now
            do {
                _ = try OrganicCandidateRunner.map(4, stage: { "Item \($0)" }) { _ -> Int in
                    // Gives up after five seconds, so a missed cancellation fails rather than hangs.
                    while start.duration(to: .now) < .seconds(5) {
                        try OrganicCandidateRunner.checkCancellation()
                    }
                    return 0
                }
                return false
            } catch is CancellationError {
                return start.duration(to: .now) < .seconds(4)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(try await task.value)
    }
}
