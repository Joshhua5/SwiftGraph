import Foundation
import Testing

@testable import SwiftGraph

@Suite struct RouteStyleTests {
    // MARK: - Helpers

    private func node(_ g: LayoutGraph, _ id: String, _ r: Rect) -> LayoutNode {
        let n = LayoutNode(id: id, width: r.width, height: r.height)
        n.bounds = r
        g.addNode(n)
        return n
    }

    @discardableResult
    private func edge(_ g: LayoutGraph, _ a: LayoutNode, _ b: LayoutNode, _ path: [Point] = []) -> LayoutEdge {
        let e = LayoutEdge(source: a, target: b)
        e.path = path
        g.addEdge(e)
        return e
    }

    private func rectilinear(_ path: [Point]) -> Bool {
        zip(path, path.dropFirst()).allSatisfy { abs($0.x - $1.x) < 1e-4 || abs($0.y - $1.y) < 1e-4 }
    }

    /// Two edges stacked on one straight leg, a bent route, and one diagonal edge that fell back elsewhere.
    private func drawingWithOneFallbackEdge() -> (LayoutGraph, [LayoutEdge]) {
        let g = LayoutGraph()
        let a = node(g, "a", Rect(x: 0, y: 0, width: 100, height: 40))
        let b = node(g, "b", Rect(x: 0, y: 200, width: 100, height: 40))
        let e1 = edge(g, a, b, [Point(x: 50, y: 40), Point(x: 50, y: 200)])
        let e2 = edge(g, a, b, [Point(x: 50, y: 40), Point(x: 50, y: 200)])
        let c = node(g, "c", Rect(x: 300, y: 0, width: 40, height: 40))
        edge(g, c, b, [Point(x: 320, y: 40), Point(x: 320, y: 120), Point(x: 90, y: 120), Point(x: 90, y: 200)])
        let d = node(g, "d", Rect(x: 600, y: 0, width: 40, height: 40))
        let f = node(g, "f", Rect(x: 800, y: 300, width: 40, height: 40))
        edge(g, d, f, [Point(x: 640, y: 40), Point(x: 800, y: 300)])
        return (g, [e1, e2])
    }

    // MARK: - One fallback edge

    @Test func oneFallbackEdgeDoesNotTiltEveryPortInAnOrthogonalDrawing() {
        let (g, stacked) = drawingWithOneFallbackEdge()
        g.routeStyle = .orthogonal
        PortDistributor().routeEdges(g)
        for e in stacked {
            #expect(rectilinear(e.path), "\(e.path)")
            #expect(e.path.first!.y == 40 && e.path.last!.y == 200)
        }
        #expect(stacked[0].path.first!.x != stacked[1].path.first!.x)
    }

    @Test func withoutARecordedStyleTheFallbackEdgeStillFlipsTheInference() {
        // Unchanged behaviour for routes no router recorded: one diagonal makes the drawing a polyline drawing.
        let (g, stacked) = drawingWithOneFallbackEdge()
        PortDistributor().routeEdges(g)
        #expect(stacked.contains { !rectilinear($0.path) })
    }

    @Test func movedNodesKeepStraightLegsRectilinearInAnOrthogonalDrawingWithOneFallbackEdge() {
        for style in [RouteStyle.orthogonal, nil] {
            let (g, stacked) = drawingWithOneFallbackEdge()
            g.routeStyle = style
            let old = g.nodes.map(\.bounds)
            g.nodes[1].x += 30
            followMovedNodes(g, from: old)
            if style == .orthogonal {
                #expect(rectilinear(stacked[0].path), "\(stacked[0].path)")
            } else {
                #expect(!rectilinear(stacked[0].path), "\(stacked[0].path)")
            }
        }
    }

    // MARK: - Routers record the style

