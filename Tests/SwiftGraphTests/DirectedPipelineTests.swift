import Foundation
import Testing
@testable import SwiftGraph

struct DirectedPipelineTests {
    private func graph(_ sizes: [(Double, Double)], _ pairs: [(Int, Int)]) -> LayoutGraph {
        let g = LayoutGraph()
        for (i, size) in sizes.enumerated() { g.addNode(LayoutNode(id: "n\(i)", width: size.0, height: size.1)) }
        for (s, t) in pairs { g.addEdge(LayoutEdge(source: g.nodes[s], target: g.nodes[t])) }
        return g
    }

    private func microSegments(_ g: LayoutGraph) -> Int {
        g.edges.reduce(0) { total, edge in
            total + zip(edge.path, edge.path.dropFirst()).filter { ($1 - $0).length > 0 && ($1 - $0).length < 4 }.count
        }
    }

    @Test func chainOfMixedHeightsRoutesStraightWithoutMicroJogs() throws {
        let g = graph([(80, 40), (100, 48), (120, 32), (90, 44), (110, 36)], [(0, 1), (1, 2), (2, 3), (3, 4)])
        let result = try DirectedLayoutOperation().apply(g)
        #expect(result.unroutableEdges.isEmpty && result.crossings == 0)
        #expect(result.bends == 0)
        #expect(microSegments(g) == 0)
        for edge in g.edges { #expect(edge.path.count == 2 && abs(edge.path[0].y - edge.path[1].y) < 0.001) }
    }

    @Test func skipEdgeBesideMixedHeightChainHasNoMicroJogs() throws {
        let sizes: [(Double, Double)] = [(80, 48), (100, 40), (130, 48), (155, 32), (80, 40), (105, 48)]
        let g = graph(sizes, [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (0, 4)])
        let result = try DirectedLayoutOperation().apply(g)
        #expect(result.unroutableEdges.isEmpty && result.sharedRuns == 0 && result.proximateRuns == 0)
        print(g.nodes.map(\.bounds), g.edges.map(\.path)); #expect(microSegments(g) == 0)
        // Every chain edge is straight: only the skip edge may bend.
        for edge in g.edges.prefix(5) { #expect(edge.path.count == 2) }
    }

    @Test func veryLongEdgeKeepsVirtualNodeGuidance() throws {
        let count = 90
        let g = graph(Array(repeating: (50, 24), count: count), (1..<count).map { ($0 - 1, $0) } + [(0, count - 1)])
        var configuration = DirectedLayoutConfiguration(); configuration.candidateCount = 1
        let result = try DirectedLayoutOperation(configuration: configuration).apply(g)
        let long = try #require(g.edges.last)
        #expect(result.unroutableEdges.isEmpty && result.sharedRuns == 0)
        // An 89-rank edge used to lose its virtual chain and run straight through the row of nodes.
        for (a, b) in zip(long.path, long.path.dropFirst()) {
            #expect(g.nodes.dropFirst().dropLast().allSatisfy { DirectedGeometry.clear(a, b, bodies: [$0.bounds]) })
        }
    }

    @Test func feedbackEdgesRankAndRouteBetweenTheRanksOnFacingSides() throws {
        let g = graph(Array(repeating: (80, 32), count: 5), [(0, 1), (1, 2), (2, 3), (3, 4), (4, 0), (3, 1)])
        let result = try DirectedLayoutOperation().apply(g)
        #expect(result.feedbackEdgeIndices == [4, 5])
        #expect(result.unroutableEdges.isEmpty && result.crossings == 0 && result.sharedRuns == 0)
        let drawing = DirectedGeometry.bounds(nodes: g.nodes, edges: [])
        for index in [4, 5] {
            let edge = g.edges[index], first = try #require(edge.path.first), last = try #require(edge.path.last)
            // Out of the source's near (left) side and into the target's right side: no detour above the ranks.
            #expect(first.x == edge.source.bounds.left && last.x == edge.target.bounds.right)
            #expect(edge.path.allSatisfy { $0.y > drawing.top - 40 && $0.y < drawing.bottom + 80 })
        }
        // Ranks follow the forward edges, so the reversed ones do not stretch them.
        let xs = g.nodes.map(\.center.x)
        #expect(xs == xs.sorted())
    }

    @Test func feedbackThatWouldCloseACycleWhenReversedKeepsItsTopLane() throws {
        let g = graph(Array(repeating: (80, 32), count: 3), [(0, 1), (1, 2), (0, 2)])
        var configuration = DirectedLayoutConfiguration(); configuration.feedbackEdges = [2]
        let result = try DirectedLayoutOperation(configuration: configuration).apply(g)
        #expect(result.unroutableEdges.isEmpty)
        let first = try #require(g.edges[2].path.first)
        #expect(first.y == g.nodes[0].bounds.top)
    }

    @Test func explicitTopAndBottomPortsGrowTheNodeWidthSoPortsStaySeparated() throws {
        let g = graph([(30, 40), (30, 40)], [])
        for _ in 0..<5 {
            let edge = LayoutEdge(source: g.nodes[0], target: g.nodes[1])
            edge.sourcePort = .bottom; edge.targetPort = .top; g.addEdge(edge)
        }
        let configuration = DirectedLayoutConfiguration()
        let result = try DirectedLayoutOperation(configuration: configuration).apply(g)
        #expect(result.unroutableEdges.isEmpty && result.sharedRuns == 0)
        // Five ports on the 30-wide node's bottom would collapse to nothing without width for them.
        #expect(g.nodes.allSatisfy { $0.width >= 4 * configuration.portSpacing + 24 })
        let starts = g.edges.compactMap(\.path.first).map(\.x).sorted()
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 >= configuration.edgeSpacing })
        #expect(g.edges.allSatisfy { $0.path.first!.y == g.nodes[0].bounds.bottom })
    }

