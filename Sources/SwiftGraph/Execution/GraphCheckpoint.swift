import Foundation

/// Kept on the graph's owner. No graph reference crosses the executor boundary.
struct GraphCheckpoint {
    let nodes: [LayoutNode]
    let edges: [LayoutEdge]
    let parents: [LayoutNode?]
    let children: [[LayoutNode]]
    let groups: [Bool]
    let rootChildren: [LayoutNode]
    let frames: [GroupFrameOptions?]
    let contentBounds: [Rect?]
    let headerBounds: [Rect?]
    let snapshot: GeometrySnapshot

    init(_ graph: LayoutGraph) throws {
        nodes = graph.nodes
        edges = graph.edges
        guard Set(nodes).count == nodes.count, nodes.count < Int(UInt32.max) else {
            throw LayoutExecutionError.invalidInput("Node references must be unique and fit in 32-bit indices.")
        }
        guard
            nodes.allSatisfy({ n in
                [n.x, n.y, n.width, n.height, n.center.x, n.center.y].allSatisfy(\.isFinite) && n.width >= 0
                    && n.height >= 0
            })
        else {
            throw LayoutExecutionError.invalidInput("Finite geometry and nonnegative dimensions are required.")
        }
        parents = nodes.map(\.parent)
        children = nodes.map(\.children)
        groups = nodes.map(\.isGroup)
        frames = nodes.map(\.groupFrame)
        contentBounds = nodes.map(\.groupContentBounds)
        headerBounds = nodes.map(\.groupHeaderBounds)
        rootChildren = graph.root.children
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, $0.offset) })
        snapshot = GeometrySnapshot(
            nodes: nodes.map(Self.state),
            edges: edges.enumerated()
                .compactMap { i, e in
                    guard let s = index[e.source], let t = index[e.target] else { return nil }
                    return .init(source: s, target: t, index: i)
                }
        )
    }

    private static func state(_ n: LayoutNode) -> GeometrySnapshot.Node {
        .init(
            bounds: n.bounds,
            fixed: n.metadata[GraphMetadataKeys.fixed] as? Bool == true,
            selected: n.metadata[GraphMetadataKeys.layoutSubset] as? Bool == true,
            isGroup: n.isGroup
        )
    }

    func matches(_ graph: LayoutGraph) -> Bool {
        graph.nodes == nodes && graph.edges == edges && graph.root.children == rootChildren
            && nodes.map(Self.state) == snapshot.nodes && nodes.map(\.parent) == parents
            && nodes.map(\.children) == children && nodes.map(\.isGroup) == groups && nodes.map(\.groupFrame) == frames
            && nodes.map(\.groupContentBounds) == contentBounds && nodes.map(\.groupHeaderBounds) == headerBounds
    }
}
