import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

/// Thread-safe record of every delivered progress report.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LayoutProgress] = []
    var reports: [LayoutProgress] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ progress: LayoutProgress) { lock.lock(); values.append(progress); lock.unlock() }
    /// An unthrottled sink, so tests observe every stage and tick.
    func sink() -> LayoutProgressSink { LayoutProgressSink(handler: record, minimumInterval: .zero) }
    var stageNames: Set<String> { Set(reports.flatMap(\.stages)) }
    var isMonotonic: Bool { zip(reports, reports.dropFirst()).allSatisfy { $0.fraction <= $1.fraction } }
    /// Exactly one report of 1, and it is the last.
    var endsComplete: Bool { reports.last?.fraction == 1 && reports.filter { $0.fraction == 1 }.count == 1 }
}

@Suite struct LayoutStageScopeTests {
    @Test func withoutListenerStagesAreFree() {
        var evaluated = false
        func name() -> String { evaluated = true; return "Stage" }
        let value = LayoutStageScope.run(name()) { LayoutStageScope.tick(1, of: 2); return 7 }
        #expect(value == 7)
        #expect(!evaluated)
        #expect(LayoutStageScope.current == nil)
    }

    @Test func nestedStagesMapIntoTheirParentSlice() async throws {
        let recorder = ProgressRecorder()
        try await withLayoutProgress(recorder.sink()) {
            LayoutStageScope.run("A", to: 0.5) {
                LayoutStageScope.run("A1", from: 0.5) { LayoutStageScope.tick(1, of: 2) }
            }
            LayoutStageScope.run("B", from: 0.5) { LayoutStageScope.tick(1, of: 4) }
        }
        let reports = recorder.reports
        // A finished child reports its parent again; offers stay below 1 until the run completes.
        #expect(reports.map(\.fraction) == [0, 0.25, 0.375, 0.5, 0.5, 0.5, 0.625, 1.0.nextDown, 1])
        #expect(reports.map(\.stages) == [["A"], ["A", "A1"], ["A", "A1"], ["A", "A1"], ["A"], ["B"], ["B"], ["B"], []])
    }

    @Test func fractionNeverDecreases() async throws {
        let recorder = ProgressRecorder()
        try await withLayoutProgress(recorder.sink()) {
            LayoutStageScope.run("Late", from: 0.6) { LayoutStageScope.tick(1, of: 2) }
            LayoutStageScope.run("Early", to: 0.2) { LayoutStageScope.tick(1, of: 2) }
        }
        #expect(recorder.isMonotonic)
        #expect(recorder.endsComplete)
    }

    @Test func earlyExitSnapsButFailureDoesNotComplete() async throws {
        let recorder = ProgressRecorder()
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            try await withLayoutProgress(recorder.sink()) {
                LayoutStageScope.run("Loop", to: 0.5) { LayoutStageScope.tick(1, of: 10) }
                try LayoutStageScope.run("Throws", from: 0.5) { LayoutStageScope.tick(1, of: 10); throw Failure() }
            }
        }
        let fractions = recorder.reports.map(\.fraction)
        #expect(fractions.contains(0.5))          // "Loop" snapped to its end after one tick
        #expect(fractions.max()! < 0.6)           // "Throws" never snapped
        #expect(!fractions.contains(1))
    }

    @Test func emptyPipelineReportsOnlyCompletion() async throws {
        let recorder = ProgressRecorder()
        try await LayoutBuilder.create(LayoutGraph()).applyAsync(sink: recorder.sink())
        #expect(recorder.reports == [LayoutProgress(stages: [], fraction: 1)])
    }

    @Test func asymptoticTicksStayInsideTheStage() async throws {
        let recorder = ProgressRecorder()
        try await withLayoutProgress(recorder.sink()) {
            LayoutStageScope.run("Open", to: 0.5) { for step in 0..<200 { LayoutStageScope.tick(asymptotic: step, halfLife: 4) } }
        }
        let inside = recorder.reports.dropLast(2).map(\.fraction)
        #expect(inside.allSatisfy { $0 < 0.5 })
        #expect(recorder.isMonotonic)
    }

    @Test func throttlingBoundsDeliveries() async throws {
        let recorder = ProgressRecorder()
        let start = ContinuousClock.now
        try await withLayoutProgress(LayoutProgressSink(handler: recorder.record)) {
            LayoutStageScope.run("Busy") { for i in 0..<200_000 { LayoutStageScope.tick(i, of: 200_000) } }
        }
        let windows = Int(start.duration(to: .now) / .milliseconds(30))
        #expect(recorder.reports.count <= windows + 4)
        #expect(recorder.endsComplete)
    }

    @Test func capturedStageCrossesQueuesAndDetachedTasks() async throws {
        let recorder = ProgressRecorder()
        try await withLayoutProgress(recorder.sink()) {
            let context = LayoutStageScope.capture()
            // `async`, not `sync`: a synchronous dispatch may run on the calling thread and still see the task-local.
            await withCheckedContinuation { done in
                DispatchQueue.global().async { context.bind { LayoutStageScope.run("Queue") {} }; done.resume() }
            }
            await withCheckedContinuation { done in
                DispatchQueue.global().async { LayoutStageScope.run("Unbound") {}; done.resume() }
            }
            try await Task.detached { context.bind { LayoutStageScope.run("Detached") {} } }.value
        }
        #expect(recorder.stageNames == ["Queue", "Detached"])
    }
}

