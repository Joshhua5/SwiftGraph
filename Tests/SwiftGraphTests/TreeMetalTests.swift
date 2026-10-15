import Foundation
import Testing
@testable import SwiftGraph

private func treeMetalFixture(_ count: Int = 11, cyclic: Bool = false, origin: Float = 0) -> LayoutGraph {
    let graph = LayoutGraph()
    for i in 0..<count {
        let node = LayoutNode(id: "tree-\(i)", width: 20 + Float(i % 4), height: 14 + Float(i % 3), data: i == 2 ? "Assistant" : "value-\(i)")
        node.x = origin + Float(i) * 2; node.y = origin + Float(i) * 3; graph.addNode(node)
    }
    for i in 1..<max(1, count - 2) { graph.addEdge(LayoutEdge(source: graph.nodes[(i - 1) / 2], target: graph.nodes[i])) }
    if cyclic, count > 3 { graph.addEdge(LayoutEdge(source: graph.nodes[3], target: graph.nodes[0])) }
    if count > 0 {
        let loop = LayoutEdge(source: graph.nodes[0], target: graph.nodes[0]); loop.path = [Point(x: 71, y: 72)]; graph.addEdge(loop)
    }
    return graph
}
private func expectTreeMetalGeometry(_ actual: LayoutGraph, _ expected: LayoutGraph, tolerance: Float = 0.01) {
    for (a, b) in zip(actual.nodes + [actual.root], expected.nodes + [expected.root]) {
        #expect(abs(a.x - b.x) <= tolerance)
        #expect(abs(a.y - b.y) <= tolerance)
        #expect(abs(a.width - b.width) <= tolerance)
        #expect(abs(a.height - b.height) <= tolerance)
        #expect(a.data as? String == b.data as? String)
    }
    for (a, b) in zip(actual.edges, expected.edges) {
        #expect(a.path.count == b.path.count)
        for (ap, bp) in zip(a.path, b.path) { #expect((ap - bp).length <= tolerance * 3) }
    }
}
@Test(arguments: TreeLayoutStyle.allCases)
func treeMetalMatchesCyclicForestAndAssistants(_ style: TreeLayoutStyle) async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    let cpu = treeMetalFixture(cyclic: true), gpu = treeMetalFixture(cyclic: true), c = TreeLayoutConfiguration()
    let parents = gpu.nodes.map(\.parent), rootChildren = gpu.root.children
    try c.algorithm(style).applyLayout(cpu)
    let executor = LayoutExecutor(), operation = TreeLayoutOperation(style: style, backend: .metal, executor: executor, configuration: c)
    try await operation.applyLayoutAsync(gpu)
    expectTreeMetalGeometry(gpu, cpu)
    #expect(gpu.nodes.map(\.parent) == parents)
    #expect(gpu.root.children == rootChildren)
    #expect(gpu.edges.last?.path == [Point(x: 71, y: 72)])
    #expect(operation.lastMetrics?.backend == .metal)
    #expect(operation.lastMetrics?.metalStages.isEmpty == false)
    #expect(operation.lastMetrics?.gpuSeconds != nil)
    let statistics = await executor.statistics()
    #expect(statistics.submittedBatches == statistics.completedBatches)
}
@Test(arguments: [127, 128, 129])
func treeMetalCommandBoundariesAndDiscardedOrigin(_ count: Int) async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    for style in TreeLayoutStyle.allCases {
        let cpu = treeMetalFixture(count, origin: 1e12), gpu = treeMetalFixture(count, origin: 1e12), c = TreeLayoutConfiguration()
        try c.algorithm(style).applyLayout(cpu)
        let operation = TreeLayoutOperation(style: style, backend: .metal, configuration: c)
        try await operation.applyLayoutAsync(gpu)
        expectTreeMetalGeometry(gpu, cpu)
        #expect(operation.lastMetrics?.backend == .metal)
    }
}
@Test func treeMapMetalPreservesNestedContainmentAndExternalChildren() async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    func nested() -> LayoutGraph {
        let graph = LayoutGraph(), group = LayoutNode(id: "group", width: 30, height: 40), outside = LayoutNode(id: "outside", width: 10, height: 20)
        group.isGroup = true; graph.addNode(group)
        for i in 0..<4 {
            let child = LayoutNode(id: "child-\(i)", width: 12, height: 14); child.parent = group
            group.children.append(child); graph.addNode(child)
        }
        outside.parent = group; group.children.append(outside)
        return graph
    }
    let cpu = nested(), gpu = nested(), c = TreeLayoutConfiguration()
    try c.algorithm(.treeMap).applyLayout(cpu)
    let operation = TreeLayoutOperation(style: .treeMap, backend: .metal, configuration: c)
    try await operation.applyLayoutAsync(gpu)
    expectTreeMetalGeometry(gpu, cpu)
    let gpuExternal = gpu.nodes[0].children.last!, cpuExternal = cpu.nodes[0].children.last!
    #expect(abs(gpuExternal.x - cpuExternal.x) < 0.01)
    #expect(abs(gpuExternal.height - cpuExternal.height) < 0.01)
    #expect(gpu.root.bounds == Rect(width: 1000, height: 1000))
    for node in gpu.nodes where node.parent !== gpu.root {
        let parent = node.parent!.bounds
        #expect(parent.contains(Point(x: node.x, y: node.y)))
        #expect(parent.contains(Point(x: node.bounds.right, y: node.bounds.bottom)))
    }
}
@Test func treePlacementFallbackValidationAndZeroNodes() async throws {
    var options = MetalLayoutOptions(); options.minimumNodeCount = 0
    let executor = LayoutExecutor(options: options, metalEnabled: false)
    let cpu = treeMetalFixture(), graph = treeMetalFixture()
    try TreeLayoutAlgorithm().applyLayout(cpu)
    let automatic = TreeLayoutOperation(style: .tree, backend: .automatic, executor: executor)
    try await automatic.applyLayoutAsync(graph)
    expectTreeMetalGeometry(graph, cpu, tolerance: 0)
    #expect(automatic.lastMetrics?.fallbackReason == .metalUnavailable)
    let before = graph.nodes.map(\.bounds)
    let explicit = TreeLayoutOperation(style: .tree, backend: .metal, executor: executor)
    do { try await explicit.applyLayoutAsync(graph); Issue.record("Expected unavailable Metal error") }
    catch { guard case OrganicLayoutError.metalUnavailable = error else { throw error } }
    #expect(graph.nodes.map(\.bounds) == before)
    var c = TreeLayoutConfiguration(); c.nodeSeparation = .infinity
    let invalid = TreeLayoutOperation(style: .tree, backend: .cpu, configuration: c)
    await #expect(throws: LayoutExecutionError.self) { try await invalid.applyLayoutAsync(graph) }
    #expect(graph.nodes.map(\.bounds) == before)
    let empty = TreeLayoutOperation(style: .tree, backend: .metal, executor: executor)
    try await empty.applyLayoutAsync(LayoutGraph())
    #expect(empty.lastMetrics?.fallbackReason == .noWork)
}
@Test func treeMetalPrecisionFallbackAndRollback() async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    var c = TreeLayoutConfiguration(); c.levelSeparation = 1e12
    let graph = treeMetalFixture(), before = graph.nodes.map(\.bounds)
    let explicit = TreeLayoutOperation(style: .tree, backend: .metal, configuration: c)
    await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(graph) }
    #expect(graph.nodes.map(\.bounds) == before)
    var options = MetalLayoutOptions(); options.minimumNodeCount = 0
    let automatic = TreeLayoutOperation(style: .tree, backend: .automatic, executor: LayoutExecutor(options: options), configuration: c)
    let cpu = treeMetalFixture(); try c.algorithm(.tree).applyLayout(cpu)
    try await automatic.applyLayoutAsync(graph)
    expectTreeMetalGeometry(graph, cpu, tolerance: 0)
    #expect(automatic.lastMetrics?.fallbackReason == .precisionLimit)
}

