import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

@Suite(.serialized)
@MainActor
struct MetalRoutingTests {
    private func graph() -> LayoutGraph {
        let graph = LayoutGraph()
        for (i, p) in [Point(x: 0, y: 0), Point(x: 300, y: 0), Point(x: 0, y: 180), Point(x: 300, y: 180), Point(x: 145, y: 20)].enumerated() {
            let node = LayoutNode(id: "node-\(i)", width: i == 4 ? 35 : 30, height: 24)
            node.center = p; graph.addNode(node)
        }
        for (i, pair) in [(0, 1), (1, 0), (0, 1), (0, 2), (0, 3), (2, 3), (1, 3), (0, 0), (0, 0)].enumerated() {
            let edge = LayoutEdge(source: graph.nodes[pair.0], target: graph.nodes[pair.1], data: "Label \(i)")
            edge.path = [edge.source.center, Point(x: 80, y: -60), Point(x: 200, y: -60), edge.target.center]
            edge.labelBounds = Rect(x: 0, y: 0, width: 45, height: 20)
            if i == 3 { edge.sourcePort = .bottom; edge.targetPort = .top }
            if i == 4 { edge.sourcePortCandidates = [.right, .bottom]; edge.targetPortCandidates = [.left, .top] }
            graph.addEdge(edge)
        }
        return graph
    }
    private func configured(_ kind: RoutingKind, backend: LayoutBackend, executor: LayoutExecutor = .shared) -> RoutingLayoutOperation {
        RoutingLayoutOperation(kind, backend: backend, executor: executor) { $0.labelIterations = 8 }
    }
    @Test(arguments: RoutingKind.allCases)
    func cpuSnapshotPreservesGeometryPortsPathsLabelsAndHierarchy(_ kind: RoutingKind) async throws {
        let a = graph(), b = graph()
        let operation = configured(kind, backend: .cpu)
        try await operation.applyLayoutAsync(a)
        let c = operation.configuration
        switch kind {
        case .polyline, .givenCoordinates: PolylineEdgeRouter().routeEdges(b)
        case .channel: ChannelEdgeRouter().routeEdges(b)
        case .bus: BusEdgeRouter().routeEdges(b)
        case .octilinear: OctilinearEdgeRouter().routeEdges(b)
        case .bsp: BspEdgeRouter().routeEdges(b)
        case .orthogonalGrouped: OrthogonalGroupedEdgeRouter().routeEdges(b)
        case .parallelEdges: ParallelEdgeRouter().routeEdges(b)
        case .edgeSeparation: EdgeSeparator().routeEdges(b)
        case .selfLoops: SelfLoopRouter().routeEdges(b)
        case .curveFitting: CurveFittingEdgeRouter().routeEdges(b)
        case .endpointClipping: EdgeEndpointClipper.clipToNodeBounds(b)
        case .labelPlacement: LabelPlacementAlgorithm().applyLabelPlacement(b)
        case .labelLayout: let r = LabelLayoutAlgorithm(); r.iterations = c.labelIterations; r.applyLabelLayout(b)
        }
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
        #expect(a.edges.map(\.labelBounds) == b.edges.map(\.labelBounds))
        #expect(a.root.bounds == b.root.bounds)
        #expect(a.nodes.allSatisfy { $0.parent === a.root })
        #expect(operation.lastMetrics?.backend == .cpu)
        #expect(operation.lastMetrics?.metalStages.isEmpty == true)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: RoutingKind.allCases)
    func metalGeometryStagesMatchCPUAndKeepOrdering(_ kind: RoutingKind) async throws {
        let a = graph(), b = graph(), executor = LayoutExecutor()
        let cpu = configured(kind, backend: .cpu), metal = configured(kind, backend: .metal, executor: executor)
        try await cpu.applyLayoutAsync(a); try await metal.applyLayoutAsync(b)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(cpu.unroutableEdgeIndices == metal.unroutableEdgeIndices)
        #expect(a.edges.map(\.labelBounds) == b.edges.map(\.labelBounds))
        for (x, y) in zip(a.edges, b.edges) {
            #expect(x.path.count == y.path.count)
            for (p, q) in zip(x.path, y.path) { #expect((p - q).length < 0.01) }
        }
        #expect(metal.lastMetrics?.backend == .metal)
        #expect(metal.lastMetrics?.gpuSeconds != nil)
        #expect(metal.lastMetrics?.metalStages.isEmpty == false)
        #expect(metal.lastMetrics?.cpuStages.isEmpty == false)
        let stats = await executor.statistics()
        #expect(stats.submittedBatches > 0 && stats.submittedBatches == stats.completedBatches)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: try! loadRoutingFixtures())
    func referenceFixtureContractsIncludeGroupedNudgesAndPorts(_ fixture: RoutingFixture) async throws {
        let a = fixture.graph(), b = fixture.graph()
        let kind: RoutingKind = fixture.router == "grouped" ? .orthogonalGrouped : fixture.router == "channel" ? .channel : fixture.router == "polyline" ? .polyline : .bsp
        let operation = RoutingLayoutOperation(kind, backend: .metal) { configuration in
            switch kind {
            case .channel:
                configuration.gridSize = Int(fixture.config["gridSize"] ?? 20)
                configuration.channelBendPenalty = Int(fixture.config["bendPenalty"] ?? 2)
                configuration.congestionPenalty = Int(fixture.config["congestionPenalty"] ?? 2)
            case .orthogonalGrouped:
                configuration.bundleSpacing = fixture.config["bundleSpacing"] ?? 4
                configuration.obstacleMargin = fixture.config["obstacleMargin"] ?? 10
                configuration.bendPenalty = fixture.config["bendPenalty"] ?? 100
            case .polyline: configuration.padding = fixture.config["padding"] ?? 10
            default: break
            }
        }
        fixture.makeRouter().routeEdges(a)
        try await operation.applyLayoutAsync(b)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds), "\(fixture.name): moved node bounds")
        #expect(a.root.bounds == b.root.bounds)
        #expect(a.edges.map(\.path) == b.edges.map(\.path), "\(fixture.name): route/port ordering")
        if fixture.name == "grouped-bus-nudge-reroute" {
            let wall = try #require(b.nodes.first { $0.id == "wall" })
            #expect(wall.bounds != fixture.graph().nodes.first { $0.id == "wall" }!.bounds)
            #expect(operation.lastMetrics?.backend == .metal)
        }
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: [0.0, 1e-12, -1e-12, 1e-7, -1e-7])
    func tangencyNearCollinearityAndDegenerateBoundsKeepExactDecisions(_ offset: Double) async throws {
        let a = graph(), b = graph()
        for g in [a, b] {
            g.nodes[4].bounds = Rect(x: 120, y: offset, width: 30, height: 30)
            g.nodes[2].width = 0; g.nodes[2].height = 0
            g.edges[0].path = [.zero, Point(x: 100, y: offset), Point(x: 300, y: 0)]
        }
        for kind in [RoutingKind.polyline, .bsp, .edgeSeparation, .selfLoops, .endpointClipping] {
            try await configured(kind, backend: .cpu).applyLayoutAsync(a)
            try await configured(kind, backend: .metal).applyLayoutAsync(b)
            #expect(a.edges.map(\.path) == b.edges.map(\.path), "\(kind) at offset \(offset)")
            #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        }
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: [RoutingKind.polyline, .channel, .bsp, .orthogonalGrouped])
    func temporarySubgraphPreservesExternalHierarchyAndObstacleMembership(_ kind: RoutingKind) async throws {
        let a = AsyncCompositionTests().graph(grouped: true), b = AsyncCompositionTests().graph(grouped: true)
        let ga = subgraph(a, nodes: Array(a.nodes.prefix(2))), gb = subgraph(b, nodes: Array(b.nodes.prefix(2)))
        let parents = gb.nodes.map(\.parent), children = gb.nodes.map(\.children), members = gb.nodes
        let cpu = configured(kind, backend: .cpu), metal = configured(kind, backend: .metal)
        try await cpu.applyLayoutAsync(ga); try await metal.applyLayoutAsync(gb)
        #expect(gb.nodes == members && gb.nodes.map(\.parent) == parents && gb.nodes.map(\.children) == children)
        #expect(ga.edges.map(\.path) == gb.edges.map(\.path))
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(cpu.unroutableEdgeIndices == metal.unroutableEdgeIndices)
        #expect(gb.nodes.count == 2)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func recursiveNestedGroupsAndCrossGroupRoutesMatchCPU() async throws {
        let a = AsyncCompositionTests().graph(grouped: true), b = AsyncCompositionTests().graph(grouped: true)
        let cpu = RecursiveGroupLayoutOperation(HierarchicalLayoutOperation(backend: .cpu), backend: .cpu)
        let executor = LayoutExecutor()
        let metal = RecursiveGroupLayoutOperation(HierarchicalLayoutOperation(backend: .metal, executor: executor), backend: .metal, executor: executor)
        let parents = b.nodes.map(\.parent), children = b.nodes.map(\.children)
        try await cpu.applyLayoutAsync(a); try await metal.applyLayoutAsync(b)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
        #expect(b.nodes.map(\.parent) == parents && b.nodes.map(\.children) == children)
        #expect(metal.lastExecutionMetrics.contains { $0.backend == .metal && !$0.metalStages.isEmpty })
        let stats = await executor.statistics()
        #expect(stats.submittedBatches == stats.completedBatches)
    }
    @Test(arguments: [RoutingKind.channel, .selfLoops, .labelLayout, .givenCoordinates])
    func routingDoesNotEvaluateLabelProvidersOutsidePlacement(_ kind: RoutingKind) async throws {
        let operation = configured(kind, backend: .cpu)
        var calls = 0
        operation.labelProvider = { _ in calls += 1; return "dynamic-\(calls)" }
        try await operation.applyLayoutAsync(graph())
        #expect(calls == 0)
    }
    @Test func automaticUnavailableAndExplicitFailureAreTransactional() async throws {
        let executor = LayoutExecutor(metalEnabled: false), a = graph(), b = graph()
        let automatic = configured(.channel, backend: .automatic, executor: executor)
        automatic.configuration.minimumMetalEdgeCount = 0
        try await automatic.applyLayoutAsync(a); try await configured(.channel, backend: .cpu).applyLayoutAsync(b)
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
        #expect(automatic.lastMetrics?.fallbackReason == .metalUnavailable)
        let explicit = configured(.channel, backend: .metal, executor: executor), paths = a.edges.map(\.path)
        await #expect(throws: OrganicLayoutError.self) { try await explicit.applyLayoutAsync(a) }
        #expect(a.edges.map(\.path) == paths && explicit.lastMetrics == nil)
        let below = configured(.channel, backend: .automatic)
        try await below.applyLayoutAsync(graph())
        #expect(below.lastMetrics?.fallbackReason == .belowThreshold)
    }
    @Test func invalidInputAndExternalEndpointFailBeforeWriteback() async throws {
        let g = graph(), operation = configured(.channel, backend: .cpu), paths = g.edges.map(\.path)
        operation.configuration.gridSize = 0
        await #expect(throws: LayoutExecutionError.self) { try await operation.applyLayoutAsync(g) }
        #expect(g.edges.map(\.path) == paths)
        operation.configuration.gridSize = 20
        g.addEdge(LayoutEdge(source: g.nodes[0], target: LayoutNode(id: "external", width: 5, height: 5)))
        await #expect(throws: LayoutExecutionError.self) { try await operation.applyLayoutAsync(g) }
        #expect(g.edges.dropLast().map(\.path) == paths)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func precisionFallbackAndExactLargeCoordinateCollisionDecisions() async throws {
        let a = graph(), b = graph(), executor = LayoutExecutor()
        a.nodes[1].x = 1e10; b.nodes[1].x = 1e10
        let explicit = configured(.parallelEdges, backend: .metal, executor: executor), before = a.edges.map(\.path)
        await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(a) }
        #expect(a.edges.map(\.path) == before)
        let automatic = configured(.parallelEdges, backend: .automatic, executor: executor)
        automatic.configuration.minimumMetalEdgeCount = 0
        try await automatic.applyLayoutAsync(a); try await configured(.parallelEdges, backend: .cpu).applyLayoutAsync(b)
        #expect(automatic.lastMetrics?.fallbackReason == .precisionLimit && a.edges.map(\.path) == b.edges.map(\.path))
        let c = graph(), d = graph()
        for g in [c, d] { for n in g.nodes { n.center = n.center + Point(x: 1e12, y: -1e12) }; for e in g.edges { e.path = e.path.map { $0 + Point(x: 1e12, y: -1e12) } } }
        try await configured(.endpointClipping, backend: .cpu).applyLayoutAsync(c)
        try await configured(.endpointClipping, backend: .metal).applyLayoutAsync(d)
        #expect(c.edges.map(\.path) == d.edges.map(\.path))
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: [false, true])
    func inFlightCancellationAndStaleEditsDrainWithoutWriteback(_ cancel: Bool) async throws {
        let executor = LayoutExecutor(), g = graph(), operation = configured(.labelLayout, backend: .metal, executor: executor)
        operation.configuration.labelIterations = 2_000
        let task = Task { try await operation.applyLayoutAsync(g) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while await executor.statistics().submittedBatches == 0 {
            if ContinuousClock.now >= deadline { throw LayoutExecutionError.invalidInput("No routing GPU submission") }
            try await Task.sleep(for: .milliseconds(1))
        }
        if cancel { task.cancel() } else { g.edges[0].path = [Point(x: -999, y: -999)] }
        let paths = g.edges.map(\.path), labels = g.edges.map(\.labelBounds), bounds = g.nodes.map(\.bounds)
        if cancel { await #expect(throws: CancellationError.self) { try await task.value } }
        else { await #expect(throws: LayoutExecutionError.staleGraph) { try await task.value } }
        #expect(g.edges.map(\.path) == paths && g.edges.map(\.labelBounds) == labels && g.nodes.map(\.bounds) == bounds)
        #expect(operation.lastMetrics == nil)
        let stats = await executor.statistics()
        #expect(stats.submittedBatches == stats.completedBatches)
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func concurrentJobsReuseResourcesAndCacheReleaseWaitsForIdle() async throws {
        let executor = LayoutExecutor(), a = graph(), b = graph()
        let x = configured(.channel, backend: .metal, executor: executor), y = configured(.polyline, backend: .metal, executor: executor)
        let first = Task { try await x.applyLayoutAsync(a) }
        let second = Task { try await y.applyLayoutAsync(b) }
        try await first.value; try await second.value
        let stats = await executor.statistics()
        #expect(stats.bufferReuses > 0 && stats.submittedBatches == stats.completedBatches)
        await executor.releaseCachedBuffers()
        #expect(await executor.statistics().cachedBufferBytes == 0)
    }
}