/// One engine or composite exercised through a builder, with stage names it must report on the CPU path.
struct ProgressCase: Sendable, CustomTestStringConvertible {
    let name: String
    var shape = "dag", count = 16, grouped = false
    /// Exact names or prefixes (ending in "/") that must appear on the CPU backend.
    var stages: [String] = []
    let configure: @Sendable (LayoutBuilder, LayoutBackend) -> Void
    var testDescription: String { name }

    func graph() -> LayoutGraph {
        let graph = VisualGraphs.graph(count, shape: shape)
        guard grouped else { return graph }
        // Two sibling groups under the root, the second nested inside the first.
        let outer = LayoutNode(id: "outer", width: 20, height: 20), inner = LayoutNode(id: "inner", width: 20, height: 20)
        outer.isGroup = true; inner.isGroup = true
        let leaves = graph.nodes
        graph.addNode(outer); graph.addNode(inner)
        graph.root.children = [outer] + Array(leaves.dropFirst(6))
        outer.children = [inner] + Array(leaves[3..<6]); inner.parent = outer
        inner.children = Array(leaves.prefix(3))
        for node in outer.children { node.parent = outer }
        for node in inner.children { node.parent = inner }
        return graph
    }

    static let all: [ProgressCase] = [
        ProgressCase(name: "organic quality", shape: "dense", stages: ["Organic", "Candidate 1/", "Force simulation", "Evaluate", "Separate", "Pack", "Measure"]) {
            $0.useOrganic(backend: $1)
        },
        ProgressCase(name: "hierarchical", stages: ["Hierarchical", "Ordering", "Coordinates", "Route edges"]) { $0.useHierarchical(backend: $1) },
        ProgressCase(name: "directed", stages: ["Prepare", "Component 1/", "Candidate 1/", "Hierarchy", "Routing", "Finish"]) {
            $0.useDirected(backend: $1)
        },
        // "Route" is reported from the routing worker's queue, so it proves the progress scope is re-bound there.
        ProgressCase(name: "polyline routing", shape: "dense", stages: ["Routing", "Route", "Separate", "Lanes"]) {
            $0.useHierarchical(backend: $1).routePolyline(backend: $1)
        },
        ProgressCase(name: "channel routing", stages: ["Routing"]) { $0.useHierarchical(backend: $1).routeChannel(backend: $1) },
        ProgressCase(name: "bsp routing", stages: ["Visibility graph", "Route"]) { $0.useHierarchical(backend: $1).routeBsp(backend: $1) },
        ProgressCase(name: "grouped orthogonal routing", stages: ["Route"]) {
            $0.useHierarchical(backend: $1).routeOrthogonalGrouped(backend: $1)
        },
        ProgressCase(name: "edge bundling", shape: "dense", count: 24, stages: ["EdgeBundling", "Bundle", "Repair"]) {
            $0.useOrganic(backend: $1).routeWithBundling(backend: $1)
        },
        ProgressCase(name: "tree", shape: "tree", stages: ["Plan", "Placement"]) { $0.useTree(backend: $1) },
        ProgressCase(name: "radial", shape: "tree", stages: ["Plan", "Clearance", "Apply"]) { $0.useRadial(backend: $1) },
        ProgressCase(name: "circular", stages: ["Plan", "Placement", "Route edges"]) { $0.useCircular(backend: $1) },
        ProgressCase(name: "barycenter", shape: "dense", count: 24, stages: ["Solve", "Separate overlaps"]) { $0.useBarycenter(backend: $1) },
        ProgressCase(name: "page rank and clusters") { $0.analyzePageRank(backend: $1).analyzeClusters(backend: $1) },
        ProgressCase(name: "components", shape: "disconnected", stages: ["Component 1/", "Pack"]) {
            $0.wrapWithComponentHandling(HierarchicalLayoutOperation(backend: $1), backend: $1)
        },
        ProgressCase(name: "recursive groups", grouped: true, stages: ["Group 1/", "Layout", "Route edges"]) {
            $0.wrapWithRecursiveGroups(HierarchicalLayoutOperation(backend: $1), backend: $1)
        },
        ProgressCase(name: "swimlanes", stages: ["Lane 1/"]) { $0.useSwimlane(backend: $1, subLayout: HierarchicalLayoutAlgorithm()) },
        ProgressCase(name: "multi-page", shape: "disconnected", stages: ["Page 1/"]) { $0.useMultiPage(backend: $1) },
    ]
}

