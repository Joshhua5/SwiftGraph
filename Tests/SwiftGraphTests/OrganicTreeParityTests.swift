import Foundation
import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct OrganicTreeParityTests {
    func graph(_ count: Int, shape: String) -> LayoutGraph {
        let graph = LayoutGraph()
        for i in 0..<count {
            let node = LayoutNode(id: String(i), width: 8, height: 8)
            if shape == "coincident" { node.center = Point(x: 3.25, y: -5.5) }
            else if shape == "cutoff" {
                node.center = Point(x: i == 0 ? 0 : (i % 2 == 0 ? 499.99 : 500.01), y: Double(i % 4) * 0.25)
            } else { node.center = Point(x: Double((i * 137 + 29) % 997), y: Double((i * 263 + 47) % 991)) }
            graph.addNode(node)
        }
        graph.nodes[0].metadata[GraphMetadataKeys.fixed] = true
        for i in 1..<count { graph.addEdge(LayoutEdge(source: graph.nodes[(i - 1) / 2], target: graph.nodes[i])) }
        return graph
    }
    @Test(arguments: ["spread", "coincident", "cutoff"])
    func serializationRetainsProductionInsertionAndCutoffPolicy(_ shape: String) throws {
        let graph = graph(129, shape: shape)
        let floats = graph.nodes.map { SIMD2(Float($0.center.x), Float($0.center.y)) }
        let points = floats.map { Point(x: Double($0.x), y: Double($0.y)) }
        let tree = ForceQuadTree(); tree.build(points)
        let snapshot = try OrganicForceTree(floats)
        #expect(snapshot.cells[0].mass == points.count)
        #expect(snapshot.gpuChildren.count == snapshot.cells.count && snapshot.gpuBounds.count == snapshot.cells.count)
        #expect(snapshot.gpuLeaves.bodies.count == points.count)
        for i in points.indices {
            #expect(snapshot.testForce(on: i, strength: 100) == tree.computeForce(nodeIndex: i, position: points[i], repulsionSquared: 100))
        }
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"), arguments: [63, 64, 65, 129], ["spread", "coincident", "cutoff"])
    func productionMetalMatchesCPUAcrossBarnesHutBoundary(_ count: Int, _ shape: String) async throws {
        let a = graph(count, shape: shape), b = graph(count, shape: shape), before = b.nodes[0].bounds
        var configuration = OrganicLayoutConfiguration(quality: .legacy)
        configuration.iterations = 3; configuration.initialTemperature = 0.5
        configuration.repulsionForce = 10; configuration.attractionForce = 0.025
        try await OrganicLayoutOperation(backend: .cpu, configuration: configuration).applyLayoutAsync(a)
        let executor = LayoutExecutor(), operation = OrganicLayoutOperation(backend: .metal, executor: executor, configuration: configuration)
        try await operation.applyLayoutAsync(b)
        #expect(operation.lastMetrics?.backend == .metal && operation.lastMetrics?.gpuSeconds != nil)
        #expect(b.nodes[0].bounds == before)
        for (x, y) in zip(a.nodes, b.nodes) { #expect((x.center - y.center).length < 0.002) }
        let stats = await executor.statistics()
        #expect(stats.pipelineBuilds == 1)
        #expect(stats.submittedBatches == stats.completedBatches)
        #expect(stats.submittedBatches == (count < 64 ? 1 : configuration.iterations))
    }
    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal unavailable"))
    func treePreparationTimingAndConcurrentSolvesStayRequestLocal() async throws {
        let executor = LayoutExecutor(), a = graph(65, shape: "spread"), b = graph(129, shape: "coincident")
        let firstSnapshot = try GraphCheckpoint(a).snapshot, secondSnapshot = try GraphCheckpoint(b).snapshot
        let first = Task { try await executor.organicTestPreparation(firstSnapshot) }
        let second = Task { try await executor.organicTestPreparation(secondSnapshot) }
        let one = try await first.value, two = try await second.value
        #expect(one > 0 && two > 0)
        let statistics = await executor.statistics(); #expect(statistics.submittedBatches == statistics.completedBatches)
    }
}

extension LayoutExecutor {
    func organicTestPreparation(_ snapshot: GeometrySnapshot) async throws -> Double {
        var configuration = OrganicLayoutConfiguration(quality: .legacy); configuration.iterations = 2; configuration.initialTemperature = 0.1
        let prepared = try snapshot.prepareMetal(configuration: configuration, fixed: snapshot.nodes.map(\.fixed), tolerance: options.maximumCoordinateError)
        if metal == nil { metal = try MetalForceSolver() }
        let result = try await metal!.solveAsync(prepared.state, iterations: configuration.iterations,
            temperature: Float(configuration.initialTemperature), parameters: ForceParameters(repulsionSquared: 100, attraction: 0.025), batchSize: 8)
        return result.cpuPreparationSeconds
    }
}

extension OrganicForceTree {
    /// Exact Double oracle for serialization regression tests only.
    func testForce(on node: Int, strength: Double) -> Point {
        guard !cells.isEmpty else { return .zero }
        let point = positions[node]
        var force = Point.zero, stack = [0]
        func contribution(_ other: Point, mass: Int) -> Point {
            var delta = point - other
            if delta.lengthSquared > 250_000 { return .zero }
            if delta.lengthSquared < 0.01 {
                let angle = Double(node) * 2.399963229728653
                delta = Point(x: cos(angle) * 0.1, y: sin(angle) * 0.1)
            }
            return delta * (strength * Double(mass) / delta.lengthSquared)
        }
        while let index = stack.popLast() {
            let cell = cells[index]
            guard cell.mass > 0 else { continue }
            if cell.children.isEmpty {
                for body in cell.bodies where body != node { force = force + contribution(positions[body], mass: 1) }
            } else {
                let distance = (point - cell.center).lengthSquared
                let delta = point - cell.bounds.center, half = cell.bounds.width / 2
                let nearX = max(0, abs(delta.x) - half), nearY = max(0, abs(delta.y) - half)
                if nearX * nearX + nearY * nearY > 250_000 { continue }
                let farX = abs(delta.x) + half, farY = abs(delta.y) + half
                if !cell.bounds.contains(point) && farX * farX + farY * farY <= 250_000 && cell.bounds.width * cell.bounds.width < 0.8 * 0.8 * distance {
                    force = force + contribution(cell.center, mass: cell.mass)
                } else { stack.append(contentsOf: cell.children.reversed()) }
            }
        }
        return force
    }

}
