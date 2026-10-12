/// Detached geometry for composite operations that suspend between child layouts.
/// Caller payloads and custom metadata are inputs only; only geometry, ports and the
/// four standard layout metadata keys are committed. Custom cores must not mutate
/// reference-valued payloads or metadata, or change graph topology.
struct LayoutTransaction {
    let working: LayoutGraph
    private let checkpoint: GraphCheckpoint
    private let originals: [LayoutNode]
    private let copies: [LayoutNode]
    private let nodeStates: [NodeState]
    private let edgeStates: [EdgeState]
    private let workingNodes: [LayoutNode]
    private let workingEdges: [LayoutEdge]
    private let workingTopology: [Topology]

    private struct Topology: Equatable {
        let parent: LayoutNode?
        let children: [LayoutNode]
        let isGroup: Bool
        init(_ node: LayoutNode) { parent = node.parent; children = node.children; isGroup = node.isGroup }
    }
    private struct NodeState: Equatable {
        let bounds: Rect
        let topology: Topology
        let name: String
        let tags: Set<String>
        let fixed: Bool?
        let selected: Bool?
        let rank: Double?
        let cluster: Int?
        init(_ node: LayoutNode) {
            bounds = node.bounds; topology = Topology(node); name = node.name; tags = node.tags
            fixed = node.metadata[GraphMetadataKeys.fixed] as? Bool
            selected = node.metadata[GraphMetadataKeys.layoutSubset] as? Bool
            rank = node.metadata[GraphMetadataKeys.pageRank] as? Double
            cluster = node.metadata[GraphMetadataKeys.cluster] as? Int
        }
    }
    private struct EdgeState: Equatable {
        let path: [Point]
        let label: Rect
        let sourcePort: PortConstraint
        let targetPort: PortConstraint
        let sourceCandidates: [PortConstraint]
        let targetCandidates: [PortConstraint]
        init(_ edge: LayoutEdge) {
            path = edge.path; label = edge.labelBounds
            sourcePort = edge.sourcePort; targetPort = edge.targetPort
            sourceCandidates = edge.sourcePortCandidates; targetCandidates = edge.targetPortCandidates
        }
        func apply(to edge: LayoutEdge) {
            edge.path = path; edge.labelBounds = label
            edge.sourcePort = sourcePort; edge.targetPort = targetPort
            edge.sourcePortCandidates = sourceCandidates; edge.targetPortCandidates = targetCandidates
        }
    }

    init(_ graph: LayoutGraph) throws {
        checkpoint = try GraphCheckpoint(graph)
        let detached = LayoutGraph()
        working = detached
        var nodes: [LayoutNode] = [], seen = Set<LayoutNode>()
        var pending = [graph.root] + graph.nodes + graph.edges.flatMap { [$0.source, $0.target] }
        while let node = pending.popLast() {
            guard seen.insert(node).inserted else { continue }
            nodes.append(node); pending.append(contentsOf: node.children)
            if let parent = node.parent { pending.append(parent) }
        }
        // Reject child cycles before allocating copies, which would otherwise form
        // an unreleasable strong-reference cycle on a failed recursive layout.
        var visited = Set<LayoutNode>(), active = Set<LayoutNode>()
        for seed in nodes where !visited.contains(seed) {
            var stack = [(seed, false)]
            while let (node, post) = stack.popLast() {
                if post { active.remove(node); visited.insert(node); continue }
                if active.contains(node) { throw GraphError.cyclicGroupHierarchy }
                if visited.contains(node) { continue }
                active.insert(node); stack.append((node, true))
                for child in node.children.reversed() { stack.append((child, false)) }
            }
        }
        originals = nodes
        copies = nodes.map { node in
            let copy = node === graph.root ? detached.root : LayoutNode(id: node.id, width: node.width, height: node.height)
            copy.bounds = node.bounds; copy.name = node.name; copy.data = node.data
            copy.tags = node.tags; copy.metadata = node.metadata; copy.isGroup = node.isGroup
            return copy
        }
        let mapping = Dictionary(uniqueKeysWithValues: zip(originals, copies))
        for (node, copy) in zip(originals, copies) {
            copy.parent = node.parent.flatMap { mapping[$0] }
            copy.children = node.children.compactMap { mapping[$0] }
        }
        working.nodes = graph.nodes.map { mapping[$0]! }
        working.edges = graph.edges.map { edge in
            let copy = LayoutEdge(source: mapping[edge.source]!, target: mapping[edge.target]!, data: edge.data)
            EdgeState(edge).apply(to: copy)
            return copy
        }
        nodeStates = originals.map(NodeState.init); edgeStates = graph.edges.map(EdgeState.init)
        workingNodes = working.nodes; workingEdges = working.edges; workingTopology = copies.map(Topology.init)
    }

    func commit(to graph: LayoutGraph) throws {
        try Task.checkCancellation()
        guard checkpoint.matches(graph), originals.map(NodeState.init) == nodeStates,
              graph.edges.map(EdgeState.init) == edgeStates else { throw LayoutExecutionError.staleGraph }
        guard working.nodes == workingNodes, working.edges == workingEdges,
              copies.map(Topology.init) == workingTopology else {
            throw LayoutExecutionError.invalidInput("Composite layout cores must preserve graph topology.")
        }
        _ = try GraphCheckpoint(working)
        guard copies.allSatisfy({ [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width >= 0 && $0.height >= 0 }),
              working.edges.allSatisfy({ edge in
                  edge.path.allSatisfy { $0.x.isFinite && $0.y.isFinite } &&
                  [edge.labelBounds.x, edge.labelBounds.y, edge.labelBounds.width, edge.labelBounds.height].allSatisfy(\.isFinite)
              }) else { throw LayoutExecutionError.invalidInput("Composite layout produced non-finite geometry.") }
        for (original, copy) in zip(originals, copies) {
            original.bounds = copy.bounds
            for key in [GraphMetadataKeys.fixed, GraphMetadataKeys.layoutSubset, GraphMetadataKeys.pageRank, GraphMetadataKeys.cluster] {
                original.metadata[key] = copy.metadata[key]
            }
        }
        for (original, copy) in zip(graph.edges, working.edges) { EdgeState(copy).apply(to: original) }
    }
}