@Suite struct LayoutProgressEngineTests {
    static var backends: [LayoutBackend] { LayoutExecutor.isMetalAvailable ? [.cpu, .automatic, .metal] : [.cpu, .automatic] }

    @Test(arguments: ProgressCase.all, backends)
    func progressIsOrderedCompleteAndDoesNotChangeTheLayout(_ test: ProgressCase, backend: LayoutBackend) async throws {
        let plain = test.graph(), observed = test.graph(), recorder = ProgressRecorder()
        let unobserved = LayoutBuilder.create(plain); test.configure(unobserved, backend)
        try await unobserved.applyAsync()
        let builder = LayoutBuilder.create(observed); test.configure(builder, backend)
        try await builder.applyAsync(sink: recorder.sink())

        #expect(recorder.isMonotonic)
        #expect(recorder.endsComplete)
        #expect(recorder.reports.count > 1)
        if backend == .cpu {
            let names = recorder.stageNames
            let missing = test.stages.filter { expected in
                expected.hasSuffix("/") ? !names.contains { $0.hasPrefix(expected) } : !names.contains(expected)
            }
            #expect(missing.isEmpty, "missing \(missing) in \(names.sorted())")
        }
        // Reporting is read-only: geometry must match exactly, not within a tolerance.
        #expect(observed.nodes.map(\.bounds) == plain.nodes.map(\.bounds))
        #expect(observed.edges.map(\.path) == plain.edges.map(\.path))
        #expect(observed.edges.map(\.labelBounds) == plain.edges.map(\.labelBounds))
    }

    @Test func publicHandlerReceivesProgress() async throws {
        let recorder = ProgressRecorder()
        let builder = LayoutBuilder.create(VisualGraphs.graph()).useHierarchical(backend: .cpu).stage("Layered", weight: 2)
        try await builder.applyAsync(progress: recorder.record)
        #expect(recorder.endsComplete)
        #expect(recorder.stageNames.contains("Layered"))
    }

    @Test func cancellingFromTheHandlerLeavesTheGraphUntouched() async throws {
        final class TaskBox: @unchecked Sendable { var task: Task<Bool, any Error>? }
        let box = TaskBox(), recorder = ProgressRecorder()
        let task = Task.detached { () throws -> Bool in
            let graph = VisualGraphs.graph(64, shape: "dense"), before = graph.nodes.map(\.bounds)
            let builder = LayoutBuilder.create(graph).useOrganic(backend: .cpu)
            do {
                try await builder.applyAsync { progress in
                    recorder.record(progress)
                    if progress.fraction > 0.2 { box.task?.cancel() }
                }
                return false
            } catch is CancellationError { return graph.nodes.map(\.bounds) == before }
        }
        box.task = task
        #expect(try await task.value)
        #expect(!recorder.reports.contains { $0.fraction == 1 })
    }

    @Test func endingTheStreamCancelsTheLayout() async throws {
        let graph = VisualGraphs.graph(64, shape: "dense"), before = graph.nodes.map(\.bounds)
        let builder = LayoutBuilder.create(graph).useOrganic(backend: .cpu)
        var received: [LayoutProgress] = []
        for try await progress in builder.layoutProgress() {
            received.append(progress)
            if progress.fraction > 0.1 { break }
        }
        #expect(!received.isEmpty)
        // A completed run would have written new positions by now; a cancelled one never commits.
        try await Task.sleep(for: .seconds(2))
        #expect(graph.nodes.map(\.bounds) == before)
    }

    @Test func streamDeliversCompletionLast() async throws {
        let builder = LayoutBuilder.create(VisualGraphs.graph()).useHierarchical(backend: .cpu)
        var last: LayoutProgress?
        for try await progress in builder.layoutProgress() { last = progress }
        #expect(last?.fraction == 1)
    }
}
