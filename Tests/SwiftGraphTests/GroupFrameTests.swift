import Testing
@testable import SwiftGraph

@Suite(.serialized)
@MainActor
struct GroupFrameTests {
    func contains(_ outer: Rect, _ inner: Rect) -> Bool {
        inner.left >= outer.left - 1e-4 && inner.right <= outer.right + 1e-4 &&
        inner.top >= outer.top - 1e-4 && inner.bottom <= outer.bottom + 1e-4
    }
    @discardableResult func leaf(_ graph: LayoutGraph, _ id: String, _ parent: LayoutNode? = nil) throws -> LayoutNode {
        let node = LayoutNode(id: id, width: 60, height: 30)
        try graph.addNode(node, to: parent); return node
    }

    @Test func constructionAndReparentingAreAtomic() throws {
        let graph = LayoutGraph(), outer = try graph.addGroup(id: "outer")
        let inner = try graph.addGroup(id: "inner", parent: outer)
        let node = try leaf(graph, "leaf", inner)
        try graph.moveNode(node, to: outer)
        #expect(node.parent === outer && inner.children.isEmpty)
        #expect(graph.nodes.count == 3 && outer.children == [inner, node])
        #expect(throws: GraphError.cyclicGroupHierarchy) { try graph.moveNode(outer, to: inner) }
        #expect(outer.parent === graph.root && inner.parent === outer)
        let foreign = LayoutGraph(), foreignGroup = try foreign.addGroup(id: "foreign")
        #expect(throws: LayoutExecutionError.self) { try graph.moveNode(node, to: foreignGroup) }
        #expect(throws: LayoutExecutionError.self) { try graph.addNode(foreignGroup, to: nil) }
        #expect(node.parent === outer && foreignGroup.parent === foreign.root)
        try graph.moveNode(node, to: nil)
        #expect(node.parent === graph.root && !outer.children.contains(node))
    }

    @Test func framesFitHeadersInsetsAndEmptyMinimums() throws {
        let graph = LayoutGraph()
        let frame = GroupFrameOptions(padding: LayoutInsets(top: 7, left: 11, bottom: 13, right: 17),
                                      headerSize: Size(width: 300, height: 28), minimumSize: Size(width: 350, height: 120))
        let group = try graph.addGroup(id: "title", frame: frame)
        let node = try leaf(graph, "node", group)
        let empty = try graph.addGroup(id: "empty", frame: frame)
        let layout = RecursiveGroupLayout(TreeLayoutAlgorithm()); try layout.applyLayout(graph)
        #expect(group.width == 350 && group.height == 120)
        #expect(empty.width == 350 && empty.height == 120)
        #expect(node.x == group.x + 11 && node.y == group.y + 7 + 28)
        #expect(group.groupHeaderBounds == Rect(x: group.x + 11, y: group.y + 7, width: 322, height: 28))
        #expect(contains(group.groupContentBounds!, node.bounds))
        #expect(!group.bounds.intersects(empty.bounds))
        let before = graph.nodes.map(\.bounds), headers = graph.nodes.map(\.groupHeaderBounds)
        try layout.applyLayout(graph)
        #expect(graph.nodes.map(\.bounds) == before && graph.nodes.map(\.groupHeaderBounds) == headers)
    }

