import CoreGraphics
import Foundation
import SwiftUI
import Testing
import SwiftGraph
import SwiftGraphUI

@Suite struct SwiftGraphUITests {
    private struct CustomNodeData: GraphNodeDescriptor {
        var nodeStyle: GraphNodeStyle?
        var groupStyle: GraphGroupStyle?
    }

    private struct CustomEdgeData: GraphEdgeDescriptor {
        var edgeLabel: String?
        var isBidirectional: Bool
        var edgeStyle: GraphEdgeStyle?
    }

    @Test func snapshotOrdersGroupsByDepthBeforeLeaves() throws {
        let graph = LayoutGraph()
        let outer = try graph.addGroup(id: "Outer")
        let inner = try graph.addGroup(id: "Inner", parent: outer)
        let leafA = LayoutNode(id: "LeafA", width: 60, height: 30)
        let leafB = LayoutNode(id: "LeafB", width: 60, height: 30)
        try graph.addNode(leafA, to: inner)
        graph.addNode(leafB)

        outer.bounds = Rect(x: 0, y: 0, width: 200, height: 200)
        inner.bounds = Rect(x: 20, y: 20, width: 140, height: 140)
        leafA.bounds = Rect(x: 40, y: 40, width: 60, height: 30)
        leafB.bounds = Rect(x: 240, y: 40, width: 60, height: 30)

        let snapshot = GraphSnapshot(graph: graph)
        #expect(snapshot.nodes.map(\.id) == ["Outer", "Inner", "LeafB", "LeafA"])
        #expect(snapshot.nodes[0].isGroup == true)
        #expect(snapshot.nodes[0].depth == 0)
        #expect(snapshot.nodes[1].isGroup == true)
        #expect(snapshot.nodes[1].depth == 1)
        #expect(snapshot.nodes[2].isGroup == false)
        #expect(snapshot.nodes[2].depth == 0)
        #expect(snapshot.nodes[3].isGroup == false)
        #expect(snapshot.nodes[3].depth == 2)
    }

    @Test func snapshotExtractsCustomNodeAndEdgeDescriptors() {
        let graph = LayoutGraph()
        let n1 = LayoutNode(
            id: "N1",
            width: 80,
            height: 36,
            data: CustomNodeData(nodeStyle: GraphNodeStyle(fill: .red, cornerRadius: 12))
        )
        n1.tags = ["critical"]
        let n2 = LayoutNode(id: "N2", width: 80, height: 36)
        n1.bounds = Rect(x: 0, y: 0, width: 80, height: 36)
        n2.bounds = Rect(x: 200, y: 0, width: 80, height: 36)
        graph.addNode(n1)
        graph.addNode(n2)

        let edge = LayoutEdge(
            source: n1,
            target: n2,
            data: CustomEdgeData(
                edgeLabel: "sync",
                isBidirectional: true,
                edgeStyle: GraphEdgeStyle(color: .purple, lineWidth: 2.5)
            )
        )
        edge.path = [Point(x: 80, y: 18), Point(x: 200, y: 18)]
        edge.labelBounds = Rect(x: 120, y: 8, width: 40, height: 16)
        graph.addEdge(edge)

        let snapshot = GraphSnapshot(graph: graph)
        #expect(snapshot.nodes.first(where: { $0.id == "N1" })?.nodeStyle?.cornerRadius == 12)
        #expect(snapshot.nodes.first(where: { $0.id == "N1" })?.tags == ["critical"])
        #expect(snapshot.edges.count == 1)
        #expect(snapshot.edges[0].sourceID == "N1")
        #expect(snapshot.edges[0].targetID == "N2")
        #expect(snapshot.edges[0].label == "sync")
        #expect(snapshot.edges[0].isBidirectional == true)
        #expect(snapshot.edges[0].style?.lineWidth == 2.5)
    }

    @Test func snapshotComputesCrossingBridges() {
        let graph = LayoutGraph()
        let a = LayoutNode(id: "A", width: 20, height: 20)
        let b = LayoutNode(id: "B", width: 20, height: 20)
        let c = LayoutNode(id: "C", width: 20, height: 20)
        let d = LayoutNode(id: "D", width: 20, height: 20)
        for n in [a, b, c, d] { graph.addNode(n) }

        let e1 = LayoutEdge(source: a, target: b)
        e1.path = [Point(x: 0, y: 50), Point(x: 100, y: 50)]
        let e2 = LayoutEdge(source: c, target: d)
        e2.path = [Point(x: 50, y: 0), Point(x: 50, y: 100)]
        graph.addEdge(e1)
        graph.addEdge(e2)

        let snapshot = GraphSnapshot(graph: graph)
        #expect(snapshot.edges[0].bridges.isEmpty)
        #expect(snapshot.edges[1].bridges.count == 1)
    }

    @Test func asyncRenderProducesSnapshotAndWorldBounds() async throws {
        let snapshot = try await GraphSnapshot.render(
            backend: .cpu,
            makeGraph: {
                let g = LayoutGraph()
                let n1 = LayoutNode(id: "Start", width: 70, height: 32)
                let n2 = LayoutNode(id: "End", width: 70, height: 32)
                g.addNode(n1)
                g.addNode(n2)
                g.addEdge(LayoutEdge(source: n1, target: n2, data: "flow"))
                return g
            },
            configure: { builder, backend in
                builder.useHierarchical(backend: backend)
                    .clipEdgeEndpoints(backend: backend)
                    .placeLabels(backend: backend)
            }
        )
        #expect(snapshot.nodes.count == 2)
        #expect(snapshot.edges.count == 1)
        #expect(snapshot.worldBounds.width > 0)
        #expect(snapshot.worldBounds.height > 0)
    }

    @Test func viewportZoomClampsAndResets() {
        var viewport = GraphViewport(zoom: 1, pan: CGSize(width: 24, height: -12), minZoom: 0.5, maxZoom: 2.0)
        viewport.zoomIn(factor: 3.0)
        #expect(viewport.zoom == 2.0)
        viewport.zoomOut(factor: 10.0)
        #expect(viewport.zoom == 0.5)
        viewport.reset()
        #expect(viewport.zoom == 1.0)
        #expect(viewport.pan == .zero)
    }
}
