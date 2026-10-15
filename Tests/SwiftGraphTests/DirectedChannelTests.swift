import Testing
@testable import SwiftGraph

struct DirectedChannelTests {
    @Test func disjointSpansReuseTracksAndOverlapsSeparate() throws {
        let segments = [DirectedChannelSegment(id: 0, source: 0, target: 40),
                        DirectedChannelSegment(id: 1, source: 60, target: 100)]
        let allocation = try DirectedChannelAllocation.solve(segments, clearance: 6)
        #expect(allocation.slots[0] == allocation.slots[1])
        #expect(allocation.count == 1)
        let overlapping = try DirectedChannelAllocation.solve([segments[0], .init(id: 2, source: 20, target: 80)], clearance: 6)
        #expect(overlapping.slots[0] != overlapping.slots[2])
        #expect(overlapping.count == 2)
    }

    @Test func endpointOrderAvoidsTwoUnnecessaryCrossings() throws {
        let allocation = try DirectedChannelAllocation.solve([
            .init(id: 0, source: 0, target: 60), .init(id: 1, source: 30, target: 90)], clearance: 6)
        #expect(try #require(allocation.slots[1]) < #require(allocation.slots[0]))
    }

    @Test func straightConnectionsConsumeNoTrackAndNearSpansStaySeparate() throws {
        let allocation = try DirectedChannelAllocation.solve([
            .init(id: 0, source: 0, target: 0), .init(id: 1, source: 10, target: 40),
            .init(id: 2, source: 44, target: 70)], clearance: 6)
        #expect(allocation.slots[0] == nil)
        #expect(allocation.slots[1] != allocation.slots[2])
    }

    @Test func conflictingPreferencesRemainDeterministicAndClear() throws {
        let segments = (0..<24).map { i in
            DirectedChannelSegment(id: i, source: Float((i * 37) % 113), target: Float((i * 61 + 19) % 127))
        }
        let a = try DirectedChannelAllocation.solve(segments, clearance: 6)
        let b = try DirectedChannelAllocation.solve(segments.reversed(), clearance: 6)
        #expect(a.slots == b.slots)
        for i in segments.indices { for j in segments.indices where j > i {
            if segments[i].low < segments[j].high + 6 && segments[j].low < segments[i].high + 6 {
                #expect(a.slots[segments[i].id] != a.slots[segments[j].id])
            }
        } }
    }

    @Test func virtualRunAlignmentPreservesObstacleSide() throws {
        let g = LayoutGraph()
        for (i, p) in [Point(x: 0, y: 0), Point(x: 200, y: 100), Point(x: 400, y: 0)].enumerated() {
            let n = LayoutNode(id: "\(i)", width: 60, height: 40); n.center = p; g.addNode(n)
        }
        let edge = LayoutEdge(source: g.nodes[0], target: g.nodes[2]); g.addEdge(edge)
        edge.path = [g.nodes[0].center, Point(x: 200, y: 30), g.nodes[2].center]
        let plan = DirectedChannelPlan(nodes: g.nodes, edges: [edge], feedback: [],
            ports: [edge: (Point(x: 30, y: 0), Point(x: 370, y: 0), Point(x: 1, y: 0), Point(x: -1, y: 0))],
            edgeIndices: [edge: 0], clearance: 10, spacing: 6)
        let path = try #require(try plan.apply(minimumGap: 60)[edge])
        #expect(path.count == 2 && path.allSatisfy { $0.y == 0 })
        #expect(zip(path, path.dropFirst()).allSatisfy { DirectedGeometry.clear($0, $1, bodies: g.nodes.map(\.bounds)) })
        #expect(g.nodes[2].center.x < 400)
    }

    @Test func drawingCompactionPreservesCrossingsBodiesAndAttachments() throws {
        let g = LayoutGraph()
        for (i, p) in [Point(x: 0, y: 0), Point(x: 1000, y: 500), Point(x: 0, y: 400), Point(x: 1000, y: 100)].enumerated() {
            let n = LayoutNode(id: "\(i)", width: 80, height: 40); n.center = p; g.addNode(n)
        }
        for (s, t, x) in [(0, 1, Float(400.0)), (2, 3, Float(600.0))] {
            let e = LayoutEdge(source: g.nodes[s], target: g.nodes[t])
            e.path = [Point(x: 40, y: e.source.center.y), Point(x: x, y: e.source.center.y),
                      Point(x: x, y: e.target.center.y), Point(x: 960, y: e.target.center.y)]
            g.addEdge(e)
        }
        let before = try DirectedGeometry.measure(nodes: g.nodes, edges: g.edges)
        #expect(before.crossings == 1)
        try DirectedDrawingCompaction.apply(nodes: g.nodes, edges: g.edges, clearance: 10, spacing: 10, layerSpacing: 100, nodeSpacing: 32)
        let after = try DirectedGeometry.measure(nodes: g.nodes, edges: g.edges)
        #expect(after.crossings == before.crossings && after.bends == before.bends)
        #expect(after.length < before.length && after.area < before.area)
        #expect(after.overlaps == 0 && after.shared == 0)
        for e in g.edges {
            #expect(e.path.first == Point(x: e.source.bounds.right, y: e.source.center.y))
            #expect(e.path.last == Point(x: e.target.bounds.left, y: e.target.center.y))
            #expect(zip(e.path, e.path.dropFirst()).allSatisfy { DirectedGeometry.clear($0, $1, bodies: g.nodes.map(\.bounds)) })
        }
        #expect(g.nodes.allSatisfy { $0.width == 80 && $0.height == 40 })
    }

