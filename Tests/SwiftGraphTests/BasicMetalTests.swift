import Foundation
import Testing
@testable import SwiftGraph

private func basicMetalFixture(_ count: Int = 9, origin: Float = 0, groups: Bool = true) -> LayoutGraph {
    let graph = LayoutGraph()
    for i in 0..<count {
        let node = LayoutNode(id: "n\(i + 1)", width: 18 + Float(i % 3), height: 12 + Float(i % 4), data: "value-\(i)")
        node.x = origin + Float(i % 3) * 11; node.y = origin + Float(i / 3) * 9
        graph.addNode(node)
    }
    if groups, let last = graph.nodes.last { last.isGroup = true; last.x = origin + 150.123456789; last.y = origin + 170.987654321 }
    for i in 1..<count { graph.addEdge(LayoutEdge(source: graph.nodes[(i - 1) / 2], target: graph.nodes[i])) }
    if let first = graph.nodes.first {
        let loop = LayoutEdge(source: first, target: first); loop.path = [Point(x: 901, y: 902)]; graph.addEdge(loop)
    }
    return graph
}
private func basicMetalConfiguration(_ style: BasicLayoutStyle, count: Int = 9) -> BasicLayoutConfiguration {
    var c = BasicLayoutConfiguration()
    c.horizontalAlignment = .snapToGrid; c.verticalAlignment = .middle
    c.area = Rect(x: 5, y: 7, width: 130, height: 90)
    c.maxCellsPerRow = 3
    for i in 0..<count { c.cellAssignment["n\(i + 1)"] = GridCell(row: i / 3, column: i % 3) }
    return c
}
private func expectBasicGeometry(_ actual: LayoutGraph, _ expected: LayoutGraph, tolerance: Float = 0.01) {
    #expect(actual.nodes.count == expected.nodes.count)
    for (a, b) in zip(actual.nodes, expected.nodes) {
        #expect(abs(a.x - b.x) <= tolerance)
        #expect(abs(a.y - b.y) <= tolerance)
        #expect(abs(a.width - b.width) <= tolerance)
        #expect(abs(a.height - b.height) <= tolerance)
        #expect(a.data as? String == b.data as? String)
    }
    #expect(actual.edges.count == expected.edges.count)
    for (a, b) in zip(actual.edges, expected.edges) {
        #expect(a.path.count == b.path.count)
        for (ap, bp) in zip(a.path, b.path) { #expect((ap - bp).length <= tolerance * 3) }
    }
}

@Test(arguments: BasicLayoutStyle.allCases)
func basicMetalMatchesSynchronous(_ style: BasicLayoutStyle) async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    let cpu = basicMetalFixture(), gpu = basicMetalFixture(), c = basicMetalConfiguration(style)
    let parents = gpu.nodes.map(\.parent), children = gpu.root.children, sizes = gpu.nodes.map { $0.bounds.size }
    try c.algorithm(style).applyLayout(cpu)
    let executor = LayoutExecutor(), operation = BasicLayoutOperation(style: style, backend: .metal, executor: executor, configuration: c)
    try await operation.applyLayoutAsync(gpu)
    expectBasicGeometry(gpu, cpu)
    #expect(operation.lastMetrics?.backend == .metal)
    #expect(operation.lastMetrics?.gpuSeconds != nil)
    #expect(operation.lastMetrics?.metalStages.isEmpty == false)
    #expect(operation.lastMetrics!.computeSeconds <= operation.lastMetrics!.totalSeconds)
    #expect(gpu.nodes.map(\.parent) == parents)
    #expect(gpu.root.children == children)
    if style != .verticalStack { #expect(gpu.nodes.map { $0.bounds.size } == sizes) }
    #expect(gpu.edges.last?.path == [Point(x: 901, y: 902)])
    let statistics = await executor.statistics()
    #expect(statistics.submittedBatches > 0)
    #expect(statistics.completedBatches == statistics.submittedBatches)
}

@Test(arguments: [127, 128, 129])
func basicMetalThreadBoundariesAndDiscardedOrigins(_ count: Int) async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    for style in [BasicLayoutStyle.circular, .tabular, .orthogonal, .partitionGrid, .kandinsky, .compactDisk, .fillArea, .verticalStack] {
        let cpu = basicMetalFixture(count, origin: 1e12, groups: false), gpu = basicMetalFixture(count, origin: 1e12, groups: false)
        var c = basicMetalConfiguration(style, count: count)
        c.maxCellsPerRow = 12
        c.cellAssignment = Dictionary(uniqueKeysWithValues: (0..<count).map { ("n\($0 + 1)", GridCell(row: $0 / 12, column: $0 % 12)) })
        try c.algorithm(style).applyLayout(cpu)
        let operation = BasicLayoutOperation(style: style, backend: .metal, configuration: c)
        try await operation.applyLayoutAsync(gpu)
        expectBasicGeometry(gpu, cpu)
        #expect(operation.lastMetrics?.backend == .metal)
    }
}

