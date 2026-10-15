import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

private let groupedFixtures = try! loadRoutingFixtures().filter { $0.router == "grouped" }

@Suite struct GroupedFixTests {
    private func routed(_ fixture: RoutingFixture) -> (graph: LayoutGraph, router: OrthogonalGroupedEdgeRouter) {
        let graph = fixture.graph(), router = fixture.makeRouter() as! OrthogonalGroupedEdgeRouter
        router.routeEdges(graph); return (graph, router)
    }
    private func measured(_ graph: LayoutGraph) -> VisualMetrics {
        let item = VisualCase(id: "grouped", family: "test", title: "Grouped") { VisualDrawing(graph: graph) }
        return VisualGeometry.measure(VisualSnapshot(case: item, drawing: VisualDrawing(graph: graph)))
    }
    private func onBoundary(_ p: Point, _ r: Rect) -> Bool {
        r.inflated(by: 1e-4).contains(p) && !r.inflated(by: -1e-4).contains(p)
    }
    private func scene(_ rects: [Rect], edges: [(Int, Int)]) -> LayoutGraph {
        let graph = LayoutGraph()
        for (i, r) in rects.enumerated() { let n = LayoutNode(id: "n\(i)", width: r.width, height: r.height); n.bounds = r; graph.addNode(n) }
        for (a, b) in edges { graph.addEdge(LayoutEdge(source: graph.nodes[a], target: graph.nodes[b])) }
        return graph
    }
    private func clearance(_ path: [Point], _ rect: Rect) -> Float {
        zip(path, path.dropFirst()).map { VisualGeometry.distance($0, $1, to: rect) }.min() ?? .infinity
    }