    @Test func layoutIsDeterministicWithoutJitter() throws {
        let pairs = [(0, 1), (0, 2), (1, 3), (2, 3), (3, 4), (0, 4)]
        let sizes: [(Double, Double)] = [(60, 30), (80, 40), (100, 30), (60, 40), (80, 30)]
        let a = graph(sizes, pairs), b = graph(sizes, pairs)
        _ = try DirectedLayoutOperation().apply(a); _ = try DirectedLayoutOperation().apply(b)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
    }
}

struct DirectedLayeringTests {
    private func total(_ ranks: [Int], _ edges: [(Int, Int)]) -> Int { edges.reduce(0) { $0 + ranks[$1.1] - ranks[$1.0] } }

    @Test func promotesSourcesAndSinksTowardTheirNeighbours() {
        // Longest-path layering puts n3 at rank 0 and stretches n3->n4 over three ranks.
        let edges = [(0, 1), (1, 2), (2, 4), (3, 4)]
        let ranks = DirectedLayering.ranks(count: 5, edges: edges)
        #expect(ranks[4] - ranks[3] == 1 && ranks[1] - ranks[0] == 1 && ranks[2] - ranks[1] == 1)
        #expect(total(ranks, edges) == 4)
    }

    @Test func rankingIsFeasibleAndOptimalOnSmallDags() {
        var seed: UInt64 = 7
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        for round in 0..<40 {
            let n = 3 + round % 4
            var edges: [(Int, Int)] = []
            for _ in 0..<(n + round % 3) {
                let a = next() % n, b = next() % n
                if a < b { edges.append((a, b)) } else if b < a { edges.append((b, a)) }
            }
            let ranks = DirectedLayering.ranks(count: n, edges: edges)
            #expect(edges.allSatisfy { ranks[$0.1] - ranks[$0.0] >= 1 })
            // Exhaustive minimum over rank vectors below n for each connected piece is the global optimum here.
            var best = Int.max, candidate = Array(repeating: 0, count: n)
            func search(_ i: Int) {
                if i == n {
                    if edges.allSatisfy({ candidate[$0.1] - candidate[$0.0] >= 1 }) { best = min(best, total(candidate, edges)) }
                    return
                }
                for r in 0..<n { candidate[i] = r; search(i + 1) }
            }
            search(0)
            #expect(total(ranks, edges) == best)
        }
    }

    @Test func disconnectedComponentsStartAtRankZero() {
        let ranks = DirectedLayering.ranks(count: 5, edges: [(0, 1), (3, 4)])
        #expect(ranks[0] == 0 && ranks[3] == 0 && ranks[2] == 0)
    }
}
