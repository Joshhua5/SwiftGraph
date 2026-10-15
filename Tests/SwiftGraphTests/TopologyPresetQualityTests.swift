import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

@Suite(.serialized) struct TopologyPresetQualityTests {
    private func snapshot(_ graph: LayoutGraph) -> VisualSnapshot {
        let item = VisualCase(id: "preset-quality", family: "test", title: "Preset quality",
                              contracts: .init(noNodeOverlaps: true, noObstacleIntersections: true, framedGroups: true)) { VisualDrawing(graph: graph) }
        return VisualSnapshot(case: item, drawing: VisualDrawing(graph: graph))
    }

    private func fixture() throws -> LayoutGraph {
        let topology = try JSONDecoder().decode(GraphTopology.self, from: Data("""
        {"nodes":[{},{"parent":0},{"parent":0},{"parent":1},{"parent":1},{"parent":2},{"parent":2},{},{}],
         "edges":[{"source":3,"target":4,"bidirectional":false},{"source":4,"target":5,"bidirectional":true},
         {"source":3,"target":6,"bidirectional":false},{"source":6,"target":7,"bidirectional":false},
         {"source":7,"target":3,"bidirectional":false},{"source":8,"target":8,"bidirectional":false}]}
        """.utf8))
        let graph = try topology.makeGraph()
        graph.nodes[3].metadata["caller"] = "preserved"
        return graph
    }

    @Test(arguments: LayoutPatternType.allCases)
    func everyPresetFitsNestedGroupsAndKeepsConnections(_ pattern: LayoutPatternType) async throws {
        let graph = try fixture(), identities = graph.nodes, edges = graph.edges, parents = graph.nodes.map(\.parent)
        try await LayoutBuilder.create(graph).applyPattern(pattern).applyAsync()
        #expect(graph.nodes == identities && graph.edges == edges)
        #expect(graph.nodes.map(\.parent) == parents)
        #expect(graph.nodes[3].metadata["caller"] as? String == "preserved")
        let measured = VisualGeometry.measure(snapshot(graph))
        #expect(measured.failures.isEmpty, "\(pattern): \(measured.failures)")
        #expect(graph.edges.allSatisfy { $0.path.count >= 2 && $0.path.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
        let cpu = try fixture()
        try await LayoutBuilder.create(cpu).applyPattern(pattern, backend: .cpu).applyAsync()
        #expect(cpu.nodes.map(\.bounds) == graph.nodes.map(\.bounds), "\(pattern): CPU placement parity")
        #expect(cpu.edges.map(\.path) == graph.edges.map(\.path), "\(pattern): CPU routing parity")
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: LayoutPatternType.allCases)
    func metalPresetsFitNestedGroups(_ pattern: LayoutPatternType) async throws {
        let graph = try fixture(), identities = graph.nodes
        let builder = LayoutBuilder.create(graph).applyPattern(pattern, backend: .metal, executor: LayoutExecutor())
        try await builder.applyAsync()
        #expect(graph.nodes == identities)
        #expect(VisualGeometry.measure(snapshot(graph)).failures.isEmpty, "\(pattern): Metal geometry")
        #expect(builder.lastExecutionMetrics.contains { !$0.metalStages.isEmpty })
        #expect(builder.lastExecutionMetrics.allSatisfy { $0.requestedBackend == .metal })
    }

    @Test func localHubAnchorsDoNotLeakIntoCallerMetadata() async throws {
        for backend in [LayoutBackend.cpu, .automatic] {
            let graph = try fixture()
            graph.nodes[3].metadata[GraphMetadataKeys.layoutSubset] = false
            try await LayoutBuilder.create(graph).applyNetworkTopology(backend: backend, organicIterations: 2).applyAsync()
            #expect(graph.nodes.allSatisfy { $0.metadata[GraphMetadataKeys.fixed] == nil })
            #expect(graph.nodes[3].metadata[GraphMetadataKeys.layoutSubset] as? Bool == false)
            #expect(graph.nodes[4].metadata[GraphMetadataKeys.layoutSubset] == nil)
        }
    }

    @Test func virtualVerticesDoNotReserveRealNodeSpacing() throws {
        let graph = LayoutGraph()
        for i in 0..<32 { graph.addNode(LayoutNode(id: "\(i)", width: 80, height: 32)) }
        for i in 0..<31 { graph.addEdge(LayoutEdge(source: graph.nodes[i], target: graph.nodes[i + 1])) }
        for i in 0..<16 { for j in 16..<32 { graph.addEdge(LayoutEdge(source: graph.nodes[i], target: graph.nodes[j])) } }
        let algorithm = HierarchicalLayoutAlgorithm(); algorithm.nodeSeparation = 80; algorithm.routesEdges = false
        try algorithm.applyLayout(graph)
        #expect(graph.bounds.width < 10_000)
        #expect(hierarchyGap(0, 1, originals: 2, separation: 80) == 80)
        #expect(hierarchyGap(0, 2, originals: 2, separation: 80) == 40)
        #expect(hierarchyGap(2, 3, originals: 2, separation: 80) == 2)
    }

    @Test func circularFittingUsesIndividualFrameSizes() throws {
        let graph = LayoutGraph()
        for i in 0..<4 { graph.addNode(LayoutNode(id: "\(i)", width: i == 0 ? 1000 : 80, height: i == 0 ? 800 : 32)) }
        let algorithm = CircularLayoutAlgorithm(); algorithm.radius = 0
        try algorithm.applyLayout(graph)
        let radius = fittedCircleRadius(graph.nodes.map(\.bounds), minimum: 0)
        #expect(radius < 500)
        for i in graph.nodes.indices { for j in graph.nodes.indices.dropFirst(i + 1) {
            #expect(!graph.nodes[i].bounds.intersects(graph.nodes[j].bounds))
        } }
        let before = graph.nodes.map(\.bounds); try algorithm.applyLayout(graph)
        #expect(graph.nodes.map(\.bounds) == before)
    }