    /// Every reference-grouped fixture: orthogonal routes that start and end on their own nodes, never cross or touch an
    /// unrelated leaf, and never close on themselves. Edges the router reports are drawn by the fallback and exempt.
    @Test(arguments: groupedFixtures)
    fileprivate func routesAreOrthogonalClearAndAttachedToTheirNodes(_ fixture: RoutingFixture) {
        let (graph, router) = routed(fixture)
        for (index, edge) in graph.edges.enumerated() where edge.source !== edge.target {
            let label = "\(fixture.name) e\(index)", path = edge.path
            #expect(path.count >= 2 && path.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "\(label): \(path)")
            guard path.count >= 2 else { continue }
            #expect(path.first != path.last, "\(label): closed loop")
            guard !router.unroutableEdges.contains(where: { $0 === edge }) else { continue }
            for (a, b) in zip(path, path.dropFirst()) { #expect(abs(a.x - b.x) < 1e-4 || abs(a.y - b.y) < 1e-4, "\(label): diagonal \(a)-\(b)") }
            #expect(onBoundary(path[0], edge.source.bounds), "\(label): starts off \(edge.source.id)")
            #expect(onBoundary(path[path.count - 1], edge.target.bounds), "\(label): ends off \(edge.target.id)")
            let unrelated = graph.nodes.filter { n in
                !n.isGroup && n !== edge.source && n !== edge.target && !isAncestor(edge.source, of: n) && !isAncestor(edge.target, of: n)
            }
            for node in unrelated { #expect(clearance(path, node.bounds) > 0, "\(label): touches \(node.id)") }
        }
    }

    /// Merged routing started every route at node centres: corridors 0-11 totalled 147 bends and 90 crossings.
    @Test func corridorsStayWithinTheirBendAndCrossingBudgets() throws {
        let budgets: [(bends: Double, crossings: Double)] = [(8, 7), (9, 3), (8, 6), (9, 3), (9, 3), (10, 5), (11, 8), (13, 5), (9, 7), (12, 9), (8, 7), (10, 10)]
        var bends = 0.0, crossings = 0.0
        for (index, budget) in budgets.enumerated() {
            let fixture = try #require(groupedFixtures.first { $0.name == "grouped-corridors-\(index)" })
            let values = measured(routed(fixture).graph).values
            #expect(values["bends"]! <= budget.bends && values["crossings"]! <= budget.crossings, "corridors-\(index): \(values["bends"]!) bends, \(values["crossings"]!) crossings")
            bends += values["bends"]!; crossings += values["crossings"]!
        }
        #expect(bends <= 116 && crossings <= 73, "\(bends) bends, \(crossings) crossings")
    }

    @Test func routesNeedNotStartOrEndAtNodeCentres() {
        // Centre to centre, the route hugged the wall's underside (clearance 0) to reach the target's centre; entering
        // lower down the face clears it. The L keeps its single bend.
        let g = scene([Rect(x: 0, y: 0, width: 40, height: 40), Rect(x: 200, y: 30, width: 40, height: 40), Rect(x: 100, y: -50, width: 30, height: 100)], edges: [(0, 1)])
        let router = OrthogonalGroupedEdgeRouter(); router.routeEdges(g)
        let path = g.edges[0].path
        #expect(router.unroutableEdges.isEmpty && path.count == 3, "\(path)")
        #expect(path.last.map { $0.y != g.nodes[1].center.y && onBoundary($0, g.nodes[1].bounds) } == true, "\(path)")
        #expect(clearance(path, g.nodes[2].bounds) > 0, "\(path)")
    }

    @Test func routesLeaveAndEnterPerpendicularToTheFaceNeverAlongIt() {
        // X's left line (10) minus the margin coincides with both end nodes' left sides: the route may not run down them.
        let g = scene([Rect(x: 0, y: 100, width: 40, height: 40), Rect(x: 10, y: 200, width: 40, height: 40), Rect(x: 0, y: 300, width: 40, height: 40)], edges: [(0, 2)])
        let router = OrthogonalGroupedEdgeRouter(); router.bundleSpacing = 0; router.routeEdges(g)
        let path = g.edges[0].path
        #expect(router.unroutableEdges.isEmpty)
        for (point, next, node) in [(path[0], path[1], g.nodes[0]), (path[path.count - 1], path[path.count - 2], g.nodes[2])] {
            let alongFace = abs(point.x - next.x) < 1e-4 ? point.x <= node.bounds.left + 1e-4 || point.x >= node.bounds.right - 1e-4 : point.y <= node.bounds.top + 1e-4 || point.y >= node.bounds.bottom - 1e-4
            #expect(!alongFace, "\(path)")
        }
    }

    @Test func routeEndsKeepClearOfNodeCorners() {
        // The target's centre line runs 2 units below the source's top edge; legs must take a lane in the middle half instead.
        let g = scene([Rect(x: 0, y: 0, width: 40, height: 40), Rect(x: 200, y: -18, width: 40, height: 40)], edges: [(0, 1)])
        OrthogonalGroupedEdgeRouter().routeEdges(g)
        let path = g.edges[0].path
        #expect(path.first.map { onBoundary($0, g.nodes[0].bounds) && $0.y >= 10 && $0.y <= 30 } == true, "\(path)")
        #expect(path.last.map { onBoundary($0, g.nodes[1].bounds) && $0.y >= -8 && $0.y <= 12 } == true, "\(path)")
    }

    @Test func lanesNeverRunAlongAnotherNodesOutline() {
        // The source's right lane (40 + margin 10) coincides with X's right edge; the route must take the lane beyond X instead.
        let g = scene([Rect(x: 0, y: 0, width: 40, height: 40), Rect(x: 0, y: 100, width: 50, height: 40), Rect(x: 0, y: 200, width: 40, height: 40)], edges: [(0, 2)])
        let router = OrthogonalGroupedEdgeRouter(); router.bundleSpacing = 0; router.routeEdges(g)
        #expect(router.unroutableEdges.isEmpty)
        #expect(clearance(g.edges[0].path, g.nodes[1].bounds) > 0, "\(g.edges[0].path)")
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable))
    func axisBlockersCloseTheirIntervalOnlyWhenAsked() throws {
        let rects = [Rect(x: 10, y: 0, width: 40, height: 40), Rect(x: 60, y: 0, width: 40, height: 40)]
        let compute = RoutingCompute(solver: try MetalForceSolver(), tolerance: 1e-3, statisticsChanged: {})
        let values: [Float] = [10.0, 30, 50, 55, 60, 100]
        #expect(compute.axisBlockers(values, rectangles: rects, vertical: true) == [[], [0], [], [], [], []])
        #expect(compute.axisBlockers(values, rectangles: rects, vertical: true, closed: true) == [[0], [0], [0], [], [1], [1]])
        #expect(compute.axisBlockers([0, 20, 40, 41], rectangles: rects, vertical: false, closed: true) == [[0, 1], [0, 1], [0, 1], []])
        #expect(compute.axisBlockers([0, 20, 40, 41], rectangles: rects, vertical: false) == [[], [0, 1], [], []])
    }

    @Test func channelLinesStayOffOutlinesAndOnlyYieldToNodesBesideThem() {
        let root = LayoutNode(id: "root", width: 400, height: 400); root.isGroup = true; root.x = -100
        // b sits 15 to the right of a but far below it: it must not pull a's right line in; fractional edges round away from the node.
        for (i, r) in [Rect(x: 0.5, y: 0, width: 50, height: 50), Rect(x: 65.5, y: 200, width: 50, height: 50)].enumerated() {
            let n = LayoutNode(id: "\(i)", width: r.width, height: r.height); n.bounds = r; n.parent = root; root.children.append(n)
        }
        let calculator = ChannelGridCalculator(); calculator.margin = 10; calculator.buildChannels(root)
        let xs = calculator.getGrid(root).xChannels
        #expect(xs.contains(-10) && xs.contains(61) && xs.contains(55) && xs.contains(126), "\(xs)")
        #expect(!xs.contains(-9) && !xs.contains(60) && !xs.contains(57))
        // Beside each other, the gap is shared: a's right line stops halfway to b.
        let beside = LayoutNode(id: "root", width: 400, height: 400); beside.isGroup = true; beside.x = -100
        for (i, r) in [Rect(x: 0, y: 0, width: 50, height: 50), Rect(x: 65, y: 0, width: 50, height: 50)].enumerated() {
            let n = LayoutNode(id: "\(i)", width: r.width, height: r.height); n.bounds = r; n.parent = beside; beside.children.append(n)
        }
        calculator.buildChannels(beside)
        #expect(calculator.getGrid(beside).xChannels.contains(58))
    }

    @Test(arguments: [3, 11, 29])
    func seededRandomDrawingsKeepEveryInvariant(_ seed: UInt64) {
        var state = seed &* 0x9E3779B97F4A7C15 | 1
        func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) }
        var rects: [Rect] = []
        for row in 0..<6 { for column in 0..<7 {
            let w = 20 + next(31), h = 20 + next(31)
            rects.append(Rect(x: Float(column * 110 + next(50)), y: Float(row * 100 + next(40)), width: Float(w), height: Float(h)))
        } }
        let g = scene(rects, edges: (0..<70).map { _ in (next(rects.count), next(rects.count)) }.filter { $0.0 != $0.1 })
        let router = OrthogonalGroupedEdgeRouter(); router.routeEdges(g)
        for (index, edge) in g.edges.enumerated() where !router.unroutableEdges.contains(where: { $0 === edge }) {
            let path = edge.path, label = "seed \(seed) e\(index)"
            #expect(path.count >= 2 && path.first != path.last, "\(label): \(path)")
            guard path.count >= 2 else { continue }
            for (a, b) in zip(path, path.dropFirst()) { #expect(abs(a.x - b.x) < 1e-4 || abs(a.y - b.y) < 1e-4, "\(label): diagonal \(a)-\(b)") }
            #expect(onBoundary(path[0], edge.source.bounds) && onBoundary(path[path.count - 1], edge.target.bounds), "\(label): \(path)")
            for node in g.nodes where node !== edge.source && node !== edge.target { #expect(clearance(path, node.bounds) > 0, "\(label): touches \(node.id)") }
        }
        #expect(router.unroutableEdges.count <= g.edges.count / 10)
    }

    @Test func coincidentNodesAreReportedAndDrawnByTheFallback() throws {
        let fixture = try #require(groupedFixtures.first { $0.name == "grouped-coincident" })
        let (graph, router) = routed(fixture)
        #expect(router.unroutableEdges.count == 1)
        let path = graph.edges[0].path
        #expect(path.count >= 2 && path.first != path.last, "\(path)")
        // Largely overlapping, but not identical, nodes are reported as well.
        let g = scene([Rect(x: 0, y: 0, width: 40, height: 40), Rect(x: 10, y: 5, width: 40, height: 40)], edges: [(0, 1)])
        let other = OrthogonalGroupedEdgeRouter(); other.routeEdges(g)
        #expect(other.unroutableEdges.count == 1 && g.edges[0].path.count >= 2 && g.edges[0].path.first != g.edges[0].path.last)
    }

    @Test func spacingDefaultsToTheSeparatorLaneWidth() {
        #expect(OrthogonalGroupedEdgeRouter().bundleSpacing == 10)
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable), arguments: ["grouped-corridors-11", "grouped-corridors-0", "grouped-corridors-9"])
    func metalAndCPUAgreeOnClosedBlockers(_ name: String) async throws {
        let fixture = try #require(groupedFixtures.first { $0.name == name })
        let cpu = fixture.graph(), metal = fixture.graph()
        let configure: (inout RoutingConfiguration) -> Void = { $0.bundleSpacing = fixture.config["bundleSpacing"] ?? 4; $0.obstacleMargin = fixture.config["obstacleMargin"] ?? 10; $0.bendPenalty = fixture.config["bendPenalty"] ?? 100 }
        try await RoutingLayoutOperation(.orthogonalGrouped, backend: .cpu, configure: configure).applyLayoutAsync(cpu)
        try await RoutingLayoutOperation(.orthogonalGrouped, backend: .metal, configure: configure).applyLayoutAsync(metal)
        #expect(cpu.edges.map(\.path) == metal.edges.map(\.path))
        #expect(cpu.nodes.map(\.bounds) == metal.nodes.map(\.bounds))
    }
}
