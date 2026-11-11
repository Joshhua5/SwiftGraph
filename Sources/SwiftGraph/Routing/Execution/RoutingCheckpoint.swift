import Foundation

struct RoutingCheckpoint {
    let graph: GraphCheckpoint
    let snapshot: RoutingSnapshot
    let related: [LayoutNode]
    private let relatedStates: [NodeState]

    private struct NodeState: Equatable {
        var bounds: Rect
        var isGroup: Bool
        var parent: LayoutNode?
        var children: [LayoutNode]
        var frame: GroupFrameOptions?
        var content: Rect?
        var header: Rect?

        init(_ node: LayoutNode) {
            bounds = node.bounds
            isGroup = node.isGroup
            parent = node.parent
            children = node.children
            frame = node.groupFrame
            content = node.groupContentBounds
            header = node.groupHeaderBounds
        }
    }

    init(_ input: LayoutGraph, labels: [String?]) throws {
        graph = try GraphCheckpoint(input)
        guard graph.snapshot.edges.count == input.edges.count else {
            throw LayoutExecutionError.invalidInput("Every routed edge must belong to the graph.")
        }
        // Temporary component/group graphs deliberately retain original parent references.
        // Snapshot those relationships without widening graph.nodes or its obstacle membership.
        var nodes = [input.root]
        var seen: Set<LayoutNode> = [input.root]
        var pending = input.nodes + input.root.children
        if let parent = input.root.parent { pending.append(parent) }
        while let node = pending.popLast() {
            guard seen.insert(node).inserted else { continue }
            nodes.append(node)
            pending.append(contentsOf: node.children)
            if let parent = node.parent { pending.append(parent) }
        }
        guard nodes.count < Int(UInt32.max),
            nodes.allSatisfy({ node in
                [node.x, node.y, node.width, node.height, node.bounds.right, node.bounds.bottom].allSatisfy(\.isFinite)
                    && node.width >= 0 && node.height >= 0
            })
        else { throw LayoutExecutionError.invalidInput("Finite routing hierarchy is required.") }
        // Child cycles would form unreleasable strong cycles in the detached clone.
        var visited = Set<LayoutNode>()
        var active = Set<LayoutNode>()
        for seed in nodes where !visited.contains(seed) {
            var stack = [(seed, false)]
            while let (node, post) = stack.popLast() {
                if post {
                    active.remove(node)
                    visited.insert(node)
                    continue
                }
                guard !active.contains(node) else {
                    throw LayoutExecutionError.invalidInput("Routing child hierarchy must be acyclic.")
                }
                if visited.contains(node) { continue }
                active.insert(node)
                stack.append((node, true))
                for child in node.children.reversed() { stack.append((child, false)) }
            }
        }
        for node in nodes {
            var ancestors = Set<LayoutNode>()
            var current: LayoutNode? = node
            while let member = current {
                guard ancestors.insert(member).inserted else {
                    throw LayoutExecutionError.invalidInput("Routing parent hierarchy must be acyclic.")
                }
                current = member.parent
            }
        }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, $0.offset) })
        let edges = input.edges.enumerated().map { i, edge in Self.state(edge, label: labels[i]) }
        guard
            edges.allSatisfy({
                $0.path.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                    && [$0.labelBounds.x, $0.labelBounds.y, $0.labelBounds.width, $0.labelBounds.height]
                        .allSatisfy(\.isFinite)
            })
        else {
            throw LayoutExecutionError.invalidInput("Finite route and label geometry is required.")
        }
        related = nodes
        relatedStates = nodes.map(NodeState.init)
        snapshot = RoutingSnapshot(
            geometry: graph.snapshot,
            hierarchy: nodes.map {
                .init(
                    id: $0.id,
                    bounds: $0.bounds,
                    isGroup: $0.isGroup,
                    parent: $0.parent.flatMap { index[$0] },
                    children: $0.children.map { index[required: $0] },
                    frame: $0.groupFrame,
                    content: $0.groupContentBounds,
                    header: $0.groupHeaderBounds
                )
            },
            members: input.nodes.map { index[required: $0] },
            edges: edges,
            routeStyle: input.routeStyle
        )
    }

    private static func state(_ edge: LayoutEdge, label: String?) -> RoutingSnapshot.Edge {
        .init(
            path: edge.path,
            labelBounds: edge.labelBounds,
            label: label,
            sourcePort: edge.sourcePort,
            targetPort: edge.targetPort,
            sourceCandidates: edge.sourcePortCandidates,
            targetCandidates: edge.targetPortCandidates
        )
    }

    func matches(_ input: LayoutGraph, labels: [String?]) -> Bool {
        graph.matches(input) && related.map(NodeState.init) == relatedStates
            && input.edges.enumerated().map { Self.state($0.element, label: labels[$0.offset]) } == snapshot.edges
    }
}
