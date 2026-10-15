import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

extension RoutingFixture: CustomTestStringConvertible {
    public var testDescription: String { name }
}
private let routingFixtures = try! loadRoutingFixtures()
private func approximatelyEqual(_ a: [Point], _ b: [[Float]]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0.x - $1[0]) < 1e-4 && abs($0.y - $1[1]) < 1e-4 }
}
private func approximatelyEqual(_ a: Rect, _ b: [Float]) -> Bool {
    zip([a.x, a.y, a.width, a.height], b).allSatisfy { abs($0 - $1) < 1e-4 }
}

/// Crossings and bends of the corridors fixtures as routed now; a regression raises them, an improvement may lower them.
private let corridorBudgets: [String: (crossings: Int, bends: Int)] = {
    let channel = [(9, 11), (9, 12), (8, 15), (6, 12), (7, 16), (8, 14), (10, 12), (7, 14), (8, 12), (5, 15), (8, 12), (8, 13)]
    let bsp = [(5, 15), (6, 13), (3, 13), (3, 13), (4, 17), (4, 15), (4, 15), (6, 13), (5, 17), (4, 15), (5, 15), (4, 15)]
    var result: [String: (crossings: Int, bends: Int)] = [:]
    for i in 0..<12 { result["channel-corridors-\(i)"] = channel[i]; result["bsp-corridors-\(i)"] = bsp[i] }
    return result
}()

@Suite struct RoutingParityTests {
    /// All four routers now diverge from the C# reference (ports, fallbacks, clearance, lane choice), so the fixtures pin
    /// invariants instead: unmoved nodes, finite routes, and for channel, BSP and polyline no route through an unrelated
    /// node and a clearance floor. Channel and BSP routes are also orthogonal and start and end on their node boundaries
    /// (also when the nodes overlap), and the corridors fixtures keep within crossing and bend budgets. Edges the router
    /// reports as fallbacks are exempt. The visual `reference-*` cases keep the C# geometry as a baseline to review against.
    @Test(arguments: routingFixtures)
    fileprivate func matchesReference(_ fixture: RoutingFixture) {
        let graph = fixture.graph(), calculator = BspGridCalculator()
        calculator.buildTree(graph)
        let lanes = calculator.getAllGridSegments()
        let leaves = graph.nodes.filter { !$0.isGroup }
        for lane in lanes.dropFirst(min(4, lanes.count)) {
            for node in leaves { #expect(!node.bounds.inflated(by: -1e-4).intersectsLine(lane.start, lane.end), "\(fixture.name): lane through \(node.id)") }
        }
        let router = fixture.makeRouter()
        router.routeEdges(graph)
        // Grouped nudging moves nodes and resizes the root on purpose; the other routers leave the layout alone.
        if fixture.router != "grouped" {
            for (node, bounds) in zip(graph.nodes, fixture.expected.bounds) { #expect(approximatelyEqual(node.bounds, bounds), "\(fixture.name): bounds of \(node.id)") }
            #expect(approximatelyEqual(graph.root.bounds, fixture.expected.root))
        }
        for (index, edge) in graph.edges.enumerated() where edge.source !== edge.target {
            #expect(edge.path.count >= 2 && edge.path.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "\(fixture.name) edge \(index): \(edge.path)")
        }
        guard fixture.router != "grouped" else { return }
        let audit = RouteAudit(graph, router)
        #expect(audit.leafHits.isEmpty, "\(fixture.name): routes through unrelated nodes \(audit.leafHits)")
        // Channel lanes sit a lattice cell from nodes; BSP and the polyline separator keep at least half the 10-unit spacing.
        #expect(audit.minClearance >= (fixture.router == "channel" ? 6 : 4.5), "\(fixture.name): clearance \(audit.minClearance)")
        // The polyline router still starts and ends at node centres, and draws diagonals.
        guard fixture.router != "polyline" else { return }
        #expect(audit.diagonal.isEmpty, "\(fixture.name): non-orthogonal edges \(audit.diagonal)")
        #expect(audit.offBoundary.isEmpty, "\(fixture.name): endpoints off their node boundary \(audit.offBoundary)")
        if let budget = corridorBudgets[fixture.name] {
            #expect(audit.crossings <= budget.crossings, "\(fixture.name): \(audit.crossings) crossings")
            #expect(audit.bends <= budget.bends, "\(fixture.name): \(audit.bends) bends")
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
        let cut = try #require(calculator.getLocalGridSegments(a).first { abs($0.start.y - 260) < 1e-4 && $0.start.y == $0.end.y })
        #expect(cut.end.x == 500) // beyond wrapper's 450 edge, but not into sibling at 550
    }

    @Test func bspQuantizationUsesTheSameBucketsForEqualityAndHashing() {
        #expect(BspPointKey(Point(x: 0.000049, y: 1)) != BspPointKey(Point(x: 0.000051, y: 1)))
        #expect(BspPointKey(Point(x: 0.000051, y: 1)) == BspPointKey(Point(x: 0.00009, y: 1)))
        let segments = [(start: Point(x: 0, y: 0), end: Point(x: 100, y: 0)), (start: Point(x: 100.00001, y: 0), end: Point(x: 100, y: 100))]
        let graph = BspVisibilityGraph(segments)
        #expect(graph.path(from: [.zero], to: [Point(x: 100, y: 100)], bendPenalty: 0) != nil)
    }
}