@Test func basicPlacementFallbackErrorsAndEmptyInput() async throws {
    var options = MetalLayoutOptions(); options.minimumNodeCount = 0
    let unavailable = LayoutExecutor(options: options, metalEnabled: false), cpu = basicMetalFixture(), graph = basicMetalFixture()
    var c = BasicLayoutConfiguration(); c.spacing = .nan // Unrelated to tabular.
    try TabularLayoutAlgorithm().applyLayout(cpu)
    let automatic = BasicLayoutOperation(style: .tabular, backend: .automatic, executor: unavailable, configuration: c)
    try await automatic.applyLayoutAsync(graph)
    expectBasicGeometry(graph, cpu, tolerance: 0)
    #expect(automatic.lastMetrics?.fallbackReason == .metalUnavailable)
    #expect(automatic.lastMetrics?.metalStages == [])
    let explicit = BasicLayoutOperation(style: .tabular, backend: .metal, executor: unavailable)
    let before = graph.nodes.map(\.bounds)
    do { try await explicit.applyLayoutAsync(graph); Issue.record("Expected unavailable Metal error") }
    catch { guard case OrganicLayoutError.metalUnavailable = error else { throw error } }
    #expect(graph.nodes.map(\.bounds) == before)
    #expect(explicit.lastMetrics == nil)
    let empty = BasicLayoutOperation(style: .circular, backend: .metal, executor: unavailable)
    try await empty.applyLayoutAsync(LayoutGraph())
    #expect(empty.lastMetrics?.fallbackReason == .noWork)
    c.cellSpacing = .infinity
    let invalid = BasicLayoutOperation(style: .tabular, backend: .cpu, configuration: c)
    await #expect(throws: LayoutExecutionError.self) { try await invalid.applyLayoutAsync(graph) }
    #expect(graph.nodes.map(\.bounds) == before)
}

@Test func basicPlacementPrecisionAndBankerRounding() async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    let graph = LayoutGraph()
    for (i, x) in [Float(-30.0), -10, 10, 30, 50].enumerated() {
        let n = LayoutNode(id: "\(i)", width: 2, height: 2); n.x = x; graph.addNode(n)
    }
    var c = BasicLayoutConfiguration(); c.horizontalAlignment = .snapToGrid
    let operation = BasicLayoutOperation(style: .alignment, backend: .metal, configuration: c)
    try await operation.applyLayoutAsync(graph)
    #expect(graph.nodes.map(\.x) == [-40, 0, 0, 40, 40])
    graph.nodes[0].x = 1e12
    let before = graph.nodes.map(\.bounds)
    await #expect(throws: LayoutExecutionError.precisionLimit) { try await operation.applyLayoutAsync(graph) }
    #expect(graph.nodes.map(\.bounds) == before)
    var options = MetalLayoutOptions(); options.minimumNodeCount = 0
    let automatic = BasicLayoutOperation(style: .alignment, backend: .automatic, executor: LayoutExecutor(options: options), configuration: c)
    try await automatic.applyLayoutAsync(graph)
    #expect(automatic.lastMetrics?.fallbackReason == .precisionLimit)
}

