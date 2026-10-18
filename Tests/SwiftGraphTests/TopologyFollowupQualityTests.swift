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

    @Test func layeredRoutesShortenFarVirtualNodeDetoursAndPreservePorts() throws {
        let graph = LayoutGraph()
        let source = LayoutNode(id: "s", width: 80, height: 32), target = LayoutNode(id: "t", width: 80, height: 32)
        source.center = Point(x: 5500, y: 374); target.center = Point(x: 5250, y: 1406)
        graph.addNode(source); graph.addNode(target)
        let edge = LayoutEdge(source: source, target: target); graph.addEdge(edge)
        try routeLayeredEdges(graph, chains: [[Point(x: 3170, y: 906)]], flows: [1])
        #expect(edge.path.first?.y == source.bounds.bottom && edge.path.last?.y == target.bounds.top)
        #expect(ObstaclePolyline.length(edge.path) < 2 * (target.center - source.center).length)
    }

    @Test func repairShortensLongClearBundledDetours() {
        let graph = LayoutGraph()
        let source = LayoutNode(id: "s", width: 80, height: 32), target = LayoutNode(id: "t", width: 80, height: 32)
        source.center = Point(x: 0, y: 0); target.center = Point(x: 180, y: 0)
        graph.addNode(source); graph.addNode(target)
        let edge = LayoutEdge(source: source, target: target)
        edge.path = [source.center, Point(x: 90, y: 400), target.center]
        graph.addEdge(edge)
        let failed = ObstaclePolyline.repair(graph, spacing: 0, shortenDetours: true)
        #expect(failed.isEmpty)
        #expect(ObstaclePolyline.length(edge.path) < 250)
    }

    @Test func anchoredOrganicPackingKeepsDisconnectedComponentsCompact() throws {
        let graph = LayoutGraph()
        for i in 0..<8 {
            let node = LayoutNode(id: "\(i)", width: 80, height: 32)
            node.center = i == 0 ? .zero : Point(x: Float(i) * 1500, y: Float(i) * -1200)
            if i == 0 { node.metadata[GraphMetadataKeys.fixed] = true }
            graph.addNode(node)
        }
        var search = try OrganicQualitySearch(GraphCheckpoint(graph).snapshot, OrganicLayoutConfiguration())
        try search.consider(graph.nodes.map(\.center))
        let xs = search.best.map(\.x), ys = search.best.map(\.y)
        #expect(search.best[0] == .zero)
        #expect((xs.max()! - xs.min()!) < 1000 && (ys.max()! - ys.min()!) < 1000)
        #expect(search.diagnostics.final.clearanceViolations == 0)
    }

    @Test func circularPlacementPairsLargeFrameAgainstSmallSiblingsCompactly() async throws {
        func makeGraph(frame: Size) -> LayoutGraph {
            let graph = LayoutGraph()
            for i in 0..<4 {
                graph.addNode(LayoutNode(id: "\(i)", width: i == 0 ? frame.width : 80, height: i == 0 ? frame.height : 32))
            }
            return graph
        }
        // The topology's outer frame: small siblings sit beside it rather than across a full-radius void.
        let cpu = makeGraph(frame: Size(width: 9080, height: 8897)); try CircularLayoutAlgorithm().applyLayout(cpu)
        #expect(cpu.bounds.width < 12_500 && cpu.bounds.height < 9000)
        for i in cpu.nodes.indices { for j in cpu.nodes.indices.dropFirst(i + 1) {
            #expect(!cpu.nodes[i].bounds.intersects(cpu.nodes[j].bounds))
        } }
        // Metal placement has a coordinate precision limit, so backend parity uses a smaller frame.
        let small = makeGraph(frame: Size(width: 908, height: 890)); try CircularLayoutAlgorithm().applyLayout(small)
        for backend in LayoutExecutor.isMetalAvailable ? [LayoutBackend.cpu, .metal] : [.cpu] {
            let graph = makeGraph(frame: Size(width: 908, height: 890))
            try await BasicLayoutOperation(style: .circular, backend: backend).applyLayoutAsync(graph)
            // Shader trigonometry may differ from Foundation's in the last bits; BasicMetalTests uses the same tolerance.
            for (a, b) in zip(graph.nodes.map(\.bounds), small.nodes.map(\.bounds)) {
                #expect(abs(a.x - b.x) <= 0.01 && abs(a.y - b.y) <= 0.01 && a.size == b.size, "\(backend)")
            }
        }
    }
}

