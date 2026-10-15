import Foundation
import Testing
@testable import SwiftGraph

private func compositionMetalFixture() -> LayoutGraph {
    let graph = LayoutGraph()
    for i in 0..<12 {
        let node = LayoutNode(id: "c\(i)", width: 24 + Float(i % 3), height: 16 + Float(i % 4), data: "payload-\(i)")
        node.x = Float(i % 4) * 40; node.y = Float(i / 4) * 30; graph.addNode(node)
    }
    for component in 0..<3 {
        let base = component * 4
        graph.addEdge(LayoutEdge(source: graph.nodes[base], target: graph.nodes[base+1]))
        graph.addEdge(LayoutEdge(source: graph.nodes[base], target: graph.nodes[base+2]))
        graph.addEdge(LayoutEdge(source: graph.nodes[base+2], target: graph.nodes[base+3]))
    }
    return graph
}
private func expectCompositionGeometry(_ actual: LayoutGraph, _ expected: LayoutGraph, tolerance: Float = 0.02) {
    for (a, b) in zip(actual.nodes, expected.nodes) {
        #expect(abs(a.x-b.x) <= tolerance); #expect(abs(a.y-b.y) <= tolerance)
        #expect(abs(a.width-b.width) <= tolerance); #expect(abs(a.height-b.height) <= tolerance)
        #expect(a.data as? String == b.data as? String)
    }
    for (a, b) in zip(actual.edges, expected.edges) {
        #expect(a.sourcePort == b.sourcePort); #expect(a.targetPort == b.targetPort)
        #expect(a.path.count == b.path.count)
        for (ap, bp) in zip(a.path, b.path) { #expect((ap-bp).length <= tolerance*3) }
    }
}
@Test(arguments: [false, true])
func compositionSwimlaneMetalMatchesDefaultAndCorePacking(_ withCore: Bool) async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    let cpu = compositionMetalFixture(), graph = compositionMetalFixture()
    let expected = SwimlaneLayoutOperation(), actual = SwimlaneLayoutOperation(backend: .metal)
    for operation in [expected, actual] {
        operation.laneAssignment = Dictionary(uniqueKeysWithValues: (0..<12).map { ("c\($0)", $0 % 3 - 1) })
        operation.laneWidth = 35 // Mixed widths require effective-width expansion.
        operation.laneInternalPadding = 14; operation.laneSpacing = 17; operation.nodeVerticalSpacing = 23
    }
    if withCore { expected.subLayout = TabularLayoutAlgorithm(); actual.subLayout = BasicLayoutOperation(style: .tabular, backend: .metal) }
    let parents = graph.nodes.map(\.parent)
    try await expected.applyLayoutAsync(cpu)
    try await actual.applyLayoutAsync(graph)
    expectCompositionGeometry(graph, cpu)
    #expect(graph.nodes.map(\.parent) == parents)
    #expect(actual.computedLanes.map(\.laneId) == expected.computedLanes.map(\.laneId))
    for (a, b) in zip(actual.computedLanes, expected.computedLanes) {
        #expect(abs(a.x-b.x)<0.02); #expect(abs(a.width-b.width)<0.02)
    }
    #expect(actual.lastExecutionMetrics.last?.backend == .metal)
    #expect(actual.lastExecutionMetrics.last?.metalStages.contains(withCore ? "lane widths and core packing" : "lane widths, offsets and ranked placement") == true)
}
@Test func compositionMultiPageDefaultHierarchyUsesSelectedBackend() async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    let cpu = compositionMetalFixture(), graph = compositionMetalFixture()
    let expected = MultiPageLayoutOperation(), actual = MultiPageLayoutOperation(backend: .metal)
    try await expected.applyLayoutAsync(cpu); try await actual.applyLayoutAsync(graph)
    expectCompositionGeometry(graph, cpu)
    #expect(actual.lastExecutionMetrics.contains { $0.backend == .metal && !$0.metalStages.isEmpty })
    #expect(actual.lastExecutionMetrics.contains { $0.cpuStages.contains("page packing") })
}
@Test func compositionSubgraphUsesMetalCoreAndCrossBoundaryRouting() async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    let cpu = compositionMetalFixture(), graph = compositionMetalFixture()
    let expected = SubgraphLayoutOperation(TabularLayoutAlgorithm())
    let actual = SubgraphLayoutOperation(BasicLayoutOperation(style: .tabular, backend: .metal), backend: .metal)
    for operation in [expected, actual] { operation.selectedNodeIds = ["c1", "c2", "c3"] }
    let untouched = graph.nodes.enumerated().filter { !actual.selectedNodeIds.contains($0.element.id) }.map { ($0.offset, $0.element.bounds) }
    try await expected.applyLayoutAsync(cpu); try await actual.applyLayoutAsync(graph)
    expectCompositionGeometry(graph, cpu)
    for (i, bounds) in untouched { #expect(graph.nodes[i].bounds == bounds) }
    #expect(actual.lastExecutionMetrics.filter { $0.backend == .metal }.count >= 2)
    #expect(actual.lastExecutionMetrics.contains { $0.cpuStages.contains("centroid preservation and selection clearance") })
}
@Test func compositionSwimlaneAutomaticFallbackAndRollback() async throws {
    var options = MetalLayoutOptions(); options.minimumNodeCount = 0
    let executor = LayoutExecutor(options: options, metalEnabled: false)
    let cpu = compositionMetalFixture(), graph = compositionMetalFixture()
    let expected = SwimlaneLayoutOperation(), actual = SwimlaneLayoutOperation(backend: .automatic, executor: executor)
    try await expected.applyLayoutAsync(cpu); try await actual.applyLayoutAsync(graph)
    expectCompositionGeometry(graph, cpu, tolerance: 0)
    #expect(actual.lastExecutionMetrics.last?.fallbackReason == .metalUnavailable)
    let before = graph.nodes.map(\.bounds), ports = graph.edges.map(\.sourcePort)
    let explicit = SwimlaneLayoutOperation(backend: .metal, executor: executor)
    do { try await explicit.applyLayoutAsync(graph); Issue.record("Expected unavailable Metal error") }
    catch { guard case OrganicLayoutError.metalUnavailable = error else { throw error } }
    #expect(graph.nodes.map(\.bounds) == before); #expect(graph.edges.map(\.sourcePort) == ports)
    #expect(explicit.computedLanes.isEmpty); #expect(explicit.lastExecutionMetrics.isEmpty)
}