@Test func basicMetalCoincidentOverlapRemovalAndClearArea() async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    for style in [BasicLayoutStyle.removeOverlaps, .clearArea] {
        let cpu = basicMetalFixture(12, groups: false), gpu = basicMetalFixture(12, groups: false)
        for graph in [cpu, gpu] { for node in graph.nodes { node.x = 0; node.y = 0 } }
        let c = BasicLayoutConfiguration()
        try c.algorithm(style).applyLayout(cpu)
        let operation = BasicLayoutOperation(style: style, backend: .metal, configuration: c)
        try await operation.applyLayoutAsync(gpu)
        expectBasicGeometry(gpu, cpu)
        if style == .removeOverlaps {
            for i in gpu.nodes.indices { for j in gpu.nodes.indices where j > i {
                #expect(!gpu.nodes[i].bounds.inflated(by: c.minSpacing / 2 - 0.001).intersects(gpu.nodes[j].bounds.inflated(by: c.minSpacing / 2 - 0.001)))
            } }
        } else { #expect(gpu.nodes.allSatisfy { !$0.bounds.intersects(c.area) }) }
    }
}

@Test @MainActor func basicMetalCancellationAfterSubmissionDrainsBuffers() async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    var options = MetalLayoutOptions(); options.maximumCoordinateError = 10
    let executor = LayoutExecutor(options: options), graph = basicMetalFixture(192, groups: false)
    for node in graph.nodes { node.x = 0; node.y = 0 }
    let before = graph.nodes.map(\.bounds)
    let operation = BasicLayoutOperation(style: .removeOverlaps, backend: .metal, executor: executor)
    let task = Task { try await operation.applyLayoutAsync(graph) }
    for _ in 0..<2_000 {
        if await executor.statistics().submittedBatches > 0 { break }
        await Task.yield()
    }
    task.cancel()
    do { try await task.value; Issue.record("Expected cancellation after submission") }
    catch is CancellationError {}
    #expect(graph.nodes.map(\.bounds) == before)
    #expect(operation.lastMetrics == nil)
    let statistics = await executor.statistics()
    #expect(statistics.submittedBatches > 0)
    #expect(statistics.submittedBatches == statistics.completedBatches)
}

@Test func basicGridAndAreaConfigurationAliasesPreserveDefaults() async throws {
    #expect(BasicLayoutOperation(style: .orthogonal, backend: .cpu).configuration.gridSize == 100)
    #expect(BasicLayoutOperation(style: .alignment, backend: .cpu).configuration.gridSize == 20)
    var c = BasicLayoutConfiguration(); c.horizontalAlignment = .snapToGrid; c.gridSize = 17
    #expect(c.alignmentGridSize == 17)
    let graph = LayoutGraph(), node = LayoutNode(id: "snap", width: 2, height: 3)
    node.x = 25; node.y = 5.123456789; graph.addNode(node)
    let backend: LayoutBackend = LayoutExecutor.isMetalAvailable ? .metal : .cpu
    try await BasicLayoutOperation(style: .alignment, backend: backend, configuration: c).applyLayoutAsync(graph)
    #expect(node.x == 17); #expect(node.y == 5.123456789)
    c.alignmentGridSize = 13; #expect(c.gridSize == 13)
    c.fillArea = Rect(x: 11, y: 12, width: 77, height: 88); #expect(c.area == c.fillArea)
    c.clearArea = Rect(x: 13, y: 14, width: 55, height: 66); #expect(c.area == c.clearArea)
}

@Test func basicSnapBoundaryUsesExplicitPrecisionFailureOrAutomaticCPU() async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    let graph = LayoutGraph(), node = LayoutNode(id: "near-half", width: 2, height: 2)
    node.x = Float(10).nextUp; graph.addNode(node)
    var c = BasicLayoutConfiguration(); c.horizontalAlignment = .snapToGrid
    let before = node.bounds
    let explicit = BasicLayoutOperation(style: .alignment, backend: .metal, configuration: c)
    await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(graph) }
    #expect(node.bounds == before)
    var options = MetalLayoutOptions(); options.minimumNodeCount = 0
    let automatic = BasicLayoutOperation(style: .alignment, backend: .automatic, executor: LayoutExecutor(options: options), configuration: c)
    try await automatic.applyLayoutAsync(graph)
    #expect(node.x == 20); #expect(automatic.lastMetrics?.fallbackReason == .precisionLimit)
}

