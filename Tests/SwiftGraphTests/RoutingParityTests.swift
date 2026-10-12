import Foundation
import Testing
@testable import SwiftGraph

private struct RoutingFixture: Decodable, Sendable, CustomTestStringConvertible {
    struct Node: Decodable, Sendable { var id: String; var bounds: [Double]; var parent: String?; var group: Bool? }
    struct Edge: Decodable, Sendable {
        var source: String; var target: String
        var sourcePort: PortConstraint?; var targetPort: PortConstraint?
        var sourceCandidates: [PortConstraint]?; var targetCandidates: [PortConstraint]?
        var path: [[Double]]?
    }
    struct Expected: Decodable, Sendable {
        var paths: [[[Double]]]; var bounds: [[Double]]; var root: [Double]
        var global: [[[Double]]]; var local: [[[[Double]]]]
    }
    var name: String; var router: String; var nodes: [Node]; var edges: [Edge]; var config: [String: Double]; var expected: Expected
    var testDescription: String { name }
    func graph() -> LayoutGraph {
        let graph = LayoutGraph()
        let lookup = Dictionary(uniqueKeysWithValues: nodes.map { spec in
            let n = LayoutNode(id: spec.id, width: spec.bounds[2], height: spec.bounds[3]); n.x = spec.bounds[0]; n.y = spec.bounds[1]; n.isGroup = spec.group ?? false
            return (spec.id, n)
        })
        for spec in nodes {
            let n = lookup[spec.id]!
            if let parent = spec.parent { n.parent = lookup[parent]!; n.parent!.children.append(n) }
            graph.addNode(n)
        }
        for spec in edges {
            let e = LayoutEdge(source: lookup[spec.source]!, target: lookup[spec.target]!)
            e.sourcePort = spec.sourcePort ?? .none; e.targetPort = spec.targetPort ?? .none
            e.sourcePortCandidates = spec.sourceCandidates ?? []; e.targetPortCandidates = spec.targetCandidates ?? []
            e.path = (spec.path ?? []).map { Point(x: $0[0], y: $0[1]) }; graph.addEdge(e)
        }
        return graph
    }
    func makeRouter() -> any EdgeRouter {
        switch router {
        case "channel":
            let r = ChannelEdgeRouter(); r.gridSize = Int(config["gridSize"] ?? 20); r.bendPenalty = Int(config["bendPenalty"] ?? 2); r.congestionPenalty = Int(config["congestionPenalty"] ?? 2); return r
        case "grouped":
            let r = OrthogonalGroupedEdgeRouter(); r.bundleSpacing = config["bundleSpacing"] ?? 4; r.obstacleMargin = config["obstacleMargin"] ?? 10; r.bendPenalty = config["bendPenalty"] ?? 100; return r
        case "polyline": let r = PolylineEdgeRouter(); r.padding = config["padding"] ?? 10; return r
        default: return BspEdgeRouter()
        }
    }
}
private let routingFixtures: [RoutingFixture] = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/routing-reference.json")
    return try! JSONDecoder().decode([RoutingFixture].self, from: Data(contentsOf: url))
}()
private func approximatelyEqual(_ a: [Point], _ b: [[Double]]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0.x - $1[0]) < 1e-7 && abs($0.y - $1[1]) < 1e-7 }
}
private func approximatelyEqual(_ a: Rect, _ b: [Double]) -> Bool {
    zip([a.x, a.y, a.width, a.height], b).allSatisfy { abs($0 - $1) < 1e-7 }
}

@Suite struct RoutingParityTests {
    @Test(arguments: routingFixtures)
    fileprivate func matchesReference(_ fixture: RoutingFixture) {
        let graph = fixture.graph(), calculator = BspGridCalculator()
        calculator.buildTree(graph)
        let global = calculator.getGlobalGridSegments()
        #expect(global.count == fixture.expected.global.count)
        for (actual, expected) in zip(global, fixture.expected.global) { #expect(approximatelyEqual([actual.start, actual.end], expected)) }
        for (node, expected) in zip(graph.nodes, fixture.expected.local) {
            let local = calculator.getLocalGridSegments(node)
            #expect(local.count == expected.count)
            for (a, b) in zip(local, expected) { #expect(approximatelyEqual([a.start, a.end], b), "\(fixture.name): local segments of \(node.id)") }
        }
        fixture.makeRouter().routeEdges(graph)
        for (node, bounds) in zip(graph.nodes, fixture.expected.bounds) { #expect(approximatelyEqual(node.bounds, bounds), "\(fixture.name): bounds of \(node.id)") }
        #expect(approximatelyEqual(graph.root.bounds, fixture.expected.root))
        for (index, edge) in graph.edges.enumerated() {
            #expect(approximatelyEqual(edge.path, fixture.expected.paths[index]), "\(fixture.name) edge \(index): \(edge.path) expected \(fixture.expected.paths[index])")
        }
    }

    @Test func groupedNudgingActuallyMovesObstaclesAndReroutesIncidentEdges() throws {
        let fixture = try #require(routingFixtures.first { $0.name == "grouped-bus-nudge-reroute" })
        let graph = fixture.graph(), wall = try #require(graph.nodes.first { $0.id == "wall" })
        let before = wall.bounds
        fixture.makeRouter().routeEdges(graph)
        #expect(wall.bounds != before)
        for a in graph.nodes { for b in graph.nodes where a !== b { #expect(!a.bounds.intersects(b.bounds)) } }
        let incident = graph.edges.last!
        #expect(incident.path.first.map { wall.bounds.contains($0) } == true)
        // The duplicate routes must have different shared interior lanes after bundling.
        #expect(graph.edges[0].path != graph.edges[1].path)
    }

    @Test func channelCongestionResetsBetweenCalls() throws {
        let fixture = try #require(routingFixtures.first { $0.name == "channel-off-grid-wall" })
        let graph = fixture.graph(), router = fixture.makeRouter()
        router.routeEdges(graph); let first = graph.edges.map(\.path)
        #expect(first[0] != first[1])
        router.routeEdges(graph); #expect(graph.edges.map(\.path) == first)
    }

    @Test func bspSegmentsStopAtSiblingPartition() throws {
        let fixture = try #require(routingFixtures.first { $0.name == "bsp-partition-gap" })
        let graph = fixture.graph(), calculator = BspGridCalculator()
        calculator.buildTree(graph)
        let a = try #require(graph.nodes.first { $0.id == "a" })
        let cut = try #require(calculator.getLocalGridSegments(a).first { abs($0.start.y - 260) < 1e-7 && $0.start.y == $0.end.y })
        #expect(cut.end.x == 500) // beyond wrapper's 450 edge, but not into sibling at 550
    }

    @Test func bspQuantizationUsesTheSameBucketsForEqualityAndHashing() {
        #expect(BspPointKey(Point(x: 0.000049, y: 1)) != BspPointKey(Point(x: 0.000051, y: 1)))
        #expect(BspPointKey(Point(x: 0.000051, y: 1)) == BspPointKey(Point(x: 0.00009, y: 1)))
        let segments = [(start: Point(x: 0, y: 0), end: Point(x: 100, y: 0)), (start: Point(x: 100.00001, y: 0), end: Point(x: 100, y: 100))]
        let graph = BspVisibilityGraph(segments)
        #expect(graph.path(from: .zero, to: Point(x: 100, y: 100)) != nil)
    }
}
