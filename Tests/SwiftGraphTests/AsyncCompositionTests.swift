import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct AsyncCompositionTests {
    func graph(grouped: Bool = false) -> LayoutGraph {
        let graph = LayoutGraph()
        for i in 0..<8 {
            let node = LayoutNode(id: "n\(i)", width: 20 + Double(i), height: 15)
            node.center = Point(x: Double(i * 50), y: Double(i % 3 * 80))
            node.data = "payload"; graph.addNode(node)
        }
        for i in [1, 2, 3, 5, 6, 7] { graph.addEdge(LayoutEdge(source: graph.nodes[i - 1], target: graph.nodes[i])) }
        if grouped {
            let outer = LayoutNode(id: "outer", width: 20, height: 20), inner = LayoutNode(id: "inner", width: 20, height: 20)
            outer.isGroup = true; inner.isGroup = true
            let leaves = graph.nodes
            graph.addNode(outer); graph.addNode(inner)
            graph.root.children = [outer] + Array(leaves.suffix(4))
            outer.children = [inner, leaves[2], leaves[3]]; inner.parent = outer
            inner.children = Array(leaves.prefix(2))
            for node in outer.children { node.parent = outer }
            for node in inner.children { node.parent = inner }
            graph.addEdge(LayoutEdge(source: leaves[1], target: leaves[5]))
        }
        for edge in graph.edges {
            edge.path = [edge.source.center, edge.target.center]
            edge.labelBounds = Rect(x: 1, y: 2, width: 3, height: 4)
            edge.sourcePortCandidates = [.left, .right]
        }
        return graph
    }

    func expectSame(_ a: LayoutGraph, _ b: LayoutGraph) {
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
        #expect(a.edges.map(\.labelBounds) == b.edges.map(\.labelBounds))
        #expect(a.edges.map(\.sourcePort) == b.edges.map(\.sourcePort))
        #expect(a.edges.map(\.targetPort) == b.edges.map(\.targetPort))
    }

    @Test(arguments: ["component", "group", "subgraph", "page", "lane"])
    func asyncCompositionMatchesSynchronousGeometry(_ kind: String) async throws {
        let a = graph(grouped: kind == "group"), b = graph(grouped: kind == "group")
        let parents = b.nodes.map(\.parent), children = b.nodes.map(\.children), identities = b.nodes
        switch kind {
        case "component":
            try ComponentLayout(HierarchicalLayoutAlgorithm()).applyLayout(a)
            try await ComponentLayoutOperation(HierarchicalLayoutAlgorithm()).applyLayoutAsync(b)
        case "group":
            try RecursiveGroupLayout(HierarchicalLayoutAlgorithm()).applyLayout(a)
            try await RecursiveGroupLayoutOperation(HierarchicalLayoutAlgorithm()).applyLayoutAsync(b)
        case "subgraph":
            let sync = SubgraphLayoutAlgorithm(HierarchicalLayoutAlgorithm()), async = SubgraphLayoutOperation(HierarchicalLayoutAlgorithm())
            sync.selectedNodeIds = ["n0", "n1", "n2"]; async.selectedNodeIds = sync.selectedNodeIds
            try sync.applyLayout(a); try await async.applyLayoutAsync(b)
        case "page":
            try MultiPageLayoutAlgorithm(HierarchicalLayoutAlgorithm()).applyLayout(a)
            try await MultiPageLayoutOperation(HierarchicalLayoutAlgorithm()).applyLayoutAsync(b)
        default:
            let sync = SwimlaneLayoutAlgorithm(), async = SwimlaneLayoutOperation()
            sync.subLayout = HierarchicalLayoutAlgorithm(); async.subLayout = HierarchicalLayoutAlgorithm()
            try sync.applyLayout(a); try await async.applyLayoutAsync(b)
            #expect(sync.computedLanes.map(\.width) == async.computedLanes.map(\.width))
        }
        expectSame(a, b)
        #expect(b.nodes == identities && b.nodes.map(\.parent) == parents && b.nodes.map(\.children) == children)
        #expect(b.nodes.prefix(8).allSatisfy { $0.data as? String == "payload" })
    }

    final class SuspendedCore: AsyncLayoutAlgorithm {
        var suspended = false
        var continuation: CheckedContinuation<Void, Never>?
        func applyLayoutAsync(_ graph: LayoutGraph) async throws {
            for node in graph.nodes { node.x += 400 }
            straightEdges(graph)
            if !suspended {
                suspended = true
                await withCheckedContinuation { continuation = $0 }
            }
            try Task.checkCancellation()
        }
        func resume() { continuation?.resume(); continuation = nil }
    }

    @Test(arguments: ["cancel", "bounds", "route", "port", "label", "hierarchy", "root", "payload"],
          ["component", "group", "subgraph", "page", "lane"])
    func suspendedCompositionIsAtomic(_ edit: String, _ kind: String) async throws {
        let graph = graph(grouped: kind == "group"), core = SuspendedCore(), before = graph.nodes.map(\.bounds)
        let originalPaths = graph.edges.map(\.path)
        let operation: any AsyncLayoutAlgorithm
        switch kind {
        case "group": operation = RecursiveGroupLayoutOperation(core)
        case "page": operation = MultiPageLayoutOperation(core)
        case "subgraph":
            let selected = SubgraphLayoutOperation(core); selected.selectedNodeIds = ["n0", "n1", "n2"]
            operation = selected
        case "lane":
            let lanes = SwimlaneLayoutOperation(); lanes.subLayout = core; operation = lanes
        default: operation = ComponentLayoutOperation(core)
        }
        let task = Task { try await operation.applyLayoutAsync(graph) }
        while !core.suspended { await Task.yield() }
        #expect(graph.nodes.map(\.bounds) == before && graph.edges.map(\.path) == originalPaths)
        switch edit {
        case "cancel": task.cancel()
        case "bounds": graph.nodes[0].x += 7
        case "route": graph.edges[0].path = [.zero]
        case "port": graph.edges[0].sourcePortCandidates = [.top]
        case "label": graph.edges[0].labelBounds.x += 9
        case "hierarchy": graph.nodes[0].isGroup = true
        case "root": graph.root.x = 42
        default: graph.nodes[0].data = "edited"; graph.nodes[0].metadata["custom"] = "preserved"
        }
        let edited = graph.nodes.map(\.bounds), paths = graph.edges.map(\.path)
        core.resume()
        if edit == "cancel" { await #expect(throws: CancellationError.self) { try await task.value } }
        else if edit == "payload" {
            try await task.value
            #expect(graph.nodes[0].data as? String == "edited")
            #expect(graph.nodes[0].metadata["custom"] as? String == "preserved")
            return
        } else { await #expect(throws: LayoutExecutionError.staleGraph) { try await task.value } }
        #expect(graph.nodes.map(\.bounds) == edited && graph.edges.map(\.path) == paths)
    }

    final class FailingCore: AsyncLayoutAlgorithm {
        var count = 0
        func applyLayoutAsync(_ graph: LayoutGraph) async throws {
            count += 1
            graph.nodes[0].x = 12345
            if count == 2 { throw LayoutExecutionError.invalidInput("second component failed") }
        }
    }
    @Test func laterChildFailureDoesNotCommitEarlierChild() async throws {
        let graph = graph(), before = graph.nodes.map(\.bounds)
        await #expect(throws: LayoutExecutionError.self) {
            try await ComponentLayoutOperation(FailingCore()).applyLayoutAsync(graph)
        }
        #expect(graph.nodes.map(\.bounds) == before)
    }

    @Test func recursiveCycleIsRejectedWithoutMutation() async throws {
        let graph = graph(grouped: true), before = graph.nodes.map(\.bounds)
        let outer = graph.nodes[8], inner = graph.nodes[9]
        inner.children.append(outer)
        defer { inner.children.removeLast() }
        await #expect(throws: GraphError.cyclicGroupHierarchy) {
            try await RecursiveGroupLayoutOperation(HierarchicalLayoutAlgorithm()).applyLayoutAsync(graph)
        }
        #expect(graph.nodes.map(\.bounds) == before)
    }

    @Test(arguments: ["standard", "progressive", "hybrid", "network", "social", "large", "dense", "bundle"])
    func backendPresetsPreserveCPUBehavior(_ kind: String) async throws {
        let a = graph(), b = graph()
        let first = LayoutBuilder.create(a), second = LayoutBuilder.create(b)
        switch kind {
        case "standard": first.applyStandardOrganic(iterations: 2); second.applyStandardOrganic(backend: .cpu, iterations: 2)
        case "progressive": first.applyProgressiveRefinement(organicIterations: 2); second.applyProgressiveRefinement(backend: .cpu, organicIterations: 2)
        case "hybrid": first.applyHybridLayout(organicIterations: 2); second.applyHybridLayout(backend: .cpu, organicIterations: 2)
        case "network": first.applyNetworkTopology(organicIterations: 2); second.applyNetworkTopology(backend: .cpu, organicIterations: 2)
        case "social": first.applySocialNetwork(organicIterations: 2); second.applySocialNetwork(backend: .cpu, organicIterations: 2)
        case "large": first.applyPattern(.largeGraphPreset); second.applyPattern(.largeGraphPreset, backend: .cpu)
        case "dense": first.applyPattern(.denseGraphPreset); second.applyPattern(.denseGraphPreset, backend: .cpu)
        default: first.applyWithEdgeBundling(); second.applyWithEdgeBundling(backend: .cpu)
        }
        try await first.applyAsync(); try await second.applyAsync()
        expectSame(a, b)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func groupedMetalUsesChildSizesAndRoutesAfterCommit() async throws {
        let graph = graph(grouped: true)
        var options = MetalLayoutOptions(); options.minimumNodeCount = 3; options.minimumIterations = 0
        let executor = LayoutExecutor(options: options)
        let organic = OrganicLayoutOperation(backend: .automatic, executor: executor)
        organic.configuration.iterations = 2
        let builder = LayoutBuilder.create(graph).wrapWithFullComposition(organic).routePolyline().routeSelfLoops()
        try await builder.applyAsync()
        #expect(!builder.lastExecutionMetrics.isEmpty)
        for record in builder.lastExecutionMetrics {
            if record.nodeCount < 3 { #expect(record.backend == .cpu && record.fallbackReason == .belowThreshold) }
            else { #expect(record.backend == .metal) }
        }
        #expect(graph.edges.allSatisfy { $0.path.count >= 2 })
        #expect(graph.nodes.map(\.bounds).allSatisfy { $0.x.isFinite && $0.y.isFinite })
        // Separately prove explicit Metal is reachable through the grouped preset.
        let explicit = self.graph(grouped: true)
        try await LayoutBuilder.create(explicit).applyStandardOrganic(backend: .metal, executor: executor, iterations: 2).applyAsync()
        let statistics = await executor.statistics()
        #expect(statistics.submittedBatches > 0 && statistics.submittedBatches == statistics.completedBatches)
    }

    @Test func builderReportsEachChildAndResetsBetweenRuns() async throws {
        let g = graph(), operation = OrganicLayoutOperation(backend: .cpu)
        operation.configuration.iterations = 2
        let builder = LayoutBuilder.create(g).wrapWithComponentHandling(operation).useBarycenter(backend: .cpu)
            .routeWithBundling(backend: .cpu)
        try await builder.applyAsync()
        #expect(builder.lastExecutionMetrics.count == 4)
        #expect(builder.lastExecutionMetrics.map(\.nodeCount) == [4, 4, 8, 8])
        try await builder.applyAsync()
        #expect(builder.lastExecutionMetrics.count == 4)
        operation.configuration.iterations = -1
        await #expect(throws: LayoutExecutionError.self) { try await builder.applyAsync() }
        #expect(builder.lastExecutionMetrics.isEmpty)
    }
}