@Test func basicAlreadyClearOverlapInputPreservesExactCoordinatesWithoutGPUWork() async throws {
    let graph = LayoutGraph()
    for i in 0..<3 {
        let node = LayoutNode(id: "clear-\(i)", width: 20 + Float(i), height: 14)
        node.center = Point(x: 100 + Float(i) * Float(100).ulp, y: Float(i) * 100)
        graph.addNode(node)
    }
    let before = graph.nodes.map(\.bounds), executor = LayoutExecutor(metalEnabled: false)
    let operation = BasicLayoutOperation(style: .removeOverlaps, backend: .metal, executor: executor)
    try await operation.applyLayoutAsync(graph)
    #expect(graph.nodes.map(\.bounds) == before)
    #expect(operation.lastMetrics?.fallbackReason == .noWork)
    #expect(operation.lastMetrics?.metalStages.isEmpty == true)
    #expect(await executor.statistics().submittedBatches == 0)
}

@Test func basicConflictingNearCoincidentCentersKeepExplicitPrecisionProtection() async throws {
    guard LayoutExecutor.isMetalAvailable else { return }
    func conflict() -> LayoutGraph {
        let graph = LayoutGraph()
        for i in 0..<3 {
            let node = LayoutNode(id: "conflict-\(i)", width: 20, height: 14)
            node.center = Point(x: 100 + Float(i) * Float(100).ulp, y: 100); graph.addNode(node)
        }
        return graph
    }
    let graph = conflict(), before = graph.nodes.map(\.bounds), executor = LayoutExecutor()
    let explicit = BasicLayoutOperation(style: .removeOverlaps, backend: .metal, executor: executor)
    await #expect(throws: LayoutExecutionError.precisionLimit) { try await explicit.applyLayoutAsync(graph) }
    #expect(graph.nodes.map(\.bounds) == before)
    #expect(await executor.statistics().submittedBatches == 0)
    var options = MetalLayoutOptions(); options.minimumNodeCount = 0
    let automatic = BasicLayoutOperation(style: .removeOverlaps, backend: .automatic, executor: LayoutExecutor(options: options))
    let cpu = conflict(); try RemoveOverlapsLayoutAlgorithm().applyLayout(cpu)
    try await automatic.applyLayoutAsync(graph)
    expectBasicGeometry(graph, cpu, tolerance: 0)
    #expect(automatic.lastMetrics?.fallbackReason == .precisionLimit)
}

@Test(arguments: [0, -1, Int.min])
func basicKandinskyNonpositiveCapacityRetainsCPUClamp(_ capacity: Int) async throws {
    var options = MetalLayoutOptions(); options.minimumNodeCount = 0
    for backend in [LayoutBackend.cpu, .automatic, .metal] {
        if backend == .metal && !LayoutExecutor.isMetalAvailable { continue }
        let cpu = basicMetalFixture(7, groups: false), graph = basicMetalFixture(7, groups: false)
        var c = BasicLayoutConfiguration(); c.maxCellsPerRow = capacity
        try c.algorithm(.kandinsky).applyLayout(cpu)
        let operation = BasicLayoutOperation(style: .kandinsky, backend: backend, executor: LayoutExecutor(options: options), configuration: c)
        try await operation.applyLayoutAsync(graph)
        expectBasicGeometry(graph, cpu, tolerance: 0)
        if backend == .metal { #expect(operation.lastMetrics?.backend == .metal) }
    }
}

@Test func basicPartitionIgnoresNegativeCellsBeforeMetalIndexValidation() async throws {
    var options = MetalLayoutOptions(); options.minimumNodeCount = 0
    for backend in [LayoutBackend.cpu, .automatic, .metal] {
        if backend == .metal && !LayoutExecutor.isMetalAvailable { continue }
        let cpu = basicMetalFixture(3, groups: false), graph = basicMetalFixture(3, groups: false)
        var c = BasicLayoutConfiguration()
        c.cellAssignment = ["n1": GridCell(row: 0, column: 0), "n2": GridCell(row: -1, column: Int.max),
                            "n3": GridCell(row: Int.max, column: -1)]
        let unchanged = graph.nodes.dropFirst().map(\.bounds)
        try c.algorithm(.partitionGrid).applyLayout(cpu)
        let operation = BasicLayoutOperation(style: .partitionGrid, backend: backend, executor: LayoutExecutor(options: options), configuration: c)
        try await operation.applyLayoutAsync(graph)
        expectBasicGeometry(graph, cpu, tolerance: 0)
        #expect(graph.nodes.dropFirst().map(\.bounds) == unchanged)
        if backend == .metal { #expect(operation.lastMetrics?.backend == .metal) }
    }
}
