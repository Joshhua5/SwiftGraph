import Foundation
import Testing

@testable import SwiftGraph

@Suite struct ChannelGridTests {
    private func node(_ g: LayoutGraph, _ id: String, _ r: Rect) -> LayoutNode {
        let n = LayoutNode(id: id, width: r.width, height: r.height)
        n.bounds = r
        g.addNode(n)
        return n
    }

    @Test func portsSitOnTheNodeWhereverTheSceneStarts() {
        // On the old lattice the port snapped to a line counted from the scene's corner, so an unrelated node far away
        // moved it by up to half a pitch. On the node-aligned grid it stays at the centre of the side.
        for corner: Float in [0, -37, -1013] {
            let g = LayoutGraph()
            let a = node(g, "a", Rect(x: 3, y: 0, width: 90, height: 40))
            let b = node(g, "b", Rect(x: 3, y: 300, width: 90, height: 40))
            _ = node(g, "far", Rect(x: corner - 500, y: corner - 700, width: 30, height: 30))
            let edge = LayoutEdge(source: a, target: b)
            g.addEdge(edge)
            let router = ChannelEdgeRouter()
            router.routeEdges(g)
            #expect(router.report.unroutable.isEmpty)
            #expect(edge.path == [Point(x: 48, y: 40), Point(x: 48, y: 300)], "corner \(corner): \(edge.path)")
        }
    }

    @Test func blockingKeepsTheClearanceLineFree() {
        let grid = ChannelGrid(
            obstacles: [Rect(x: 0, y: 0, width: 40, height: 40)],
            groups: [],
            anchors: .init(),
            slots: .init(),
            pitch: 20,
            clearance: 10,
            margin: 40
        )
        let column = { grid.line(at: $0, axis: .horizontal)! }
        let row = { grid.line(at: $0, axis: .vertical)! }
        // The centre lies inside the obstacle; the line the clearance away from its side does not.
        #expect(grid.isBlocked(grid.vertex(column: column(20), row: row(20)), walls: []))
        #expect(!grid.isBlocked(grid.vertex(column: column(50), row: row(20)), walls: []))
        #expect(!grid.isBlocked(grid.vertex(column: column(-10), row: row(-10)), walls: []))
    }

    @Test func congestionIsCountedPerSpanAndRemovedByOwner() {
        let grid = ChannelGrid(
            obstacles: [Rect(x: 0, y: 0, width: 40, height: 40)],
            groups: [],
            anchors: .init(),
            slots: .init(),
            pitch: 20,
            clearance: 10,
            margin: 40
        )
        var congestion = ChannelCongestion(grid, penalty: 2)
        let a = grid.vertex(column: 0, row: 0)
        let b = grid.vertex(column: 1, row: 0)
        let span = ChannelGrid.span(between: a, b, along: .horizontal)
        let first = LayoutNode(id: "first", width: 1, height: 1)
        let second = LayoutNode(id: "second", width: 1, height: 1)
        let owner = ObjectIdentifier(first)
        let other = ObjectIdentifier(second)
        let footprint = ChannelCongestion.Footprint(
            spans: [span],
            passes: [b * 2 + ChannelGrid.Axis.horizontal.rawValue]
        )
        congestion.add(footprint, owner: owner)
        congestion.add(footprint, owner: other)
        #expect(congestion.usage(ofSpan: span) == 2)
        #expect(congestion.cost(along: span, length: 40) == 8)  // two routes, a penalty of 2, two pitches long
        #expect(congestion.crossingCost(at: b, along: .vertical) == 4)  // crossing two routes, the penalty each
        #expect(congestion.overuse(grid) == 2)  // one route beyond the first, two pitches long
        congestion.escalate()  // one history unit, a tenth of the penalty per pitch
        #expect(abs(congestion.cost(along: span, length: 40) - 8.4) < 1e-4)
        #expect(abs(congestion.sharingCost(of: other, grid) - 4.4) < 1e-4)
        congestion.remove(owner: owner)
        #expect(congestion.usage(ofSpan: span) == 1)
        congestion.add(footprint, owner: other)  // replacing an owner's route does not count it twice
        #expect(congestion.usage(ofSpan: span) == 1)
        congestion.remove(owner: other)
        #expect(congestion.usage(ofSpan: span) == 0 && congestion.isEmpty)
        withExtendedLifetime((first, second)) {}
    }
}