    @Test func routersRecordTheirStyle() {
        func graph() -> LayoutGraph {
            let g = LayoutGraph()
            let hub = node(g, "hub", Rect(x: 0, y: 0, width: 40, height: 40))
            for i in 0..<4 {
                let n = node(g, "n\(i)", Rect(x: Float(i) * 120 - 120, y: 200, width: 40, height: 40))
                edge(g, hub, n)
            }
            straightEdges(g)
            return g
        }
        let routers: [(any EdgeRouter, RouteStyle)] = [
            (ChannelEdgeRouter(), .orthogonal),
            (BspEdgeRouter(), .orthogonal),
            (OrthogonalGroupedEdgeRouter(), .orthogonal),
            (BusEdgeRouter(), .orthogonal),
            (PolylineEdgeRouter(), .polyline),
            (OctilinearEdgeRouter(), .octilinear),
            (EdgeBundlingRouter(), .polyline),
        ]
        for (router, style) in routers {
            let g = graph()
            router.routeEdges(g)
            #expect(g.routeStyle == style, "\(type(of: router))")
        }
        let g = graph()
        ChannelEdgeRouter().routeEdges(g)
        for stage in [EdgeSeparator(), SelfLoopRouter(), PortDistributor()] as [any EdgeRouter] { stage.routeEdges(g) }
        #expect(g.routeStyle == .orthogonal, "finishing stages keep the style")
        CurveFittingEdgeRouter().routeEdges(g)
        #expect(g.routeStyle == .curved)
        straightEdges(g)
        #expect(g.routeStyle == nil, "a layout that redraws the routes forgets the style")
    }

    @Test func backendRoutingCarriesTheStyleThroughItsDetachedGraph() async throws {
        let g = LayoutGraph()
        let a = node(g, "a", Rect(x: 0, y: 0, width: 40, height: 40))
        let b = node(g, "b", Rect(x: 200, y: 120, width: 40, height: 40))
        edge(g, a, b)
        try await LayoutBuilder.create(g).routeChannel(backend: .cpu).separateEdges(backend: .cpu)
            .clipEdgeEndpoints(backend: .cpu).applyAsync()
        #expect(g.routeStyle == .orthogonal)
        try await LayoutBuilder.create(g).routePolyline(backend: .cpu).applyAsync()
        #expect(g.routeStyle == .polyline)
    }

    // MARK: - Recursive groups

    /// Two frames with an edge inside each, and one edge between them, so there are three routing graphs.
    private func groupedDrawing() throws -> LayoutGraph {
        let g = LayoutGraph()
        var members: [LayoutNode] = []
        for index in 0..<2 {
            let frame = try g.addGroup(id: "frame\(index)", frame: .init(minimumSize: Size(width: 200, height: 100)))
            frame.x = Float(index) * 400
            for name in ["a", "b"] {
                let member = LayoutNode(id: "\(name)\(index)", width: 40, height: 40)
                member.x = frame.x + (name == "a" ? 0 : 100)
                try g.addNode(member, to: frame)
                members.append(member)
            }
            g.addEdge(LayoutEdge(source: members[2 * index], target: members[2 * index + 1]))
        }
        g.addEdge(LayoutEdge(source: members[0], target: members[3]))
        return g
    }

    @Test func recursiveGroupLayoutRecordsTheSharedStyleOfItsRoutingGraphs() throws {
        for routing in [PresetRouting.channel, .polyline] {
            let g = try groupedDrawing()
            g.routeStyle = .curved  // stale
            let layout = RecursiveGroupLayout(GivenCoordinatesLayoutAlgorithm())
            layout.presetRouting = { routing.apply($0) }
            try layout.applyLayout(g)
            #expect(g.routeStyle == routing.style)
        }
        let g = try groupedDrawing()
        try RecursiveGroupLayout(GivenCoordinatesLayoutAlgorithm()).applyLayout(g)
        #expect(g.routeStyle == .polyline, "the default group router")
    }

    @Test func recursiveGroupLayoutOperationRecordsTheSharedStyleOfItsRoutingGraphs() async throws {
        for routing in [PresetRouting.channel, .polyline] {
            let g = try groupedDrawing()
            g.routeStyle = .curved  // stale
            let layout = RecursiveGroupLayoutOperation(GivenCoordinatesLayoutAlgorithm())
            layout.presetRouting = { try await routing.apply($0, backend: .cpu, executor: .shared) }
            try await layout.applyLayoutAsync(g)
            #expect(g.routeStyle == routing.style)
        }
        let g = try groupedDrawing()
        try await RecursiveGroupLayoutOperation(GivenCoordinatesLayoutAlgorithm()).applyLayoutAsync(g)
        #expect(g.routeStyle == .polyline, "the default group router")
    }