    @Test(arguments: ["hierarchical", "tree", "circular", "organic", "radial", "balloon"])
    func mixedNestedLayoutsContainWholeRectangles(_ kind: String) throws {
        let graph = LayoutGraph(), outer = try graph.addGroup(id: "outer", frame: .init(headerSize: Size(width: 220, height: 24)))
        let inner = try graph.addGroup(id: "inner", parent: outer)
        let deep = try graph.addGroup(id: "deep", parent: inner)
        for i in 0..<3 { try leaf(graph, "deep-\(i)", deep) }
        try leaf(graph, "inner-peer", inner); try leaf(graph, "outer-peer", outer)
        let peer = try graph.addGroup(id: "peer")
        for i in 0..<3 { try leaf(graph, "peer-\(i)", peer) }
        let edge = LayoutEdge(source: deep.children[0], target: peer.children[1]); graph.addEdge(edge)
        let core: any LayoutAlgorithm
        switch kind {
        case "hierarchical": core = HierarchicalLayoutAlgorithm()
        case "tree": core = TreeLayoutAlgorithm()
        case "circular": core = CircularLayoutAlgorithm()
        case "organic": let organic = OrganicLayoutAlgorithm(); organic.iterations = 8; core = organic
        case "radial": core = RadialLayoutAlgorithm()
        default: core = BalloonLayoutAlgorithm()
        }
        let layout = RecursiveGroupLayout(core)
        layout.groupLayoutSelector = { group in group === deep ? VerticalStackLayoutAlgorithm() : core }
        try layout.applyLayout(graph)
        for group in graph.nodes where group.isGroup {
            for child in group.children { #expect(contains(group.groupContentBounds!, child.bounds)) }
        }
        #expect(!outer.bounds.intersects(peer.bounds))
        #expect(edge.path.count >= 2 && layout.unroutableEdges.isEmpty)
        #expect(edge.path.first == edge.source.center && edge.path.last == edge.target.center)
    }

    final class RecordingLayout: LayoutAlgorithm {
        var pairs: [(String, String)] = []
        var sawGroup = false
        func applyLayout(_ graph: LayoutGraph) throws {
            pairs = graph.edges.map { ($0.source.id, $0.target.id) }
            sawGroup = graph.nodes.contains(where: \.isGroup)
            try HierarchicalLayoutAlgorithm().applyLayout(graph)
        }
    }
    @Test func descendantConnectionsDriveParentPlacement() throws {
        let graph = LayoutGraph(), b = try graph.addGroup(id: "B"), a = try graph.addGroup(id: "A")
        let first = try leaf(graph, "first", a), second = try leaf(graph, "second", b)
        let edge = LayoutEdge(source: first, target: second)
        graph.edges = [edge, LayoutEdge(source: first, target: second)]
        let recorder = RecordingLayout(), layout = RecursiveGroupLayout(TreeLayoutAlgorithm())
        layout.groupLayoutSelector = { if $0 === graph.root { return recorder }; return TreeLayoutAlgorithm() }
        let identities = graph.nodes, edges = graph.edges, parents = graph.nodes.map(\.parent)
        try layout.applyLayout(graph)
        #expect(recorder.pairs.count == 2 && recorder.pairs.allSatisfy { $0 == "A" && $1 == "B" })
        #expect(!recorder.sawGroup && a.bounds.bottom <= b.bounds.top)
        #expect(graph.nodes == identities && graph.edges == edges && graph.nodes.map(\.parent) == parents)
        #expect(edge.source === first && edge.target === second)
    }

    final class BentLayout: LayoutAlgorithm {
        func applyLayout(_ graph: LayoutGraph) throws {
            for (i, node) in graph.nodes.enumerated() { node.x = Float(i * 180); node.y = 50 }
            for edge in graph.edges {
                edge.path = [edge.source.center, Point(x: edge.source.center.x, y: -80),
                             Point(x: edge.target.center.x, y: -80), edge.target.center]
                edge.labelBounds = Rect(x: 90, y: -100, width: 60, height: 15)
            }
        }
    }
    @Test func ownedBendsLabelsAndLoopsFitAndTranslateOnce() throws {
        let graph = LayoutGraph(), outer = try graph.addGroup(id: "outer"), inner = try graph.addGroup(id: "inner", parent: outer)
        let a = try leaf(graph, "a", inner), b = try leaf(graph, "b", inner)
        graph.edges = [LayoutEdge(source: a, target: b)]
        let layout = RecursiveGroupLayout(TreeLayoutAlgorithm())
        layout.groupLayoutSelector = { if $0 === inner { return BentLayout() }; return TreeLayoutAlgorithm() }
        try layout.applyLayout(graph)
        let edge = graph.edges[0], shape = edge.path.map { $0 - a.center }
        #expect(shape == [.zero, Point(x: 0, y: -145), Point(x: 180, y: -145), Point(x: 180, y: 0)])
        for point in edge.path { #expect(inner.groupContentBounds!.contains(point)) }
        #expect(contains(inner.groupContentBounds!, edge.labelBounds))
        #expect(contains(outer.groupContentBounds!, inner.bounds))
        let before = graph.nodes.map(\.bounds), path = edge.path, label = edge.labelBounds
        try layout.applyLayout(graph)
        #expect(graph.nodes.map(\.bounds) == before && edge.path == path && edge.labelBounds == label)
        let loop = LayoutEdge(source: a, target: a)
        loop.path = [a.center, Point(x: a.bounds.right + 40, y: a.center.y), Point(x: a.bounds.right + 40, y: a.y - 40), a.center]
        graph.addEdge(loop)
        try RecursiveGroupLayout(GivenCoordinatesLayoutAlgorithm()).applyLayout(graph)
        for point in loop.path { #expect(inner.groupContentBounds!.contains(point)) }
    }

    @Test func crossGroupRoutingAvoidsForeignFramesAndHeaders() throws {
        let graph = LayoutGraph(), left = try graph.addGroup(id: "left"), right = try graph.addGroup(id: "right")
        let wall = try graph.addGroup(id: "wall", frame: .init(headerSize: Size(width: 100, height: 25), minimumSize: Size(width: 140, height: 220)))
        let a = try leaf(graph, "a", left), b = try leaf(graph, "b", right)
        left.x = -250; right.x = 250; wall.x = -20; wall.y = -50
        let edge = LayoutEdge(source: a, target: b); graph.addEdge(edge)
        let layout = RecursiveGroupLayout(GivenCoordinatesLayoutAlgorithm()); try layout.applyLayout(graph)
        #expect(layout.unroutableEdges.isEmpty && edge.path.count > 2)
        for (p, q) in zip(edge.path, edge.path.dropFirst()) {
            #expect(!wall.bounds.inflated(by: -1e-4).intersectsLine(p, q))
        }
        // Route out of a titled group upwards: the title itself remains an obstacle.
        let titled = try graph.addGroup(id: "titled", frame: .init(headerSize: Size(width: 120, height: 40)))
        titled.x = 600
        let start = try leaf(graph, "start", titled), target = try leaf(graph, "outside")
        target.x = 640; target.y = -200
        let upward = LayoutEdge(source: start, target: target); graph.addEdge(upward)
        try layout.applyLayout(graph)
        for (p, q) in zip(upward.path, upward.path.dropFirst()) {
            #expect(!titled.groupHeaderBounds!.inflated(by: -1e-4).intersectsLine(p, q))
        }
    }

    final class ShrinkingLayout: LayoutAlgorithm {
        func applyLayout(_ graph: LayoutGraph) throws { for node in graph.nodes { node.width = 1; node.height = 1 } }
    }
    @Test func invalidSettingsHierarchyAndShrinkingFramesDoNotCommit() throws {
        let graph = LayoutGraph(), group = try graph.addGroup(id: "group"), node = try leaf(graph, "leaf", group)
        let before = graph.nodes.map(\.bounds)
        let layout = RecursiveGroupLayout(TreeLayoutAlgorithm())
        layout.groupLayoutSelector = { if $0 === graph.root { return ShrinkingLayout() }; return TreeLayoutAlgorithm() }
        #expect(throws: LayoutExecutionError.self) { try layout.applyLayout(graph) }
        #expect(graph.nodes.map(\.bounds) == before && group.groupContentBounds == nil)
        group.groupFrame?.padding.left = -.infinity
        #expect(throws: LayoutExecutionError.self) { try layout.applyLayout(graph) }
        group.groupFrame = GroupFrameOptions(); node.parent = graph.root
        #expect(throws: LayoutExecutionError.self) { try layout.applyLayout(graph) }
        #expect(graph.nodes.map(\.bounds) == before)
    }

    final class SuspendedLayout: AsyncLayoutAlgorithm {
        var continuation: CheckedContinuation<Void, Never>?
        func applyLayoutAsync(_ graph: LayoutGraph) async throws {
            try TreeLayoutAlgorithm().applyLayout(graph)
            await withCheckedContinuation { continuation = $0 }
            try Task.checkCancellation()
        }
    }
    @Test(arguments: ["frame", "cancel"])
    func suspendedFrameChangesDiscardResults(_ edit: String) async throws {
        let graph = LayoutGraph(), group = try graph.addGroup(id: "group")
        try leaf(graph, "child", group)
        let core = SuspendedLayout(), operation = RecursiveGroupLayoutOperation(TreeLayoutAlgorithm())
        operation.groupLayoutSelector = { if $0 === group { return core }; return TreeLayoutAlgorithm() }
        let before = graph.nodes.map(\.bounds), task = Task { try await operation.applyLayoutAsync(graph) }
        while core.continuation == nil { await Task.yield() }
        #expect(graph.nodes.map(\.bounds) == before && group.groupContentBounds == nil)
        if edit == "cancel" { task.cancel() } else { group.groupFrame?.headerSize.height = 80 }
        core.continuation?.resume(); core.continuation = nil
        if edit == "cancel" { await #expect(throws: CancellationError.self) { try await task.value } }
        else { await #expect(throws: LayoutExecutionError.staleGraph) { try await task.value } }
        #expect(graph.nodes.map(\.bounds) == before && group.groupContentBounds == nil)
    }

    @Test func asyncMatchesSyncIncludingIdentitySelectorsAndFrameGeometry() async throws {
        func make() throws -> LayoutGraph {
            let graph = LayoutGraph(), group = try graph.addGroup(id: "group", frame: .init(headerSize: Size(width: 240, height: 25)))
            let inner = try graph.addGroup(id: "inner", parent: group)
            let a = try leaf(graph, "a", inner), b = try leaf(graph, "b", inner), c = try leaf(graph, "outside")
            graph.edges = [LayoutEdge(source: a, target: b), LayoutEdge(source: b, target: c)]
            return graph
        }
        let a = try make(), b = try make()
        let sync = RecursiveGroupLayout(TreeLayoutAlgorithm()), async = RecursiveGroupLayoutOperation(TreeLayoutAlgorithm())
        sync.groupLayoutSelector = { if $0 === a.nodes[1] { return CircularLayoutAlgorithm() }; return TreeLayoutAlgorithm() }
        async.groupLayoutSelector = { if $0 === b.nodes[1] { return CircularLayoutAlgorithm() }; return TreeLayoutAlgorithm() }
        try sync.applyLayout(a); try await async.applyLayoutAsync(b)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(a.nodes.map(\.groupContentBounds) == b.nodes.map(\.groupContentBounds))
        #expect(a.nodes.map(\.groupHeaderBounds) == b.nodes.map(\.groupHeaderBounds))
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
    }

    final class FailingLayout: AsyncLayoutAlgorithm {
        var calls = 0
        func applyLayoutAsync(_ graph: LayoutGraph) async throws {
            calls += 1
            try TreeLayoutAlgorithm().applyLayout(graph)
            if calls == 2 { throw LayoutExecutionError.invalidInput("Second group failed") }
        }
    }
    @Test func laterGroupFailureDoesNotCommitEarlierFrames() async throws {
        let graph = LayoutGraph(), a = try graph.addGroup(id: "a"), b = try graph.addGroup(id: "b")
        try leaf(graph, "a-leaf", a); try leaf(graph, "b-leaf", b)
        let before = graph.nodes.map(\.bounds), operation = RecursiveGroupLayoutOperation(FailingLayout())
        await #expect(throws: LayoutExecutionError.self) { try await operation.applyLayoutAsync(graph) }
        #expect(graph.nodes.map(\.bounds) == before && a.groupContentBounds == nil && b.groupHeaderBounds == nil)
    }

    @Test func impossibleRoutesExposeOriginalEdgesAndVisibleFallbacks() throws {
        let graph = LayoutGraph(), a = try leaf(graph, "source"), b = try leaf(graph, "target")
        b.x = 400
        for (i, rect) in [Rect(x: -20, y: -20, width: 100, height: 10), Rect(x: -20, y: 50, width: 100, height: 10),
                          Rect(x: -20, y: -20, width: 10, height: 80), Rect(x: 70, y: -20, width: 10, height: 80)].enumerated() {
            let wall = LayoutNode(id: "wall-\(i)", width: rect.width, height: rect.height); wall.bounds = rect; graph.addNode(wall)
        }
        let group = try graph.addGroup(id: "unrelated"); group.x = 1000
        let edge = LayoutEdge(source: a, target: b); graph.addEdge(edge)
        let layout = RecursiveGroupLayout(GivenCoordinatesLayoutAlgorithm()); try layout.applyLayout(graph)
        #expect(layout.unroutableEdges == [edge])
        #expect(edge.path == [a.center, b.center])
    }

    @Test func builderOverloadsConfigureBothCompositionKinds() async throws {
        let graph = LayoutGraph(), group = try graph.addGroup(id: "frame")
        try leaf(graph, "leaf", group)
        var calls = 0
        let sync = TreeLayoutAlgorithm()
        let async: any AsyncLayoutAlgorithm = TreeLayoutAlgorithm()
        try await LayoutBuilder.create(graph)
            .wrapWithRecursiveGroups(sync) { $0.groupPadding = 12; calls += 1 }
            .wrapWithFullComposition(sync) { $0.groupPadding = 12; calls += 1 }
            .wrapWithRecursiveGroups(async) { $0.groupPadding = 12; calls += 1 }
            .wrapWithFullComposition(async) { $0.groupPadding = 12; calls += 1 }
            .wrapWithRecursiveGroups(async, backend: .cpu) { $0.groupPadding = 12; calls += 1 }
            .wrapWithFullComposition(async, backend: .cpu) { $0.groupPadding = 12; calls += 1 }
            .applyAsync()
        #expect(calls == 6 && contains(group.groupContentBounds!, group.children[0].bounds))
    }

    @Test(.enabled(if: LayoutExecutor.isMetalAvailable, "Metal device unavailable"))
    func framedMetalMatchesCPUAndReportsRealWork() async throws {
        func make() throws -> LayoutGraph {
            let graph = LayoutGraph(), a = try graph.addGroup(id: "A", frame: .init(headerSize: Size(width: 180, height: 30)))
            let b = try graph.addGroup(id: "B", frame: .init(headerSize: Size(width: 180, height: 30)))
            let inner = try graph.addGroup(id: "inner", parent: a)
            let first = try leaf(graph, "first", inner), second = try leaf(graph, "second", inner), third = try leaf(graph, "third", b)
            graph.edges = [LayoutEdge(source: first, target: second), LayoutEdge(source: second, target: third)]
            return graph
        }
        let a = try make(), b = try make(), executor = LayoutExecutor()
        let cpu = RecursiveGroupLayoutOperation(HierarchicalLayoutOperation(backend: .cpu), backend: .cpu)
        let metal = RecursiveGroupLayoutOperation(HierarchicalLayoutOperation(backend: .metal, executor: executor), backend: .metal, executor: executor)
        try await cpu.applyLayoutAsync(a); try await metal.applyLayoutAsync(b)
        #expect(a.nodes.map(\.bounds) == b.nodes.map(\.bounds))
        #expect(a.nodes.map(\.groupHeaderBounds) == b.nodes.map(\.groupHeaderBounds))
        #expect(a.nodes.map(\.groupContentBounds) == b.nodes.map(\.groupContentBounds))
        #expect(a.edges.map(\.path) == b.edges.map(\.path))
        #expect(metal.lastExecutionMetrics.contains { $0.backend == .metal && !$0.metalStages.isEmpty })
        let stats = await executor.statistics()
        #expect(stats.submittedBatches > 0 && stats.submittedBatches == stats.completedBatches)
    }
}