@Test(arguments: [false, true])
func compositionSwimlaneNegativeEffectiveWidthPreservesCPUAnnotation(_ withCore: Bool) async throws {
    var options = MetalLayoutOptions(); options.minimumNodeCount = 0
    func fixture() -> LayoutGraph {
        let graph = LayoutGraph(), node = LayoutNode(id: "negative-lane", width: 20, height: 10)
        graph.addNode(node); return graph
    }
    for backend in [LayoutBackend.cpu, .automatic, .metal] {
        if backend == .metal && !LayoutExecutor.isMetalAvailable { continue }
        let cpu = fixture(), graph = fixture()
        let reference = SwimlaneLayoutAlgorithm(), operation = SwimlaneLayoutOperation(backend: backend, executor: LayoutExecutor(options: options))
        reference.laneWidth = -10; reference.laneInternalPadding = -100
        operation.laneWidth = -10; operation.laneInternalPadding = -100
        if withCore { reference.subLayout = TabularLayoutAlgorithm(); operation.subLayout = TabularLayoutAlgorithm() }
        try reference.applyLayout(cpu); try await operation.applyLayoutAsync(graph)
        expectCompositionGeometry(graph, cpu, tolerance: 0)
        #expect(operation.computedLanes.count == reference.computedLanes.count)
        #expect(operation.computedLanes.first?.width == -10)
        #expect(operation.computedLanes.first?.x == reference.computedLanes.first?.x)
        if backend == .metal { #expect(operation.lastExecutionMetrics.last?.backend == .metal) }
    }
}