@Test func treeMapNearlySquareSplitRejectsUnsafeFloatOrientation() async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    func nestedSquare() -> LayoutGraph {
        let graph = LayoutGraph()
        let group = LayoutNode(id: "group", width: 1, height: 1), subgroup = LayoutNode(id: "subgroup", width: 1, height: 1)
        group.isGroup = true; subgroup.isGroup = true
        graph.addNode(group)
        let other = LayoutNode(id: "other", width: 1, height: 1); graph.addNode(other)
        subgroup.parent = group; group.children.append(subgroup); graph.addNode(subgroup)
        let sibling = LayoutNode(id: "sibling", width: 1, height: 1)
        sibling.parent = group; group.children.append(sibling); graph.addNode(sibling)
        for id in ["left", "right"] {
            let node = LayoutNode(id: id, width: 1, height: 1); node.parent = subgroup; subgroup.children.append(node); graph.addNode(node)
        }
        return graph
    }
    var c = TreeLayoutConfiguration(); c.padding = 100
    let squareCPU = nestedSquare(), squareGPU = nestedSquare()
    try c.algorithm(.treeMap).applyLayout(squareCPU)
    let square = TreeLayoutOperation(style: .treeMap, backend: .metal, configuration: c)
    try await square.applyLayoutAsync(squareGPU)
    expectTreeMetalGeometry(squareGPU, squareCPU)
    #expect(square.lastMetrics?.backend == .metal)
    c.padding = Float(100).nextUp
    let graph = nestedSquare(), before = graph.nodes.map(\.bounds)
    let explicit = TreeLayoutOperation(style: .treeMap, backend: .metal, configuration: c)
    await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(graph) }
    #expect(graph.nodes.map(\.bounds) == before)
    var options = MetalLayoutOptions(); options.minimumNodeCount = 0
    let automatic = TreeLayoutOperation(style: .treeMap, backend: .automatic, executor: LayoutExecutor(options: options), configuration: c)
    let cpu = nestedSquare(); try c.algorithm(.treeMap).applyLayout(cpu)
    try await automatic.applyLayoutAsync(graph)
    expectTreeMetalGeometry(graph, cpu, tolerance: 0)
    #expect(automatic.lastMetrics?.fallbackReason == .precisionLimit)
}
