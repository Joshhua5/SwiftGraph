import Foundation
import Testing

@testable import SwiftGraph

/// `finishRoutes` owns the order of the stages after a router: self-loops, repair, clip, ports, curves.
@Suite struct RouteFinishingTests {
    // MARK: - Fixtures

    /// A 3 x 3 grid with edges that pass straight through the middle node, a fan, parallel edges and a self-loop.
    private static func grid() -> LayoutGraph {
        let graph = LayoutGraph()
        var nodes: [LayoutNode] = []
        for row in 0..<3 {
            for column in 0..<3 {
                let node = LayoutNode(id: "n\(row)\(column)", width: 60, height: 40)
                node.center = Point(x: Double(column) * 160, y: Double(row) * 120)
                graph.addNode(node)
                nodes.append(node)
            }
        }
        for (source, target) in [
            (0, 8), (2, 6), (3, 5), (1, 7), (0, 1), (0, 3), (0, 4), (4, 5), (4, 5), (6, 2), (8, 8),
        ] {
            graph.addEdge(LayoutEdge(source: nodes[source], target: nodes[target]))
        }
        for edge in graph.edges { edge.path = [edge.source.center, edge.target.center] }
        return graph
    }

    private static func paths(_ graph: LayoutGraph) -> [[Point]] { graph.edges.map(\.path) }

    private static func blocked(_ graph: LayoutGraph) -> [LayoutEdge] {
        let scene = ObstaclePolyline.Scene(graph.nodes)
        return graph.edges.filter { $0.source !== $0.target && !scene.clear($0.path, $0) }
    }

    private static func onBoundary(_ point: Point, _ rect: Rect) -> Bool {
        let inside =
            point.x >= rect.left - 1e-3 && point.x <= rect.right + 1e-3 && point.y >= rect.top - 1e-3
            && point.y <= rect.bottom + 1e-3
        let edge = [
            abs(point.x - rect.left), abs(point.x - rect.right), abs(point.y - rect.top),
            abs(point.y - rect.bottom),
        ]
        .contains { $0 < 1e-3 }
        return inside && edge
    }

    /// The chain presets ran before `finishRoutes` existed.
    private static func legacyPresetFinish(_ graph: LayoutGraph) {
        SelfLoopRouter().routeEdges(graph)
        _ = ObstaclePolyline.repair(graph, spacing: 0, shortenDetours: true)
        EdgeEndpointClipper.clipToNodeBounds(graph)
        PortDistributor().routeEdges(graph)
    }

    // MARK: - Order

    @Test func finishingRoutesLoopsRepairsAndClipsEveryEdge() {
        let graph = Self.grid()
        #expect(!Self.blocked(graph).isEmpty)
        let failed = RouteFinishing.finish(graph, style: .polyline)
        #expect(failed.isEmpty)
        #expect(Self.blocked(graph).isEmpty)
        for edge in graph.edges where edge.source !== edge.target {
            #expect(Self.onBoundary(edge.path[0], edge.source.bounds))
            #expect(Self.onBoundary(edge.path[edge.path.count - 1], edge.target.bounds))
        }
        let loop = graph.edges[graph.edges.count - 1]
        #expect(loop.path.count > 2)
        #expect(loop.path.contains { !loop.source.bounds.contains($0) })
    }

    @Test func curvesAreTheLastStage() {
        let curved = Self.grid()
        RouteFinishing.finish(curved, style: .curved, curveIterations: 3)
        let expected = Self.grid()
        RouteFinishing.finish(expected, style: .polyline)
        let curves = CurveFittingEdgeRouter()
        curves.iterations = 3
        curves.routeEdges(expected)
        #expect(Self.paths(curved) == Self.paths(expected))
        #expect(Self.paths(curved).contains { $0.count > 4 })
    }

    @Test func straightRoutesAreNotRepaired() {
        let graph = Self.grid()
        RouteFinishing.finish(graph, style: .straight)
        let through = graph.edges[0]
        #expect(through.path.count == 2)
        #expect(!Self.blocked(graph).isEmpty)
    }