    @Test func circularSectorsFitLargeFramesAmongHundredsOfSmallSiblings() throws {
        let graph = LayoutGraph()
        for i in 0..<205 { graph.addNode(LayoutNode(id: "\(i)", width: i == 0 ? 865 : 80, height: i == 0 ? 830 : 32)) }
        try CircularLayoutAlgorithm().applyLayout(graph)
        #expect(graph.bounds.width < 10_000 && graph.bounds.height < 10_000)
        for i in graph.nodes.indices { for j in graph.nodes.indices.dropFirst(i + 1) {
            #expect(!graph.nodes[i].bounds.intersects(graph.nodes[j].bounds))
        } }
    }

    @Test func visibilityCornersRemainUsableAtLargeFloatCoordinates() {
        let graph = LayoutGraph()
        for (id, rect) in [("s", Rect(x: 100_000, y: 100_000, width: 40, height: 40)),
                           ("t", Rect(x: 100_600, y: 100_000, width: 40, height: 40)),
                           ("wall", Rect(x: 100_250, y: 99_900, width: 100, height: 240))] {
            let node = LayoutNode(id: id, width: rect.width, height: rect.height); node.bounds = rect; graph.addNode(node)
        }
        let edge = LayoutEdge(source: graph.nodes[0], target: graph.nodes[1]); graph.addEdge(edge)
        let router = PolylineEdgeRouter(); router.routeEdges(graph)
        #expect(router.unroutableEdges.isEmpty)
        #expect(edge.path.count > 2)
        #expect(ObstaclePolyline.clear(edge.path, [graph.nodes[2].bounds]))
    }

    @Test func forestRootsPackIntoRows() throws {
        for algorithm in [TreeLayoutAlgorithm(), OrgChartLayoutAlgorithm(), RadialTreeLayoutAlgorithm()] as [any LayoutAlgorithm] {
            let graph = LayoutGraph()
            for i in 0..<64 { graph.addNode(LayoutNode(id: "\(i)", width: 80, height: 32)) }
            try algorithm.applyLayout(graph)
            #expect(Set(graph.nodes.map { $0.center.y }).count > 1)
            #expect(graph.bounds.width < 2000)
            #expect(VisualGeometry.measure(snapshot(graph)).values["nodeOverlaps"] == 0)
        }
    }

    @Test func bundlingWithoutStartingRoutesAvoidsUnrelatedNodes() {
        let graph = LayoutGraph()
        for (id, r) in [("s", Rect(x: 0, y: 0, width: 40, height: 32)), ("t", Rect(x: 500, y: 0, width: 40, height: 32)),
                        ("wall", Rect(x: 230, y: -80, width: 80, height: 200))] {
            let node = LayoutNode(id: id, width: r.width, height: r.height); node.bounds = r; graph.addNode(node)
        }
        for _ in 0..<4 { graph.addEdge(LayoutEdge(source: graph.nodes[0], target: graph.nodes[1])) }
        let router = EdgeBundlingRouter(); router.routeEdges(graph)
        #expect(router.unroutableEdges.isEmpty)
        #expect(graph.edges.allSatisfy { ObstaclePolyline.clear($0.path, ObstaclePolyline.obstacles($0, graph)) })
    }

    @Test func ancestorHeadersRemainObstacles() throws {
        let graph = LayoutGraph(), group = try graph.addGroup(id: "group", frame: .init(headerSize: Size(width: 120, height: 30)))
        let a = LayoutNode(id: "a", width: 40, height: 30), b = LayoutNode(id: "b", width: 40, height: 30)
        try graph.addNode(a, to: group); try graph.addNode(b, to: group)
        a.x = 0; a.y = 100; b.x = 200; b.y = 100
        try RecursiveGroupLayout(GivenCoordinatesLayoutAlgorithm()).applyLayout(graph)
        let edge = LayoutEdge(source: a, target: b); graph.addEdge(edge)
        let header = try #require(group.groupHeaderBounds)
        edge.path = [a.center, header.center, b.center]
        #expect(!ObstaclePolyline.Scene(graph.nodes).clear(edge.path, edge))
        PolylineEdgeRouter().routeEdges(graph)
        #expect(!zip(edge.path, edge.path.dropFirst()).contains { header.inflated(by: -0.01).intersectsLine($0, $1) })
    }

    @Test func denseSeparationDoesNotCreateDistantFans() {
        let graph = LayoutGraph(), a = LayoutNode(id: "a", width: 80, height: 32), b = LayoutNode(id: "b", width: 80, height: 32)
        b.x = 500; graph.addNode(a); graph.addNode(b)
        for _ in 0..<200 {
            let edge = LayoutEdge(source: a, target: b)
            edge.path = [a.center, Point(x: 150, y: -100), Point(x: 350, y: -100), b.center]; graph.addEdge(edge)
        }
        let before = ObstaclePolyline.bounds(graph.edges.flatMap(\.path))
        let separator = EdgeSeparator(); separator.routeEdges(graph)
        #expect(graph.edges.flatMap(\.path).allSatisfy(before.inflated(by: 40.01).contains))
        #expect(!separator.unseparatedEdges.isEmpty)
    }
}
