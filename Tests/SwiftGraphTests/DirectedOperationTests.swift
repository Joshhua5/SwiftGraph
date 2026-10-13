import Foundation
import Testing
@testable import SwiftGraph

struct DirectedOperationTests {
    private func graph(_ count: Int, _ pairs: [(Int, Int)]) -> LayoutGraph {
        let g = LayoutGraph()
        for i in 0..<count { g.addNode(LayoutNode(id: "node-\(i)", width: 80 + Double(i % 3) * 35, height: 32)) }
        for (s, t) in pairs { g.addEdge(LayoutEdge(source: g.nodes[s], target: g.nodes[t])) }
        return g
    }

    @Test func separatedFeedbackUsesFacingPortsWithoutGlobalDetours() throws {
        let g = graph(3, [(0, 1), (1, 0)])
        g.nodes[0].center = Point(x: 0, y: 0)
        g.nodes[1].center = Point(x: 400, y: 200)
        g.nodes[2].center = Point(x: 200, y: -500)
        let before = g.nodes.map(\.center)
        var configuration = DirectedLayoutConfiguration()
        configuration.mode = .routesOnly; configuration.feedbackEdges = [0, 1]
        let result = try DirectedLayoutOperation(configuration: configuration).apply(g)
        #expect(result.unroutableEdges.isEmpty && result.sharedRuns == 0)
        #expect(g.nodes.map(\.center) == before)
        for (i, edge) in g.edges.enumerated() {
            let first = try #require(edge.path.first), last = try #require(edge.path.last)
            #expect(first.y == (i == 0 ? edge.source.bounds.bottom : edge.source.bounds.top))
            #expect(last.y == (i == 0 ? edge.target.bounds.top : edge.target.bounds.bottom))
            #expect(edge.path.allSatisfy { $0.y >= g.nodes[0].bounds.bottom && $0.y <= g.nodes[1].bounds.top })
        }
    }

    @Test(arguments: [false, true]) func refinementRemovesJogsWithoutMovingPortsOrCrossingObstacles(blockShortcut: Bool) throws {
        let g = graph(3, [(0, 1)])
        g.nodes[0].center = .zero
        g.nodes[1].center = Point(x: 400, y: 100)
        // This obstacle blocks one of the two possible shortcuts.
        g.nodes[2].bounds = Rect(x: 140, y: 80, width: 40, height: 40)
        let edge = g.edges[0], before = g.nodes.map(\.bounds)
        edge.path = [Point(x: g.nodes[0].bounds.right, y: 0), Point(x: 110, y: 0),
            Point(x: 110, y: 60), Point(x: 220, y: 60), Point(x: 220, y: 100),
            Point(x: g.nodes[1].bounds.left, y: 100)]
        let original = edge.path
        if blockShortcut {
            let upper = LayoutNode(id: "upper", width: 20, height: 20)
            let lower = LayoutNode(id: "lower", width: 20, height: 20)
            upper.center = Point(x: 200, y: -100); lower.center = Point(x: 200, y: 35)
            g.addNode(upper); g.addNode(lower)
            let blocker = LayoutEdge(source: upper, target: lower)
            blocker.path = [Point(x: 200, y: -90), Point(x: 200, y: 25)]
            g.addEdge(blocker)
        }
        let edgeIndices = Dictionary(uniqueKeysWithValues: g.edges.enumerated().map { ($0.element, $0.offset) })
        let router = DirectedRouter(nodes: g.nodes, edges: g.edges, feedback: [], edgeIndices: edgeIndices,
            configuration: .init(), pitch: 12)
        try router.refine()
        #expect(edge.path.count == (blockShortcut ? 6 : 4))
        #expect(edge.path.first == original.first && edge.path.last == original.last)
        #expect(Array(g.nodes.prefix(3)).map(\.bounds) == before)
        #expect(zip(edge.path, edge.path.dropFirst()).allSatisfy { DirectedGeometry.clear($0, $1, bodies: before) })
        #expect(try DirectedGeometry.measure(nodes: g.nodes, edges: g.edges).crossings == 0)
    }

