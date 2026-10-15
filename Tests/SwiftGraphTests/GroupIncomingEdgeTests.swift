import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct GroupIncomingEdgeTests {
    func length(_ edges: [LayoutEdge]) -> Float {
        edges.reduce(0) { sum, edge in
            sum + zip(edge.path, edge.path.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
        }
    }

    /// A source above an off-centre target in a wide frame. The optional neighbour
    /// prevents translating the frame, leaving room only for its target to align.
    func fixture(blockFrame: Bool = false, outgoing: Bool = false) throws -> LayoutGraph {
        let graph = LayoutGraph()
        let frame = try graph.addGroup(id: "frame", frame: .init(minimumSize: Size(width: 400, height: 70)))
        frame.y = 300
        let target = LayoutNode(id: "target", width: 60, height: 30)
        try graph.addNode(target, to: frame)
        let source = LayoutNode(id: "source", width: 60, height: 30); source.x = 200
        graph.addNode(source); graph.addEdge(LayoutEdge(source: source, target: target))
        if blockFrame {
            let neighbour = LayoutNode(id: "neighbour", width: 60, height: 70)
            neighbour.x = 500; neighbour.y = 300; graph.addNode(neighbour)
        }
        if outgoing {
            let sink = LayoutNode(id: "sink", width: 60, height: 30)
            sink.x = 20; sink.y = 400; graph.addNode(sink)
            graph.addEdge(LayoutEdge(source: target, target: sink))
        }
        return graph
    }

    func layout(_ graph: LayoutGraph, optimize: Bool) throws {
        let layout = RecursiveGroupLayout(GivenCoordinatesLayoutAlgorithm())
        layout.optimizeIncomingEdges = optimize
        try layout.applyLayout(graph)
        #expect(layout.unroutableEdges.isEmpty)
    }

    @Test func alignsRealTargetByMovingItsFrame() throws {
        let baseline = try fixture(), refined = try fixture()
        try layout(baseline, optimize: false); try layout(refined, optimize: true)
        let frame = refined.nodes[0], target = refined.nodes[1], source = refined.nodes[2]
        #expect(length(refined.edges) < length(baseline.edges) - 40)
        #expect(target.center.x == source.center.x)
        #expect(frame.x == 180 && frame.y == baseline.nodes[0].y)
        #expect(frame.bounds.size == baseline.nodes[0].bounds.size)
        #expect(target.center - frame.center == baseline.nodes[1].center - baseline.nodes[0].center)
        let bounds = refined.nodes.map(\.bounds), path = refined.edges[0].path
        try layout(refined, optimize: true)
        #expect(refined.nodes.map(\.bounds) == bounds && refined.edges[0].path == path)
    }

    @Test func usesSpareContentSpaceWhenSiblingSpacingLocksFrame() throws {
        let baseline = try fixture(blockFrame: true), refined = try fixture(blockFrame: true)
        try layout(baseline, optimize: false); try layout(refined, optimize: true)
        #expect(refined.nodes[0].bounds == baseline.nodes[0].bounds)
        #expect(refined.nodes[1].center.x == refined.nodes[2].center.x)
        #expect(length(refined.edges) < length(baseline.edges) - 40)
        #expect(refined.nodes[0].groupContentBounds!.contains(refined.nodes[1].center))
        #expect(refined.nodes[3].bounds == baseline.nodes[3].bounds)
    }

    @Test func rejectsIncomingSavingsThatIncreaseTotalLength() throws {
        let baseline = try fixture(outgoing: true), refined = try fixture(outgoing: true)
        try layout(baseline, optimize: false); try layout(refined, optimize: true)
        #expect(refined.nodes.map(\.bounds) == baseline.nodes.map(\.bounds))
        #expect(refined.edges.map(\.path) == baseline.edges.map(\.path))
    }

    @Test(arguments: ["frame", "target"])
    func fixedFrameOrDescendantPreventsRefinement(_ id: String) throws {
        let baseline = try fixture(), refined = try fixture()
        for graph in [baseline, refined] {
            graph.nodes.first { $0.id == id }!.metadata[GraphMetadataKeys.fixed] = true
        }
        try layout(baseline, optimize: false); try layout(refined, optimize: true)
        #expect(refined.nodes.map(\.bounds) == baseline.nodes.map(\.bounds))
        #expect(refined.edges.map(\.path) == baseline.edges.map(\.path))
    }

    @Test func multipleInputsAndMeasuredLabelsArePreserved() throws {
        let graph = try fixture(blockFrame: true)
        let source = LayoutNode(id: "second-source", width: 60, height: 30); source.x = 280
        graph.addNode(source); graph.addEdge(LayoutEdge(source: source, target: graph.nodes[1]))
        for edge in graph.edges { edge.labelBounds = Rect(width: 30, height: 12) }
        try layout(graph, optimize: false)
        let before = length(graph.edges), labels = graph.edges.map(\.labelBounds)
        try GroupLayoutEngine(graph, padding: 20).refineIncomingEdges(excluding: [])
        #expect(length(graph.edges) < before)
        #expect(graph.edges.map(\.labelBounds) != labels)
        #expect(graph.edges.allSatisfy { $0.labelBounds.size == Size(width: 30, height: 12) })
        #expect(graph.edges.allSatisfy { $0.path.first == $0.source.center && $0.path.last == $0.target.center })
    }

    @Test func movingFrameCannotObstructAnUnrelatedRoute() throws {
        let graph = try fixture()
        graph.nodes[0].groupFrame?.minimumSize.width = 100
        let a = LayoutNode(id: "a", width: 20, height: 20), b = LayoutNode(id: "b", width: 20, height: 20)
        a.x = 130; a.y = 200; b.x = 230; b.y = 450
        graph.addNode(a); graph.addNode(b); graph.addEdge(LayoutEdge(source: a, target: b))
        try layout(graph, optimize: false)
        let before = graph.nodes.map(\.bounds), paths = graph.edges.map(\.path)
        try GroupLayoutEngine(graph, padding: 20).refineIncomingEdges(excluding: [])
        #expect(graph.nodes.map(\.bounds) == before && graph.edges.map(\.path) == paths)
    }

    @Test func nestedRefinementKeepsInternalRoutesAndLabelsInsideFrames() throws {
        let graph = try fixture(blockFrame: true)
        let frame = graph.nodes[0], target = graph.nodes[1]
        let inner = try graph.addGroup(id: "inner", parent: frame)
        try graph.moveNode(target, to: inner)
        let peer = LayoutNode(id: "peer", width: 60, height: 30); peer.y = 100
        try graph.addNode(peer, to: inner)
        let internalEdge = LayoutEdge(source: target, target: peer)
        internalEdge.labelBounds = Rect(width: 20, height: 10); graph.addEdge(internalEdge)
        try layout(graph, optimize: false)
        let before = length([graph.edges[0]]), shape = internalEdge.path.map { $0 - target.center }
        try GroupLayoutEngine(graph, padding: 20).refineIncomingEdges(excluding: [])
        #expect(length([graph.edges[0]]) < before)
        #expect(internalEdge.path.map { $0 - target.center } == shape)
        let content = inner.groupContentBounds!
        #expect(internalEdge.path.allSatisfy(content.contains))
        #expect(content.contains(Point(x: internalEdge.labelBounds.left, y: internalEdge.labelBounds.top)))
        #expect(content.contains(Point(x: internalEdge.labelBounds.right, y: internalEdge.labelBounds.bottom)))
        #expect(frame.groupContentBounds!.contains(inner.center))
    }

    @Test(arguments: [false, true])
    func asyncMatchesSyncWithOptionEnabledOrDisabled(_ enabled: Bool) async throws {
        let sync = try fixture(blockFrame: true), async = try fixture(blockFrame: true)
        try layout(sync, optimize: enabled)
        let operation = RecursiveGroupLayoutOperation(GivenCoordinatesLayoutAlgorithm())
        operation.optimizeIncomingEdges = enabled
        try await operation.applyLayoutAsync(async)
        #expect(async.nodes.map(\.bounds) == sync.nodes.map(\.bounds))
        #expect(async.edges.map(\.path) == sync.edges.map(\.path))
    }
}