    @Test func portDistributionIsSkippedAboveTheLimit() {
        let limited = Self.grid()
        RouteFinishing.finish(limited, style: .polyline, portDistributionLimit: limited.edges.count - 1)
        let expected = Self.grid()
        SelfLoopRouter().routeEdges(expected)
        _ = ObstaclePolyline.repair(expected, spacing: 0, shortenDetours: true)
        EdgeEndpointClipper.clipToNodeBounds(expected)
        #expect(Self.paths(limited) == Self.paths(expected))

        let unlimited = Self.grid()
        RouteFinishing.finish(unlimited, style: .polyline, portDistributionLimit: unlimited.edges.count)
        let reference = Self.grid()
        RouteFinishing.finish(reference, style: .polyline)
        #expect(Self.paths(unlimited) == Self.paths(reference))
        #expect(Self.paths(limited) != Self.paths(reference))
    }

    // MARK: - Presets keep their drawings

    @Test(arguments: ["polyline", "bsp", "channel", "layered"])
    func presetRoutingMatchesTheChainItReplaced(_ name: String) {
        let preset: PresetRouting =
            switch name {
            case "bsp": .bsp
            case "channel": .channel
            case "layered": .layered
            default: .polyline
            }
        let finished = Self.grid()
        _ = preset.apply(finished)

        let legacy = Self.grid()
        switch preset {
        case .bsp: BspEdgeRouter().routeEdges(legacy)
        case .channel:
            ChannelEdgeRouter().routeEdges(legacy)
            EdgeSeparator().routeEdges(legacy)
        case .layered:
            _ = ObstaclePolyline.repair(legacy, shortenDetours: true)
            EdgeSeparator().routeEdges(legacy)
        default: PolylineEdgeRouter().routeEdges(legacy)
        }
        Self.legacyPresetFinish(legacy)
        #expect(Self.paths(finished) == Self.paths(legacy))
    }

    // MARK: - Builder

    @Test(arguments: RouteStyle.allCases)
    func builderStepsMatchOnEveryPath(_ style: RouteStyle) async throws {
        let direct = Self.grid()
        RouteFinishing.finish(direct, style: style)
        let sync = Self.grid()
        try await LayoutBuilder.create(sync).finishRoutes(style: style).applyAsync()
        let backend = Self.grid()
        try await LayoutBuilder.create(backend).finishRoutes(style: style, backend: .cpu).applyAsync()
        #expect(Self.paths(sync) == Self.paths(direct))
        #expect(Self.paths(backend) == Self.paths(direct))
    }

    /// The gallery used to run a second separation pass after these two routers. Their corridor tracks already sit a
    /// spacing apart; a second pass may give lanes exactly a spacing apart another order, but crosses no fewer edges.
    @Test(arguments: ["bsp", "grouped"])
    func routersThatSeparateTheirOwnLanesNeedNoSecondPass(_ name: String) {
        let router: any EdgeRouter = name == "bsp" ? BspEdgeRouter() : OrthogonalGroupedEdgeRouter()
        let once = Self.grid()
        router.routeEdges(once)
        #expect(Self.closestLanes(once) >= 10 - 1e-3, "\(name): lanes \(Self.closestLanes(once)) apart")
        let twice = Self.grid()
        router.routeEdges(twice)
        EdgeSeparator().routeEdges(twice)
        #expect(RouteAudit(twice, router).crossings >= RouteAudit(once, router).crossings)
    }

    /// The closest two parallel stretches of different edges that overlap along their line.
    private static func closestLanes(_ graph: LayoutGraph) -> Float {
        var stretches: [(edge: Int, vertical: Bool, at: Float, low: Float, high: Float)] = []
        for (e, edge) in graph.edges.enumerated() where edge.source !== edge.target {
            for (a, b) in zip(edge.path, edge.path.dropFirst()) {
                if abs(a.x - b.x) < 1e-3, abs(a.y - b.y) > 1e-3 {
                    stretches.append((e, true, a.x, min(a.y, b.y), max(a.y, b.y)))
                } else if abs(a.y - b.y) < 1e-3, abs(a.x - b.x) > 1e-3 {
                    stretches.append((e, false, a.y, min(a.x, b.x), max(a.x, b.x)))
                }
            }
        }
        var closest = Float.infinity
        for (i, s) in stretches.enumerated() {
            for t in stretches[(i + 1)...]
            where s.edge != t.edge && s.vertical == t.vertical && min(s.high, t.high) - max(s.low, t.low) > 1e-3 {
                closest = min(closest, abs(s.at - t.at))
            }
        }
        return closest
    }
}
