import Foundation
import Testing
@testable import SwiftGraph

private func fixture(_ count: Int = 12) -> LayoutGraph {
    let graph = LayoutGraph()
    for i in 0..<count {
        let n = LayoutNode(id: "\(i)", width: 30 + Double(i % 3), height: 20 + Double(i % 5))
        n.center = Point(x: Double((i * 137 + 11) % 337), y: Double((i * 71 + 23) % 331))
        n.data = "payload-\(i)"; graph.addNode(n)
    }
    for i in 1..<count { graph.addEdge(LayoutEdge(source: graph.nodes[(i - 1) / 2], target: graph.nodes[i])) }
    return graph
}
private func close(_ a: Point, _ b: Point, tolerance: Double = 0.002) -> Bool { (a - b).length < tolerance }

@Test func geometryAndOwnership() {
    let rect = Rect(x: 10, y: 20, width: 30, height: 40)
    #expect(rect.intersectsLine(Point(x: 0, y: 25), Point(x: 100, y: 25)))
    #expect(rect.intersectsLine(Point(x: 0, y: 20), Point(x: 100, y: 20)))
    #expect(!rect.intersectsLine(Point(x: 0, y: 19), Point(x: 100, y: 19)))
    #expect(!rect.intersects(Rect(x: 40, y: 20, width: 30, height: 40)))
    let graph = fixture(), temporary = subgraph(graph, nodes: Array(graph.nodes.prefix(4)))
    #expect(temporary.root.children.count == 4)
    #expect(temporary.nodes.allSatisfy { $0.parent === graph.root })
    #expect(graph.nodes[0] != LayoutNode(id: "0", width: 30, height: 20))
}

@Test(arguments: [OrganicBackend.cpuExact, .cpuBarnesHut])
func cpuBackendsPreserveContracts(_ backend: OrganicBackend) throws {
    let graph = fixture(), sizes = graph.nodes.map { $0.bounds.size }, parents = graph.nodes.map(\.parent)
    let loop = LayoutEdge(source: graph.nodes[0], target: graph.nodes[0]); graph.addEdge(loop)
    loop.path = [Point(x: 99, y: 99)]
    let algorithm = try AcceleratedOrganicLayoutAlgorithm(backend: backend); algorithm.iterations = 12
    try algorithm.applyLayout(graph)
    #expect(graph.nodes.map { $0.bounds.size } == sizes)
    #expect(graph.nodes.map(\.parent) == parents)
    #expect(graph.nodes.enumerated().allSatisfy { $0.element.data as? String == "payload-\($0.offset)" })
    #expect(graph.nodes.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(abs(graph.nodes.map { $0.center.x }.min()!) < 1e-4)
    #expect(abs(graph.nodes.map { $0.center.y }.min()!) < 1e-4)
    #expect(loop.path == [Point(x: 99, y: 99)])
    #expect(algorithm.lastMetrics?.backend == backend)
}

