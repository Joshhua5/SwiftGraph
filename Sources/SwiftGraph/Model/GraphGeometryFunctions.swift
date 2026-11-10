func enclosingBounds(_ nodes: [LayoutNode]) -> Rect {
    guard let first = nodes.first else { return Rect() }
    return nodes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
}

func straightEdges(_ graph: LayoutGraph) {
    for e in graph.edges where e.source !== e.target { e.path = [e.source.center, e.target.center] }
}

func translate(_ graph: LayoutGraph, by offset: Point) {
    for n in graph.nodes {
        n.center = n.center + offset
        n.groupContentBounds = n.groupContentBounds?.translated(by: offset)
        n.groupHeaderBounds = n.groupHeaderBounds?.translated(by: offset)
    }
    for e in graph.edges {
        e.path = e.path.map { $0 + offset }
        e.labelBounds = e.labelBounds.translated(by: offset)
    }
}

func subgraph(_ graph: LayoutGraph, nodes: [LayoutNode]) -> LayoutGraph {
    let result = LayoutGraph()
    let members = Set(nodes)
    for node in nodes { result.addNodeDetached(node) }
    result.edges = graph.edges.filter { members.contains($0.source) && members.contains($0.target) }
    return result
}