    @Test func recursiveGroupLayoutForgetsTheStyleWhenGroupsDisagreeOrNothingWasRouted() async throws {
        var calls = 0
        let g = try groupedDrawing()
        g.routeStyle = .orthogonal
        let layout = RecursiveGroupLayout(GivenCoordinatesLayoutAlgorithm())
        layout.presetRouting = {
            calls += 1
            return (calls == 1 ? PresetRouting.channel : .polyline).apply($0)
        }
        try layout.applyLayout(g)
        #expect(g.routeStyle == nil)

        var asyncCalls = 0
        let h = try groupedDrawing()
        h.routeStyle = .orthogonal
        let operation = RecursiveGroupLayoutOperation(GivenCoordinatesLayoutAlgorithm())
        operation.presetRouting = {
            asyncCalls += 1
            return try await (asyncCalls == 1 ? PresetRouting.channel : .polyline)
                .apply($0, backend: .cpu, executor: .shared)
        }
        try await operation.applyLayoutAsync(h)
        #expect(h.routeStyle == nil)

        let unrouted = try groupedDrawing()
        unrouted.routeStyle = .orthogonal
        let plain = RecursiveGroupLayout(GivenCoordinatesLayoutAlgorithm())
        plain.routesEdges = false
        try plain.applyLayout(unrouted)
        #expect(unrouted.routeStyle == nil, "straight stand-ins are not the old style")
    }

    // MARK: - Rectilinear repair and fallback

    /// `a` and `b` side by side with a tall wall between them; every L, Z and U between their ports cuts the wall.
    private func walledPair() -> (LayoutGraph, LayoutEdge, LayoutNode) {
        let g = LayoutGraph()
        let a = node(g, "a", Rect(x: 0, y: 0, width: 40, height: 40))
        let b = node(g, "b", Rect(x: 200, y: 0, width: 40, height: 40))
        let wall = node(g, "wall", Rect(x: 100, y: -100, width: 20, height: 240))
        let e = edge(g, a, b, [a.center, b.center])
        return (g, e, wall)
    }

    @Test func orthogonalRepairDetoursRectilinearly() {
        let (g, e, wall) = walledPair()
        g.routeStyle = .orthogonal
        let failed = ObstaclePolyline.repair(g, spacing: 0)
        #expect(failed.isEmpty)
        #expect(rectilinear(e.path), "\(e.path)")
        #expect(ObstaclePolyline.clear(e.path, [wall.bounds]))
        #expect(e.path.count > 2)
    }

    @Test func orthogonalRepairNeverTradesAClearRouteForADiagonalShortcut() {
        let g = LayoutGraph()
        let a = node(g, "a", Rect(x: 0, y: 0, width: 40, height: 40))
        let b = node(g, "b", Rect(x: 60, y: 60, width: 40, height: 40))
        // Clear, but far longer than four times the centre distance.
        let long = [Point(x: 40, y: 20), Point(x: 600, y: 20), Point(x: 600, y: 80), Point(x: 100, y: 80)]
        let e = edge(g, a, b, long)
        g.routeStyle = .orthogonal
        ObstaclePolyline.repair(g, spacing: 0, shortenDetours: true)
        #expect(rectilinear(e.path), "\(e.path)")
        #expect(ObstaclePolyline.length(e.path) < ObstaclePolyline.length(long))
    }

    @Test func fallbackInAnOrthogonalDrawingSearchesRectilinearlyBeforeAPolyline() {
        let (g, e, wall) = walledPair()
        g.routeStyle = .orthogonal
        let path = RoutingFallback.route(e, g)
        #expect(rectilinear(path), "\(path)")
        #expect(ObstaclePolyline.clear(path, [wall.bounds]))
    }

    @Test func rectilinearSearchFindsARouteTheSimpleShapesMiss() {
        // A cup open at the bottom around the start, a floor below it and a post standing on the floor: the way out
        // runs under the cup, up beside it and over the post, more bends than any L, Z or U has.
        let obstacles = [
            Rect(x: -60, y: -60, width: 120, height: 20),
            Rect(x: -60, y: -40, width: 20, height: 80),
            Rect(x: 40, y: -40, width: 20, height: 80),
            Rect(x: -100, y: 70, width: 400, height: 20),
            Rect(x: 150, y: -100, width: 20, height: 170),
        ]
        let start = Point(x: 0, y: 0)
        let end = Point(x: 300, y: 0)
        #expect(RectilinearRoute.simple(start, end, obstacles) == nil)
        let found = RectilinearRoute.search(start, end, obstacles, padding: 10)
        #expect(found != nil)
        if let found {
            #expect(rectilinear(found) && ObstaclePolyline.clear(found, obstacles), "\(found)")
            #expect(found.first == start && found.last == end)
        }
    }
}