    @Test func unpreferredNestedPairsAddNoDepth() throws {
        let allocation = try DirectedChannelAllocation.solve([
            .init(id: 0, source: 0, target: 100), .init(id: 1, source: 10, target: 30), .init(id: 2, source: 60, target: 90)], clearance: 6)
        #expect(allocation.count == 2)
        #expect(allocation.slots[1] == allocation.slots[2] && allocation.slots[0] != allocation.slots[1])
    }

    @Test func channelTracksSpreadAcrossTheGapAtEdgeSpacing() throws {
        let g = LayoutGraph()
        let points = [Point(x: 0, y: 0), Point(x: 0, y: 80), Point(x: 400, y: 80), Point(x: 400, y: 0)]
        for (i, p) in points.enumerated() { let n = LayoutNode(id: "\(i)", width: 60, height: 40); n.center = p; g.addNode(n) }
        let edges = [LayoutEdge(source: g.nodes[0], target: g.nodes[2]), LayoutEdge(source: g.nodes[1], target: g.nodes[3])]
        var ports: [LayoutEdge: (Point, Point, Point, Point)] = [:]
        for e in edges {
            g.addEdge(e); e.path = [e.source.center, e.target.center]
            ports[e] = (Point(x: 30, y: e.source.center.y), Point(x: 370, y: e.target.center.y), Point(x: 1, y: 0), Point(x: -1, y: 0))
        }
        let plan = DirectedChannelPlan(nodes: g.nodes, edges: edges, feedback: [], ports: ports,
            edgeIndices: [edges[0]: 0, edges[1]: 1], clearance: 10, spacing: 10)
        let paths = try plan.apply(minimumGap: 100)
        let xs = try edges.map { e -> Float in
            let path = try #require(paths[e])
            return path[1].x
        }.sorted()
        let low = g.nodes[0].bounds.right + 10, high = g.nodes[2].bounds.left - 10
        #expect(xs[0] > low && xs[1] < high && xs[1] - xs[0] >= 10)
        #expect(abs((xs[0] - low) - (high - xs[1])) < 1e-4)
        #expect(g.nodes[2].bounds.left - g.nodes[0].bounds.right >= 100)
    }

    @Test func compactionNeverShrinksLayerOrNodeGapsBelowSpacing() throws {
        let g = LayoutGraph()
        for (i, p) in [Point(x: 0, y: 0), Point(x: 900, y: 0), Point(x: 0, y: 500), Point(x: 900, y: 500)].enumerated() {
            let n = LayoutNode(id: "\(i)", width: 80, height: 40); n.center = p; g.addNode(n)
        }
        let e = LayoutEdge(source: g.nodes[0], target: g.nodes[1]); g.addEdge(e)
        e.path = [Point(x: 40, y: 0), Point(x: 300, y: 0), Point(x: 300, y: -30), Point(x: 500, y: -30), Point(x: 500, y: 0), Point(x: 860, y: 0)]
        try DirectedDrawingCompaction.apply(nodes: g.nodes, edges: g.edges, clearance: 10, spacing: 10, layerSpacing: 120, nodeSpacing: 60)
        #expect(g.nodes[1].bounds.left - g.nodes[0].bounds.right >= 120 - 1e-4)
        #expect(g.nodes[2].bounds.top - g.nodes[0].bounds.bottom >= 60 - 1e-4)
        // Tracks inside the gap still keep their spacing.
        let verticals = Set(e.path.map(\.x)).sorted().filter { $0 > g.nodes[0].bounds.right && $0 < g.nodes[1].bounds.left }
        #expect(zip(verticals, verticals.dropFirst()).allSatisfy { $1 - $0 >= 10 - 1e-4 })
    }
}
