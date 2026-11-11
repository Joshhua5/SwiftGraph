import Foundation
import Testing

@testable import SwiftGraph

@Suite struct PortAssignmentTests {
    private func graph(_ rects: [Rect]) -> LayoutGraph {
        let g = LayoutGraph()
        for (i, r) in rects.enumerated() {
            let n = LayoutNode(id: "n\(i)", width: r.width, height: r.height)
            n.bounds = r
            g.addNode(n)
        }
        return g
    }

    @discardableResult
    private func edge(_ g: LayoutGraph, _ s: Int, _ t: Int) -> LayoutEdge {
        let e = LayoutEdge(source: g.nodes[s], target: g.nodes[t])
        g.addEdge(e)
        return e
    }

    @Test func insetIsTheLesserOfTheDefaultAndAQuarterOfTheSide() {
        let wide = PortAssignment.span(of: Rect(x: 0, y: 0, width: 100, height: 20), side: .top)
        #expect(wide.low == 10 && wide.high == 90)
        let short = PortAssignment.span(of: Rect(x: 0, y: 0, width: 100, height: 20), side: .left)
        #expect(short.low == 5 && short.high == 15)
    }

    @Test func orthogonalEndsFaceEachOtherAndSpreadOnASharedSide() {
        let g = graph([
            Rect(x: 0, y: 0, width: 60, height: 60), Rect(x: 200, y: 0, width: 60, height: 60),
            Rect(x: 200, y: 200, width: 60, height: 60),
        ])
        let a = edge(g, 0, 1)
        let b = edge(g, 0, 1)
        let ports = PortAssignment().assign(g, style: .orthogonal)
        let first = ports.source(of: a)
        let second = ports.source(of: b)
        #expect(first?.side == .right && second?.side == .right)
        #expect(ports.target(of: a)?.side == .left)
        // Both aim level with the other node's middle (30); they are spread the edge spacing apart around it, in edge
        // order at both ends so the pair does not cross.
        #expect(first?.point == Point(x: 60, y: 25) && second?.point == Point(x: 60, y: 35))
        #expect(ports.target(of: a)?.point == Point(x: 200, y: 25))
    }

    @Test func constraintsAndCandidatesChooseTheSide() {
        let g = graph([Rect(x: 0, y: 0, width: 40, height: 40), Rect(x: 200, y: 0, width: 40, height: 40)])
        let e = edge(g, 0, 1)
        e.sourcePort = .bottom
        e.targetPortCandidates = [.top, .right]
        for style in [RouteStyle.orthogonal, .polyline] {
            let ports = PortAssignment().assign(g, style: style)
            #expect(ports.source(of: e)?.side == .bottom && ports.target(of: e)?.side == .top, "\(style)")
            #expect(ports.source(of: e)?.point.y == 40 && ports.target(of: e)?.point.y == 0, "\(style)")
        }
    }

    @Test func polylineEndsSitWhereTheCentreLineLeaves() {
        let g = graph([Rect(x: 0, y: 0, width: 100, height: 20), Rect(x: 200, y: 100, width: 20, height: 20)])
        let e = edge(g, 0, 1)
        let ports = PortAssignment().assign(g, style: .polyline)
        // Centre (50, 10) to (210, 110): the line leaves the wide source through its bottom, at x = 50 + 160 / 10.
        #expect(ports.source(of: e) == EdgePort(side: .bottom, point: Point(x: 66, y: 20)))
        #expect(ports.target(of: e)?.side == .left)
    }

    @Test func overlappingEndsAndSelfLoopsGetNoPorts() {
        let g = graph([Rect(x: 0, y: 0, width: 100, height: 100), Rect(x: 20, y: 20, width: 20, height: 20)])
        let nested = edge(g, 0, 1)
        let loop = edge(g, 0, 0)
        let ports = PortAssignment().assign(g, style: .orthogonal)
        #expect(ports.source(of: nested) == nil && ports.source(of: loop) == nil && ports.isEmpty)
    }

    @Test func polylineRoutesLeaveFromTheirAssignedPortsInsteadOfOneCentre() {
        // Three targets to the right of one tall source: each route starts on the source's right side, apart.
        let g = graph([
            Rect(x: 0, y: 0, width: 40, height: 120), Rect(x: 300, y: 0, width: 40, height: 20),
            Rect(x: 300, y: 50, width: 40, height: 20), Rect(x: 300, y: 100, width: 40, height: 20),
        ])
        let edges = (1...3).map { edge(g, 0, $0) }
        PolylineEdgeRouter().routeEdges(g)
        let starts = edges.compactMap(\.path.first)
        #expect(starts.allSatisfy { $0.x == 40 })
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $1.y - $0.y >= 10 }, "\(starts)")
        #expect(edges.allSatisfy { $0.path.last?.x == 300 })
    }
}
