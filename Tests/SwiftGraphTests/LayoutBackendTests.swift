import Foundation
import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct LayoutBackendTests {
    func graph(_ count: Int = 129, origin: Double = 0) -> LayoutGraph {
        let g = LayoutGraph()
        for i in 0..<count {
            let n = LayoutNode(id: String(i), width: 20 + Double(i % 3), height: 10)
            n.center = Point(x: origin + Double((i * 137 + 29) % 997), y: origin + Double((i * 263 + 47) % 991))
            n.data = "payload"; g.addNode(n)
        }
        for i in 1..<count { g.addEdge(LayoutEdge(source: g.nodes[(i - 1) / 2], target: g.nodes[i])) }
        return g
    }
    func configuration(_ iterations: Int = 3) -> OrganicLayoutConfiguration {
        var c = OrganicLayoutConfiguration(); c.iterations = iterations; return c
    }

    @Test func asyncCPUIsTheExistingImplementation() async throws {
        let a = graph(), b = graph()
        a.nodes[0].metadata[GraphMetadataKeys.fixed] = true
        b.nodes[0].metadata[GraphMetadataKeys.fixed] = true
        let cpu = OrganicLayoutAlgorithm(); cpu.iterations = 3; try cpu.applyLayout(a)
        let operation = OrganicLayoutOperation(backend: .cpu, configuration: configuration())
        try await operation.applyLayoutAsync(b)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(operation.lastMetrics?.backend == .cpu)
        #expect(operation.lastMetrics?.fallbackReason == nil)
        #expect(b.nodes.allSatisfy { $0.data as? String == "payload" && $0.parent === b.root })
    }

    @Test func builderAwaitsTheAsyncWitness() async throws {
        final class AsyncProbe: LayoutAlgorithm {
            func applyLayout(_ graph: LayoutGraph) throws { Issue.record("Builder called blocking method") }
            func applyLayoutAsync(_ graph: LayoutGraph) async throws {
                await Task.yield(); graph.nodes[0].x = 321
            }
        }
        let g = graph(2)
        try await LayoutBuilder.create(g).useAlgorithm(AsyncProbe()).transform { g in #expect(g.nodes[0].x == 321) }.applyAsync()
        try await LayoutBuilder.create(g).useOrganic(backend: .cpu) { $0.iterations = 2 }
            .transform { g in #expect(g.nodes.allSatisfy { $0.x.isFinite }) }.routeSelfLoops().applyAsync()
    }

    @Test func selectionAndUnavailableHardwareAreExplicit() async throws {
        let g = graph(2), before = g.nodes.map(\.bounds)
        let small = OrganicLayoutOperation(backend: .automatic, configuration: configuration())
        try await small.applyLayoutAsync(g)
        #expect(small.lastMetrics?.fallbackReason == .belowThreshold)
        var options = MetalLayoutOptions(); options.minimumNodeCount = 0; options.minimumIterations = 0
        let executor = LayoutExecutor(options: options, metalEnabled: false)
        let automatic = OrganicLayoutOperation(backend: .automatic, executor: executor, configuration: configuration())
        try await automatic.applyLayoutAsync(g)
        #expect(automatic.lastMetrics?.backend == .cpu)
        #expect(automatic.lastMetrics?.fallbackReason == .metalUnavailable)
        let explicit = OrganicLayoutOperation(backend: .metal, executor: executor, configuration: configuration())
        let unchanged = g.nodes.map(\.bounds)
        await #expect(throws: OrganicLayoutError.self) { try await explicit.applyLayoutAsync(g) }
        #expect(g.nodes.map(\.bounds) == unchanged)
        #expect(g.nodes.map(\.bounds) != before)
    }

    @Test func zeroIterationsAndInvalidInputAreTransactional() async throws {
        let g = graph(), before = g.nodes.map(\.bounds)
        let operation = OrganicLayoutOperation(backend: .metal, executor: LayoutExecutor(metalEnabled: false), configuration: configuration(0))
        try await operation.applyLayoutAsync(g)
        #expect(g.nodes.map(\.bounds) == before)
        #expect(operation.lastMetrics?.fallbackReason == .noWork)
        operation.configuration.iterations = -1
        await #expect(throws: LayoutExecutionError.self) { try await operation.applyLayoutAsync(g) }
        #expect(operation.lastMetrics == nil)
        #expect(g.nodes.map(\.bounds) == before)
        operation.configuration.iterations = 1; g.nodes.append(g.nodes[0])
        await #expect(throws: LayoutExecutionError.self) { try await operation.applyLayoutAsync(g) }
    }

    @Test func checkpointDetectsRelevantEdits() throws {
        let g = graph(3), checkpoint = try GraphCheckpoint(g)
        g.nodes[0].data = "changed payload"
        #expect(checkpoint.matches(g))
        g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
        #expect(!checkpoint.matches(g))
        g.nodes[0].metadata.removeValue(forKey: GraphMetadataKeys.fixed)
        #expect(checkpoint.matches(g))
        g.nodes.swapAt(0, 1)
        #expect(!checkpoint.matches(g))
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func metalPipelinePreservesPinsAndReusesResources() async throws {
        let executor = LayoutExecutor()
        let operation = OrganicLayoutOperation(backend: .metal, executor: executor, configuration: configuration())
        let g = graph(), before = g.nodes.map(\.bounds)
        operation.configuration.scope = .subset
        for n in g.nodes.dropFirst(3) { n.metadata[GraphMetadataKeys.layoutSubset] = true }
        g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
        let edgePaths = g.edges.map(\.path)
        try await LayoutBuilder.create(g).useAsyncAlgorithm(operation).transform { graph in
            #expect(Array(graph.nodes.prefix(3).map(\.bounds)) == Array(before.prefix(3)))
            #expect(graph.nodes[3].bounds != before[3])
        }.applyAsync()
        #expect(g.edges.map(\.path) == edgePaths)
        #expect(operation.lastMetrics?.backend == .metal)
        #expect(operation.lastMetrics?.gpuSeconds != nil)
        let first = await executor.statistics()
        try await operation.applyLayoutAsync(g)
        let second = await executor.statistics()
        #expect(first.pipelineBuilds == 1 && second.pipelineBuilds == 1)
        #expect(first.bufferAllocations == second.bufferAllocations)
        #expect(second.bufferReuses >= first.bufferReuses + 5)
        #expect(second.submittedBatches == second.completedBatches)
        await executor.releaseCachedBuffers()
        #expect(await executor.statistics().cachedBufferBytes == 0)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func localOriginPreservesSmallDistancesAtLargeOffsets() async throws {
        let a = graph(17), b = graph(17, origin: 1e12)
        for g in [a, b] { g.nodes[0].metadata[GraphMetadataKeys.fixed] = true }
        let originalPin = b.nodes[0].bounds
        let executor = LayoutExecutor(), c = configuration(1)
        try await OrganicLayoutOperation(backend: .metal, executor: executor, configuration: c).applyLayoutAsync(a)
        try await OrganicLayoutOperation(backend: .metal, executor: executor, configuration: c).applyLayoutAsync(b)
        #expect(b.nodes[0].bounds == originalPin)
        for i in a.nodes.indices {
            let translated = b.nodes[i].center - Point(x: 1e12, y: 1e12)
            #expect((translated - a.nodes[i].center).length < 0.001)
        }
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func precisionFallbackDoesNotSilentlyChangeExplicitMetal() async throws {
        let g = graph(2)
        g.nodes[1].x = 1e10
        let before = g.nodes.map(\.bounds)
        var options = MetalLayoutOptions(); options.minimumNodeCount = 0; options.minimumIterations = 0
        let executor = LayoutExecutor(options: options)
        let explicit = OrganicLayoutOperation(backend: .metal, executor: executor, configuration: configuration(1))
        await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(g) }
        #expect(g.nodes.map(\.bounds) == before)
        #expect(await executor.statistics().submittedBatches == 0)
        let automatic = OrganicLayoutOperation(backend: .automatic, executor: executor, configuration: configuration(1))
        try await automatic.applyLayoutAsync(g)
        #expect(automatic.lastMetrics?.backend == .cpu)
        #expect(automatic.lastMetrics?.fallbackReason == .precisionLimit)
        #expect(await executor.statistics().submittedBatches == 0)
        let reference = graph(2); reference.nodes[1].x = 1e10
        try await OrganicLayoutOperation(backend: .cpu, configuration: configuration(1)).applyLayoutAsync(reference)
        #expect(g.nodes.map(\.bounds) == reference.nodes.map(\.bounds))
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func automaticSelectionRunsTheWholeQualitySearchOnMetal() async throws {
        var options = MetalLayoutOptions(); options.minimumNodeCount = 0; options.minimumIterations = 0
        let executor = LayoutExecutor(options: options), a = graph(65), b = graph(65)
        let automatic = OrganicLayoutOperation(backend: .automatic, executor: executor, configuration: configuration())
        let explicit = OrganicLayoutOperation(backend: .metal, executor: executor, configuration: configuration())
        try await automatic.applyLayoutAsync(a)
        try await explicit.applyLayoutAsync(b)
        #expect(automatic.lastMetrics?.backend == .metal)
        #expect(automatic.lastMetrics?.fallbackReason == nil)
        #expect(automatic.lastDiagnostics?.candidateCount == 13)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(automatic.lastDiagnostics?.final == explicit.lastDiagnostics?.final)
    }

    func awaitSubmission(_ executor: LayoutExecutor) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await executor.statistics().submittedBatches == 0 {
            if ContinuousClock.now >= deadline { throw LayoutExecutionError.invalidInput("Timed out waiting for GPU submission") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func cancellationAfterSubmissionDrainsResourcesWithoutWriteback() async throws {
        var options = MetalLayoutOptions(); options.iterationsPerBatch = 1
        let executor = LayoutExecutor(options: options), g = graph(129), before = g.nodes.map(\.bounds)
        var c = configuration(4_000); c.initialTemperature = 0.1
        let operation = OrganicLayoutOperation(backend: .metal, executor: executor, configuration: c)
        let task = Task { try await operation.applyLayoutAsync(g) }
        defer { task.cancel() }
        try await awaitSubmission(executor)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(g.nodes.map(\.bounds) == before)
        #expect(operation.lastMetrics == nil)
        let stats = await executor.statistics()
        #expect(stats.submittedBatches == stats.completedBatches)
        #expect(stats.cachedBufferBytes > 0)
        #expect(stats.submittedBatches < 4_000)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func editsDuringSuspensionRejectStaleResults() async throws {
        var options = MetalLayoutOptions(); options.iterationsPerBatch = 1
        let executor = LayoutExecutor(options: options), g = graph(129)
        // Small temperature keeps the conservative Float movement bound within tolerance.
        var c = configuration(300); c.initialTemperature = 0.1
        let operation = OrganicLayoutOperation(backend: .metal, executor: executor, configuration: c)
        let task = Task { try await operation.applyLayoutAsync(g) }
        defer { task.cancel() }
        try await awaitSubmission(executor)
        g.nodes[0].x += 50
        let edited = g.nodes.map(\.bounds)
        await #expect(throws: LayoutExecutionError.staleGraph) { try await task.value }
        #expect(g.nodes.map(\.bounds) == edited)
        #expect(operation.lastMetrics == nil)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func concurrentRequestsNeverShareInFlightBuffers() async throws {
        let executor = LayoutExecutor(), a = graph(129), b = graph(257)
        let referenceA = graph(129), referenceB = graph(257), c = configuration(9)
        try await OrganicLayoutOperation(backend: .metal, executor: executor, configuration: c).applyLayoutAsync(referenceA)
        try await OrganicLayoutOperation(backend: .metal, executor: executor, configuration: c).applyLayoutAsync(referenceB)
        let first = Task { try await OrganicLayoutOperation(backend: .metal, executor: executor, configuration: c).applyLayoutAsync(a) }
        let second = Task { try await OrganicLayoutOperation(backend: .metal, executor: executor, configuration: c).applyLayoutAsync(b) }
        try await first.value; try await second.value
        #expect(a.nodes.map(\.bounds) == referenceA.nodes.map(\.bounds))
        #expect(b.nodes.map(\.bounds) == referenceB.nodes.map(\.bounds))
        let stats = await executor.statistics()
        #expect(stats.submittedBatches == stats.completedBatches)
    }
}
