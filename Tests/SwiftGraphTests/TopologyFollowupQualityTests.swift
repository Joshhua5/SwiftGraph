import Testing
@testable import SwiftGraph

@Suite(.serialized) struct TopologyFollowupQualityTests {
    private func chain() -> LayoutGraph {
        let graph = LayoutGraph()
        for (id, width, height) in [("root", Float(80), Float(32)), ("frame", 2000, 2000), ("leaf", 80, 32)] {
            graph.addNode(LayoutNode(id: id, width: width, height: height))
        }
        graph.addEdge(LayoutEdge(source: graph.nodes[0], target: graph.nodes[1]))
        graph.addEdge(LayoutEdge(source: graph.nodes[1], target: graph.nodes[2]))
        return graph
    }

    @Test func organizationLevelsUseOnlyThePreviousDepthsHeight() async throws {
        let cpu = chain(); try OrgChartLayoutAlgorithm().applyLayout(cpu)
        #expect(cpu.nodes[1].y - cpu.nodes[0].y == 80)
        #expect(cpu.nodes[2].y - cpu.nodes[1].y == 2020)
        #expect(cpu.nodes[0].center.x == cpu.nodes[1].center.x)
        #expect(cpu.nodes[1].center.x == cpu.nodes[2].center.x)
        for backend in LayoutExecutor.isMetalAvailable ? [LayoutBackend.cpu, .metal] : [.cpu] {
            let graph = chain()
            try await TreeLayoutOperation(style: .orgChart, backend: backend).applyLayoutAsync(graph)
            #expect(graph.nodes.map(\.bounds) == cpu.nodes.map(\.bounds))
        }
    }

    @Test func radialDepthsFitRectanglesWithoutReservingFullAnnuli() async throws {
        let cpu = chain(); try RadialTreeLayoutAlgorithm().applyLayout(cpu)
        #expect(cpu.bounds.width < 2300 && cpu.bounds.height == 2000)
        for i in cpu.nodes.indices { for j in cpu.nodes.indices.dropFirst(i + 1) {
            #expect(!cpu.nodes[i].bounds.intersects(cpu.nodes[j].bounds))
        } }
        for backend in LayoutExecutor.isMetalAvailable ? [LayoutBackend.cpu, .metal] : [.cpu] {
            let graph = chain()
            try await RadialLayoutOperation(style: .tree, backend: backend).applyLayoutAsync(graph)
            #expect(graph.nodes.map(\.bounds) == cpu.nodes.map(\.bounds))
        }
    }

    @Test func longPolylineRoutesCompareNarrowerClearCorridors() {
        let graph = LayoutGraph()
        for (id, bounds) in [("s", Rect(width: 40, height: 30)), ("t", Rect(x: 120, width: 40, height: 30)),
                             ("upper", Rect(x: 55, y: -400, width: 50, height: 410)),
                             ("lower", Rect(x: 55, y: 20, width: 50, height: 400))] {
            let node = LayoutNode(id: id, width: bounds.width, height: bounds.height); node.bounds = bounds; graph.addNode(node)
        }
        let edge = LayoutEdge(source: graph.nodes[0], target: graph.nodes[1]); graph.addEdge(edge)
        let router = PolylineEdgeRouter(); router.routeEdges(graph)
        #expect(router.unroutableEdges.isEmpty)
        #expect(ObstaclePolyline.length(edge.path) < 200)
        #expect(ObstaclePolyline.Scene(graph.nodes).clear(edge.path, edge))
    }

    @Test func bspBoundaryLinksAvoidTheFarSideOfWideContainers() throws {
        let graph = LayoutGraph(), group = try graph.addGroup(id: "wide", frame: .init())
        group.bounds = Rect(x: -3000, width: 6000, height: 600)
        let source = LayoutNode(id: "s", width: 80, height: 32), wall = LayoutNode(id: "wall", width: 80, height: 32)
        source.y = 100; wall.y = 400
        try graph.addNode(source, to: group); try graph.addNode(wall, to: group)
        let target = LayoutNode(id: "t", width: 80, height: 32); target.y = 800; graph.addNode(target)
        let edge = LayoutEdge(source: source, target: target); edge.sourcePort = .bottom; edge.targetPort = .top; graph.addEdge(edge)
        let router = BspEdgeRouter(); router.routeEdges(graph)
        #expect(router.unroutableEdges.isEmpty)
        #expect(ObstaclePolyline.length(edge.path) < 1200)
        #expect(ObstaclePolyline.Scene(graph.nodes).clear(edge.path, edge))
        #expect(edge.path.first?.y == source.bounds.bottom && edge.path.last?.y == target.bounds.top)
        #expect(zip(edge.path, edge.path.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y })
        #expect(source.parent === group && wall.parent === group)
    }
}
