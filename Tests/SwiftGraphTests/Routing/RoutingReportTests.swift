import Foundation
import Testing

@testable import SwiftGraph

/// Every router reports through the same `RoutingReport`: unroutable, unseparated and fallback edges as indices
/// into `graph.edges`.
@Suite struct RoutingReportTests {
    // MARK: - Fixtures

    private func node(_ graph: LayoutGraph, _ id: String, _ bounds: Rect) -> LayoutNode {
        let node = LayoutNode(id: id, width: bounds.width, height: bounds.height)
        node.bounds = bounds
        graph.addNode(node)
        return node
    }

    @discardableResult
    private func edge(_ graph: LayoutGraph, _ source: LayoutNode, _ target: LayoutNode) -> LayoutEdge {
        let edge = LayoutEdge(source: source, target: target)
        graph.addEdge(edge)
        return edge
    }

    /// A source at the origin and a target sealed inside a closed ring of walls, so no router can reach it.
    private func sealedTarget() -> (graph: LayoutGraph, source: LayoutNode, target: LayoutNode) {
        let graph = LayoutGraph()
        let source = node(graph, "s", Rect(x: 0, y: 0, width: 40, height: 40))
        let target = node(graph, "t", Rect(x: 400, y: 0, width: 40, height: 40))
        node(graph, "north", Rect(x: 370, y: -40, width: 100, height: 30))
        node(graph, "south", Rect(x: 370, y: 50, width: 100, height: 30))
        node(graph, "west", Rect(x: 370, y: -40, width: 20, height: 120))
        node(graph, "east", Rect(x: 450, y: -40, width: 20, height: 120))
        return (graph, source, target)
    }

    /// The sealed fixture with one free edge before the sealed one, so indices are not trivially zero.
    private func sealedWithFreeEdge() -> LayoutGraph {
        let (graph, source, target) = sealedTarget()
        let free = node(graph, "free", Rect(x: 0, y: 300, width: 40, height: 40))
        edge(graph, source, free)
        edge(graph, source, target)
        return graph
    }

    // MARK: - Report type

    @Test func reportNormalisesIndicesAndMapsEdges() {
        let report = RoutingReport(unroutable: [3, 1, 3], unseparated: [], fallbacks: [2, 2])
        #expect(report.unroutable == [1, 3] && report.fallbacks == [2] && !report.isEmpty)
        #expect(RoutingReport().isEmpty)

        let (graph, source, target) = sealedTarget()
        let sealed = edge(graph, source, target)
        let foreign = LayoutEdge(source: source, target: target)
        let built = RoutingReport(graph, unroutable: [sealed, foreign], fallbacks: [sealed])
        #expect(built.unroutable == [0] && built.fallbacks == [0])
        #expect(built.unroutableEdges(in: graph) == [sealed] && built.fallbackEdges(in: graph) == [sealed])
    }

    @Test func routersThatOnlyAdjustRoutesReportNothing() {
        let graph = sealedWithFreeEdge()
        let routers: [any EdgeRouter] = [CurveFittingEdgeRouter(), PortDistributor()]
        for router in routers {
            #expect(router.route(graph).isEmpty)
        }
    }

    // MARK: - Routers that search

    @Test func polylineReportsUnroutableAsFallback() {
        let graph = sealedWithFreeEdge()
        let router = PolylineEdgeRouter()
        let report = router.route(graph)
        #expect(report.unroutable == [1] && report.fallbacks == [1])
        #expect(router.report == report)
    }

    @Test func channelReportsUnroutableAsFallback() {
        let graph = sealedWithFreeEdge()
        let report = ChannelEdgeRouter().route(graph)
        #expect(report.unroutable == [1] && report.fallbacks == [1])
    }

    @Test func bspReportsUnroutableAsFallback() {
        let graph = sealedWithFreeEdge()
        let report = BspEdgeRouter().route(graph)
        #expect(report.unroutable == [1] && report.fallbacks == [1])
    }

    @Test func groupedReportsUnroutableAsFallback() {
        let graph = sealedWithFreeEdge()
        let report = OrthogonalGroupedEdgeRouter().route(graph)
        #expect(report.unroutable == [1] && report.fallbacks == [1])
    }

    @Test func bundlingReportsUnroutable() {
        let graph = sealedWithFreeEdge()
        let report = EdgeBundlingRouter().route(graph)
        #expect(report.unroutable == [1])
    }

    @Test func selfLoopReportsLoopsWithNoClearCorner() {
        let graph = LayoutGraph()
        let boxed = node(graph, "boxed", Rect(x: 0, y: 0, width: 40, height: 40))
        node(graph, "top", Rect(x: -20, y: -20, width: 80, height: 18))
        node(graph, "bottom", Rect(x: -20, y: 42, width: 80, height: 18))
        node(graph, "left", Rect(x: -20, y: -20, width: 18, height: 80))
        node(graph, "right", Rect(x: 42, y: -20, width: 18, height: 80))
        edge(graph, graph.nodes[1], graph.nodes[2])
        edge(graph, boxed, boxed)
        let report = SelfLoopRouter().route(graph)
        #expect(report.unroutable == [1] && report.fallbacks.isEmpty)
    }

