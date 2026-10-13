import Testing
@testable import SwiftGraph

@Suite struct HierarchicalPlacementTests {
    @Test func placementOnlyPreservesGeometryAndLeavesRoutesForTheNextStage() throws {
        func graph() -> LayoutGraph {
            let graph = LayoutGraph()
            let nodes = [LayoutNode(id: "a", width: 40, height: 20),
                         LayoutNode(id: "b", width: 20, height: 60),
                         LayoutNode(id: "c", width: 80, height: 30)]
            for node in nodes { graph.addNode(node) }
            for (source, target) in zip(nodes, nodes.dropFirst()) {
                let edge = LayoutEdge(source: source, target: target)
                edge.path = [Point(x: -100, y: -100), Point(x: -50, y: -50)]
                graph.addEdge(edge)
            }
            return graph
        }
        let routed = graph(), placement = graph()
        let algorithm = HierarchicalLayoutAlgorithm()
        #expect(algorithm.routesEdges)
        try algorithm.applyLayout(routed)
        let paths = placement.edges.map(\.path)
        algorithm.routesEdges = false
        try algorithm.applyLayout(placement)
        #expect(placement.nodes.map(\.bounds) == routed.nodes.map(\.bounds))
        #expect(placement.edges.map(\.path) == paths)
        #expect(routed.edges.allSatisfy { $0.path.count >= 2 })
        #expect(routed.edges.map(\.path) != paths)
    }

    @Test func asyncCPUPlacementOnlyLeavesRoutesUntouched() async throws {
        let graph = LayoutGraph()
        let source = LayoutNode(id: "source", width: 80, height: 20)
        let target = LayoutNode(id: "target", width: 30, height: 60)
        graph.addNode(source)
        graph.addNode(target)
        let edge = LayoutEdge(source: source, target: target)
        edge.path = [Point(x: -100, y: -100), Point(x: -50, y: -50)]
        graph.addEdge(edge)
        let path = edge.path
        var configuration = HierarchicalLayoutConfiguration()
        configuration.routesEdges = false
        try await HierarchicalLayoutOperation(backend: .cpu, configuration: configuration).applyLayoutAsync(graph)
        #expect(target.center.y > source.center.y)
        #expect(source.width == 80 && source.height == 20)
        #expect(target.width == 30 && target.height == 60)
        #expect(edge.path == path)
    }
}