@Test(arguments: [OrganicBackend.cpuExact, .cpuBarnesHut])
func pinsAndSubsetAreExact(_ backend: OrganicBackend) throws {
    let graph = fixture()
    graph.nodes[0].x = 0.123456789012345; graph.nodes[0].y = -10.987654321098765
    graph.nodes[0].metadata[GraphMetadataKeys.fixed] = true
    graph.nodes[1].metadata[GraphMetadataKeys.layoutSubset] = true
    let original = graph.nodes.map(\.bounds)
    let algorithm = try AcceleratedOrganicLayoutAlgorithm(backend: backend); algorithm.scope = .subset; algorithm.iterations = 5
    try algorithm.applyLayout(graph)
    #expect(graph.nodes[1].bounds != original[1])
    for i in graph.nodes.indices where i != 1 { #expect(graph.nodes[i].bounds == original[i]) }
}

@Test func zeroIterationsAndEmptyGraph() throws {
    let graph = fixture(), original = graph.nodes.map(\.bounds)
    let algorithm = try AcceleratedOrganicLayoutAlgorithm(); algorithm.iterations = 0
    try algorithm.applyLayout(graph)
    #expect(graph.nodes.map(\.bounds) == original)
    try algorithm.applyLayout(LayoutGraph())
    #expect(algorithm.lastMetrics?.nodeCount == 0)
}

@Test func deterministicScatterAndPinnedOrigin() throws {
    func atOrigin() -> LayoutGraph {
        let g = fixture()
        for n in g.nodes { n.x = 0; n.y = 0 }
        g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
        return g
    }
    let a = atOrigin(), b = atOrigin(), pinned = a.nodes[0].bounds
    let algorithm = try AcceleratedOrganicLayoutAlgorithm(backend: .cpuExact); algorithm.iterations = 4
    try algorithm.applyLayout(a); try algorithm.applyLayout(b)
    #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
    #expect(a.nodes[0].bounds == pinned)
    #expect(a.nodes.dropFirst().contains { $0.x != 0 || $0.y != 0 })
}

@Test func exactPairAndCutoff() throws {
    let graph = LayoutGraph()
    for x in [0.0, 100.0] { let n = LayoutNode(id: "\(x)", width: 10, height: 10); n.center = Point(x: x, y: 0); graph.addNode(n) }
    var state = try ForceState(graph, scope: .all, scatter: false)
    let parameters = ForceParameters(repulsionSquared: 1_000, attraction: 0)
    let result = try cpuStep(state, parameters: parameters, temperature: 100, theta: nil)
    #expect(abs(result[0].x + 10) < 1e-5); #expect(abs(result[1].x - 110) < 1e-5)
    state.positions[1].x = 501
    #expect(try cpuStep(state, parameters: parameters, temperature: 100, theta: nil) == state.positions)
}

@Test func barnesHutMatchesExactAtSmallTheta() throws {
    let state = try ForceState(fixture(129), scope: .all, scatter: false)
    let parameters = ForceParameters(repulsionSquared: 100, attraction: 0.05)
    let exact = try cpuStep(state, parameters: parameters, temperature: 2, theta: nil)
    let tree = try cpuStep(state, parameters: parameters, temperature: 2, theta: 0.001)
    for (a, b) in zip(exact, tree) { #expect(abs(a.x - b.x) < 1e-3 && abs(a.y - b.y) < 1e-3) }
}

@Test func coincidentNodesStayFinite() throws {
    let graph = fixture(129)
    for n in graph.nodes { n.center = Point(x: -10, y: -20) }
    for backend in [OrganicBackend.cpuExact, .cpuBarnesHut] {
        let algorithm = try AcceleratedOrganicLayoutAlgorithm(backend: backend); algorithm.iterations = 3
        try algorithm.applyLayout(graph)
        #expect(graph.nodes.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }
}

@Test func rejectedInputDoesNotMutateGraph() throws {
    let graph = fixture(), before = graph.nodes.map(\.bounds)
    let algorithm = try AcceleratedOrganicLayoutAlgorithm(); algorithm.repulsionForce = .nan
    #expect(throws: OrganicLayoutError.self) { try algorithm.applyLayout(graph) }
    #expect(graph.nodes.map(\.bounds) == before)
    #expect(algorithm.lastMetrics == nil)
    algorithm.repulsionForce = 2_000; graph.nodes.append(graph.nodes[0])
    #expect(throws: OrganicLayoutError.self) { try algorithm.applyLayout(graph) }
}

@Test func cancelledLayoutDoesNotMutateGraph() async throws {
    try await Task {
        let graph = fixture(), before = graph.nodes.map(\.bounds)
        let algorithm = try AcceleratedOrganicLayoutAlgorithm(backend: .cpuExact)
        withUnsafeCurrentTask { $0?.cancel() }
        #expect(throws: CancellationError.self) { try algorithm.applyLayout(graph) }
        #expect(graph.nodes.map(\.bounds) == before)
    }.value
}

@Test(.enabled(if: AcceleratedOrganicLayoutAlgorithm.isMetalAvailable), arguments: [1, 2, 127, 128, 129, 257])
func metalMatchesExactOneStep(_ count: Int) throws {
    let a = fixture(count), b = fixture(count)
    let cpu = try AcceleratedOrganicLayoutAlgorithm(backend: .cpuExact), gpu = try AcceleratedOrganicLayoutAlgorithm(backend: .metal)
    cpu.iterations = 1; gpu.iterations = 1
    try cpu.applyLayout(a); try gpu.applyLayout(b)
    for (x, y) in zip(a.nodes, b.nodes) { #expect(close(x.center, y.center), "node \(x.id): CPU \(x.center), Metal \(y.center)") }
    #expect(gpu.lastMetrics?.gpuTimeSeconds != nil)
}

@Test(.enabled(if: AcceleratedOrganicLayoutAlgorithm.isMetalAvailable), arguments: [1, 3, 8, 9, 17])
func metalBatchBoundariesAndPinnedPrecision(_ iterations: Int) throws {
    let a = fixture(129), b = fixture(129)
    for g in [a, b] {
        g.nodes[0].x = 0.123456789012345; g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
        for n in g.nodes.dropFirst(3) { n.metadata[GraphMetadataKeys.layoutSubset] = true }
    }
    let pins = Array(b.nodes.prefix(3).map(\.bounds))
    let cpu = try AcceleratedOrganicLayoutAlgorithm(backend: .cpuExact), gpu = try AcceleratedOrganicLayoutAlgorithm(backend: .metal)
    for solver in [cpu, gpu] {
        solver.iterations = iterations; solver.scope = .subset
        solver.repulsionForce = 10; solver.initialTemperature = 1
    }
    try cpu.applyLayout(a); try gpu.applyLayout(b)
    #expect(Array(b.nodes.prefix(3).map(\.bounds)) == pins)
    for (x, y) in zip(a.nodes, b.nodes) { #expect(close(x.center, y.center, tolerance: 0.01)) }
}

@Test(.enabled(if: AcceleratedOrganicLayoutAlgorithm.isMetalAvailable))
func metalOriginAndSelfLoops() throws {
    let a = fixture(129), b = fixture(129)
    for g in [a, b] {
        for n in g.nodes { n.center = Point(x: 12, y: 18) }
        g.addEdge(LayoutEdge(source: g.nodes[0], target: g.nodes[0]))
    }
    let cpu = try AcceleratedOrganicLayoutAlgorithm(backend: .cpuExact), gpu = try AcceleratedOrganicLayoutAlgorithm(backend: .metal)
    cpu.iterations = 1; gpu.iterations = 1
    try cpu.applyLayout(a); try gpu.applyLayout(b)
    for (x, y) in zip(a.nodes, b.nodes) { #expect(close(x.center, y.center)) }
}