    // MARK: - Routers that used to report nothing

    @Test func octilinearReportsEdgesThatCutANodeUnderBothShapes() {
        let graph = LayoutGraph()
        let a = node(graph, "a", Rect(x: -10, y: -10, width: 20, height: 20))
        let b = node(graph, "b", Rect(x: 190, y: 90, width: 20, height: 20))
        let c = node(graph, "c", Rect(x: -10, y: 290, width: 20, height: 20))
        let d = node(graph, "d", Rect(x: 390, y: 290, width: 20, height: 20))
        node(graph, "wall", Rect(x: 80, y: -60, width: 40, height: 220))
        node(graph, "bar", Rect(x: 190, y: 280, width: 20, height: 40))
        edge(graph, a, b)
        edge(graph, c, d)
        let free = edge(graph, a, c)
        let report = OctilinearEdgeRouter().route(graph)
        #expect(report.unroutable == [0, 1])
        #expect(graph.edges.firstIndex(of: free).map { !report.unroutable.contains($0) } == true)
    }

    @Test func parallelReportsDetoursAndBlockedLanes() {
        let open = LayoutGraph()
        let a = node(open, "a", Rect(x: 0, y: 0, width: 40, height: 40))
        let b = node(open, "b", Rect(x: 400, y: 0, width: 40, height: 40))
        node(open, "middle", Rect(x: 180, y: -60, width: 80, height: 160))
        edge(open, a, b)
        edge(open, a, b)
        let detoured = ParallelEdgeRouter().route(open)
        #expect(detoured.fallbacks == [0, 1] && detoured.unroutable.isEmpty)

        let (sealed, source, target) = sealedTarget()
        edge(sealed, source, target)
        edge(sealed, target, source)
        let blocked = ParallelEdgeRouter().route(sealed)
        #expect(blocked.unroutable == [0, 1] && blocked.fallbacks.isEmpty)
    }

    @Test func busReportsDetouredAndBlockedLegs() {
        let (graph, hub, sealed) = sealedTarget()
        let up = node(graph, "up", Rect(x: 0, y: -300, width: 40, height: 40))
        let down = node(graph, "down", Rect(x: 0, y: 300, width: 40, height: 40))
        edge(graph, hub, up)
        edge(graph, hub, down)
        edge(graph, hub, sealed)
        let report = BusEdgeRouter().route(graph)
        #expect(report.unroutable.contains(2) && report.fallbacks.contains(2))
        #expect(Set(report.unroutable).isSubset(of: Set(report.fallbacks)))
    }

    // MARK: - Separation

    @Test func separatorReportsUnseparatedEdges() {
        // Two routes share a stretch through a slot too narrow for a second lane.
        let graph = LayoutGraph()
        let a = node(graph, "a", Rect(x: -20, y: -20, width: 40, height: 40))
        let b = node(graph, "b", Rect(x: 380, y: -20, width: 40, height: 40))
        node(graph, "above", Rect(x: 150, y: -60, width: 100, height: 58))
        node(graph, "below", Rect(x: 150, y: 2, width: 100, height: 58))
        for _ in 0..<2 {
            let e = edge(graph, a, b)
            e.path = [a.center, b.center]
        }
        let separator = EdgeSeparator()
        let report = separator.route(graph)
        #expect(!report.unseparated.isEmpty && report.unroutable.isEmpty && report.fallbacks.isEmpty)
    }

    // MARK: - Async operation

    @Test func routingOperationCarriesTheRouterReport() async throws {
        let graph = sealedWithFreeEdge()
        let operation = RoutingLayoutOperation(.polyline, backend: .cpu)
        try await operation.applyLayoutAsync(graph)
        #expect(operation.report.unroutable == [1] && operation.report.fallbacks == [1])

        let octilinear = LayoutGraph()
        let a = node(octilinear, "a", Rect(x: -10, y: -10, width: 20, height: 20))
        let b = node(octilinear, "b", Rect(x: 390, y: -10, width: 20, height: 20))
        node(octilinear, "wall", Rect(x: 180, y: -50, width: 40, height: 100))
        edge(octilinear, a, b)
        let straight = RoutingLayoutOperation(.octilinear, backend: .cpu)
        try await straight.applyLayoutAsync(octilinear)
        #expect(straight.report.unroutable == [0])
    }

    @Test @available(*, deprecated)
    func deprecatedAccessorsAgreeWithTheReport() async throws {
        let graph = sealedWithFreeEdge()
        let polyline = PolylineEdgeRouter()
        polyline.routeEdges(graph)
        #expect(polyline.unroutableEdges == polyline.report.unroutableEdges(in: graph))
        #expect(polyline.unseparatedEdges == polyline.report.unseparatedEdges(in: graph))

        let operation = RoutingLayoutOperation(.polyline, backend: .cpu)
        try await operation.applyLayoutAsync(sealedWithFreeEdge())
        #expect(operation.unroutableEdgeIndices == operation.report.unroutable)
    }
}