    @Test func parallelReciprocalSelfAndHighDegreePortsStayDistinct() throws {
        let g = graph(20, [(0, 1), (0, 1), (1, 0), (0, 0)] + (2..<20).map { (0, $0) })
        var config = DirectedLayoutConfiguration(); config.feedbackEdges = [2]
        let result = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(result.unroutableEdges.isEmpty)
        #expect(result.sharedRuns == 0 && result.overlappingNodeIDs.isEmpty)
        #expect(g.nodes[0].height > 32)
        let ports = g.edges.filter { $0.source === g.nodes[0] && $0.target !== g.nodes[0] }.map { $0.path[0] }
        for i in ports.indices { for j in ports.indices where j > i { #expect((ports[i] - ports[j]).length >= config.portSpacing - 0.001) } }
        for edge in g.edges {
            #expect(zip(edge.path, edge.path.dropFirst()).allSatisfy { DirectedGeometry.clear($0, $1, bodies: g.nodes.map(\.bounds)) })
        }
    }

    @Test func incrementalInsertionAndImpossibleFixedConstraintsAreExplicit() throws {
        let g = graph(3, [(0, 1)])
        try DirectedLayoutOperation().apply(g)
        let prior = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.bounds) })
        let new = LayoutNode(id: "expanded", width: 200, height: 32); g.addNode(new)
        g.addEdge(LayoutEdge(source: g.nodes[0], target: new))
        var config = DirectedLayoutConfiguration(); config.mode = .incremental
        config.previousBounds = prior; config.fixedNodeIDs = [g.nodes[0].id]
        config.insertionOrigins[new.id] = g.nodes[1].center
        let result = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(result.unroutableEdges.isEmpty && result.overlappingNodeIDs.isEmpty)
        for node in g.nodes.dropLast() { #expect(node.center == prior[node.id]?.center) }
        config.mode = .routesOnly
        config.previousBounds = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.bounds) })
        config.previousBounds[g.nodes[1].id] = config.previousBounds[g.nodes[0].id]
        let conflict = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(!conflict.fixedNodeConflicts.isEmpty)
        #expect(!conflict.unroutableEdges.isEmpty)
        #expect(g.nodes[0].center == prior[g.nodes[0].id]?.center)
    }

    @Test func insertedNodesReserveBothRoutingEscapes() throws {
        let g = graph(2, [(0, 1)])
        g.nodes[0].center = .zero; g.nodes[1].center = Point(x: 400, y: 0)
        let prior = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.bounds) })
        var config = DirectedLayoutConfiguration()
        config.mode = .incremental; config.previousBounds = prior
        config.nodeSpacing = 8; config.clearance = 20
        for (i, width) in [222.0, 248.0, 200.0].enumerated() {
            let node = LayoutNode(id: "inserted-\(i)", width: width, height: 25)
            g.addNode(node); g.addEdge(LayoutEdge(source: g.nodes[0], target: node))
            config.insertionOrigins[node.id] = g.nodes[1].center
        }
        let report = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(report.unroutableEdges.isEmpty && report.overlappingNodeIDs.isEmpty)
        for node in g.nodes.prefix(2) { #expect(node.center == prior[node.id]?.center) }
        for node in g.nodes.dropFirst(2) {
            for other in g.nodes where other !== node {
                #expect(!node.bounds.inflated(by: config.clearance * 2).intersects(other.bounds))
            }
        }
    }

    @Test func cancelledOperationDoesNotPublishPartialGeometry() async throws {
        let task = Task {
            let g = graph(180, (1..<180).flatMap { [(0, $0), ($0, ($0 + 1) % 180)] })
            let before = g.nodes.map(\.bounds)
            while !Task.isCancelled { await Task.yield() }
            do { try DirectedLayoutOperation().apply(g); Issue.record("Cancelled operation completed") }
            catch is CancellationError { #expect(g.nodes.map(\.bounds) == before); #expect(g.edges.allSatisfy { $0.path.isEmpty }) }
        }
        task.cancel(); try await task.value
    }

    @Test func feedbackOnlyConnectivityAndRoutesOnlyInputBounds() throws {
        let g = graph(2, [(1, 0)])
        var config = DirectedLayoutConfiguration(); config.feedbackEdges = [0]
        let report = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(report.feedbackEdgeIndices == [0] && report.unroutableEdges.isEmpty)
        let before = g.nodes.map(\.center)
        config.mode = .routesOnly
        let routed = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(g.nodes.map(\.center) == before && routed.unroutableEdges.isEmpty)
    }

    @Test func explicitPinsConstrainFreshRequestsToo() throws {
        let g = graph(3, [(0, 1), (1, 2)])
        g.nodes[0].center = Point(x: 321, y: -456)
        var config = DirectedLayoutConfiguration(); config.fixedNodeIDs = [g.nodes[0].id]
        let result = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(g.nodes[0].center == Point(x: 321, y: -456))
        #expect(result.overlappingNodeIDs.isEmpty && result.unroutableEdges.isEmpty)
    }

    @Test func cacheReusesValueSnapshotsAndInvalidatesChangedGeometry() throws {
        let cache = DirectedLayoutCache(capacity: 2), first = graph(4, [(0, 1), (1, 2)])
        let operation = DirectedLayoutOperation(cache: cache)
        let initial = try operation.apply(first)
        #expect(initial.cachedComponents == 0)
        let again = graph(4, [(0, 1), (1, 2)])
        let reused = try operation.apply(again)
        #expect(reused.cachedComponents == 2)
        #expect(first.nodes.map(\.bounds) == again.nodes.map(\.bounds))
        #expect(first.edges.map(\.path) == again.edges.map(\.path))
        let changed = graph(4, [(0, 1), (1, 2)]); changed.nodes[0].width = 600
        let rebuilt = try operation.apply(changed)
        #expect(rebuilt.cachedComponents == 1)
        #expect(changed.nodes[0].width == 600)
        #expect(rebuilt.unroutableEdges.isEmpty)
    }

    private func layers(_ widths: [Int], seed: Int = 7) -> LayoutGraph {
        // Deterministic layered graph with forward, long and feedback links.
        let g = LayoutGraph(); var state = seed
        func next(_ n: Int) -> Int { state = (state &* 1103515245 &+ 12345) & 0x7fffffff; return state % n }
        var rows: [[Int]] = []
        for (r, w) in widths.enumerated() { rows.append((0..<w).map { _ in g.addNode(LayoutNode(id: "r\(r)-\(g.nodes.count)", width: 60 + Double(next(4)) * 20, height: 30)); return g.nodes.count - 1 }) }
        for r in 0..<(rows.count - 1) { for a in rows[r] {
            g.addEdge(LayoutEdge(source: g.nodes[a], target: g.nodes[rows[r + 1][next(rows[r + 1].count)]]))
            if next(3) == 0, r + 2 < rows.count { g.addEdge(LayoutEdge(source: g.nodes[a], target: g.nodes[rows[r + 2][next(rows[r + 2].count)]])) }
        } }
        for _ in 0..<(widths.count / 2) { g.addEdge(LayoutEdge(source: g.nodes[rows.last![0]], target: g.nodes[rows[0][next(rows[0].count)]])) }
        return g
    }

    @Test func edgeSpacingKeepsParallelRunsApartAndIsReported() throws {
        let g = layers([3, 4, 4, 3, 2])
        var config = DirectedLayoutConfiguration(); config.edgeSpacing = 12
        let report = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(report.unroutableEdges.isEmpty && report.sharedRuns == 0 && report.overlappingNodeIDs.isEmpty)
        #expect(report.proximateRuns == 0)
        #expect(try DirectedGeometry.measure(nodes: g.nodes, edges: g.edges, spacing: config.edgeSpacing).proximity == report.proximateRuns)
    }

    @Test func proximityRanksAfterSharingAndAlongsideCrossings() throws {
        let g = LayoutGraph()
        for i in 0..<2 { g.addNode(LayoutNode(id: "\(i)", width: 10, height: 10)) }
        let a = LayoutEdge(source: g.nodes[0], target: g.nodes[1]), b = LayoutEdge(source: g.nodes[0], target: g.nodes[1])
        g.addEdge(a); g.addEdge(b)
        a.path = [Point(x: 0, y: 0), Point(x: 100, y: 0)]
        b.path = [Point(x: 0, y: 4), Point(x: 100, y: 4)]
        var near = try DirectedGeometry.measure(nodes: [], edges: g.edges, spacing: 10)
        #expect(near.proximity == 1 && near.shared == 0)
        b.path = [Point(x: 0, y: 40), Point(x: 100, y: 40)]
        let apart = try DirectedGeometry.measure(nodes: [], edges: g.edges, spacing: 10)
        #expect(apart.proximity == 0)
        // One proximate pair weighs several crossings, but never outweighs sharing.
        var few = apart, many = apart
        few.crossings = 3
        many.crossings = 5
        #expect(few.precedes(near) && near.precedes(many))
        near.shared = 0; var sharing = apart; sharing.shared = 1; sharing.proximity = 0
        #expect(near.precedes(sharing))
    }

    @Test func feedbackPortsNestArcsWithoutCrossings() throws {
        // Two right-going arcs leave one node: the farther arc is outer, its port nearer the centre.
        let g = graph(3, [(0, 1), (0, 2)])
        g.nodes[0].center = .zero; g.nodes[1].center = Point(x: 300, y: 0); g.nodes[2].center = Point(x: 700, y: 0)
        var config = DirectedLayoutConfiguration(); config.mode = .routesOnly; config.feedbackEdges = [0, 1]
        let report = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(report.unroutableEdges.isEmpty && report.crossings == 0 && report.sharedRuns == 0)
        let near = try #require(g.edges[0].path.first), far = try #require(g.edges[1].path.first)
        #expect(far.x < near.x && near.y == g.nodes[0].bounds.top && far.y == near.y)
        // Loops on one node nest and stay clear of arcs that leave beside them.
        let h = graph(2, [(0, 0), (0, 0), (0, 1)])
        h.nodes[0].center = .zero; h.nodes[1].center = Point(x: 400, y: 0)
        config.feedbackEdges = [2]
        let loops = try DirectedLayoutOperation(configuration: config).apply(h)
        #expect(loops.unroutableEdges.isEmpty && loops.crossings == 0 && loops.sharedRuns == 0)
    }

    @Test func blockedSidesFallBackToAnotherSideInsteadOfAnEmptyPath() throws {
        let g = graph(3, [(0, 1)])
        g.nodes[0].center = .zero; g.nodes[1].center = Point(x: 400, y: 0)
        // The neighbour hugs the source's right side, leaving no escape on the assigned side.
        g.nodes[2].center = Point(x: g.nodes[0].bounds.right + 4 + g.nodes[2].width / 2, y: 0)
        var config = DirectedLayoutConfiguration(); config.mode = .routesOnly
        let report = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(report.unroutableEdges.isEmpty)
        let path = try #require(g.edges[0].path.first)
        #expect(path.x != g.nodes[0].bounds.right)
        for edge in g.edges { #expect(zip(edge.path, edge.path.dropFirst()).allSatisfy { DirectedGeometry.clear($0, $1, bodies: g.nodes.map(\.bounds)) }) }
    }

    @Test func incrementalKeepsPriorPortsAndRoutesAndSlotsNewEdgesIntoGaps() throws {
        let g = layers([2, 3, 3, 2])
        try DirectedLayoutOperation().apply(g)
        let before = g.edges.map(\.path)
        var config = DirectedLayoutConfiguration(); config.mode = .incremental
        config.previousBounds = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.bounds) })
        config.previousPaths = Dictionary(uniqueKeysWithValues: g.edges.enumerated().map { ($0.offset, $0.element.path) })
        let added = LayoutEdge(source: g.nodes[0], target: g.nodes[g.nodes.count - 1]); g.addEdge(added)
        let report = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(report.unroutableEdges.isEmpty && report.displacement == 0)
        let moved = zip(before, g.edges).filter { $0.count != $1.path.count || zip($0, $1.path).contains { ($0 - $1).length > 1e-6 } }.count
        #expect(moved <= 2)
        #expect(added.path.first.map { p in g.edges.dropLast().allSatisfy { $0.source !== g.nodes[0] || ($0.path[0] - p).length >= 10 } } == true)
    }

    @Test func routesOnlyFeedbackLanesFollowOccupancyNotEdgeIndex() throws {
        let g = layers([2, 3, 3, 3, 2], seed: 3)
        for i in 0..<30 { g.addEdge(LayoutEdge(source: g.nodes[g.nodes.count - 1 - i % 3], target: g.nodes[i % 2])) }
        try DirectedLayoutOperation().apply(g)
        let drawing = DirectedGeometry.bounds(nodes: g.nodes, edges: [])
        var config = DirectedLayoutConfiguration(); config.mode = .routesOnly
        config.feedbackEdges = Set(g.edges.indices.filter { g.edges[$0].source.center.x > g.edges[$0].target.center.x })
        let report = try DirectedLayoutOperation(configuration: config).apply(g)
        #expect(report.unroutableEdges.isEmpty)
        let reach = DirectedGeometry.bounds(nodes: g.nodes, edges: g.edges)
        // Lanes stack outward by spacing, not by edge index times the port pitch.
        #expect(reach.height < drawing.height + Double(g.edges.count) * config.edgeSpacing)
    }

    @Test func denseLayeredGraphStaysRoutableAndFast() throws {
        let g = layers([8, 10, 10, 10, 8, 6], seed: 11)
        let start = ContinuousClock.now
        let report = try DirectedLayoutOperation().apply(g)
        #expect(report.unroutableEdges.isEmpty && report.sharedRuns == 0 && report.overlappingNodeIDs.isEmpty)
        #expect(start.duration(to: .now) < .seconds(30))
        for edge in g.edges { #expect(zip(edge.path, edge.path.dropFirst()).allSatisfy { DirectedGeometry.clear($0, $1, bodies: g.nodes.map(\.bounds)) }) }
    }
}
