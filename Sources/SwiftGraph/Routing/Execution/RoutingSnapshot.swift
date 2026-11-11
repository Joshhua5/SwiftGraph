import Foundation

struct RoutingSnapshot: Sendable {
    var geometry: GeometrySnapshot

    struct Node: Sendable {
        var id: String
        var bounds: Rect
        var isGroup: Bool
        var parent: Int?
        var children: [Int]
        var frame: GroupFrameOptions? = nil
        var content: Rect? = nil
        var header: Rect? = nil
    }

    /// Related hierarchy nodes are distinct from obstacle/routing graph membership.
    /// Index zero is the local graph's root; external ancestor roots remain separate nodes.
    var hierarchy: [Node]
    var members: [Int]

    struct Edge: Sendable, Equatable {
        var path: [Point]
        var labelBounds: Rect
        var label: String?
        var sourcePort: PortConstraint
        var targetPort: PortConstraint
        var sourceCandidates: [PortConstraint]
        var targetCandidates: [PortConstraint]
    }

    var edges: [Edge]
    /// The input graph's recorded route style, so finishing stages on the detached copy read what the caller's would.
    var routeStyle: RouteStyle? = nil

    func makeGraph() -> (LayoutGraph, [LayoutNode]) {
        let graph = LayoutGraph()
        graph.routeStyle = routeStyle
        let nodes = hierarchy.enumerated()
            .map { i, state in
                let node =
                    i == 0
                    ? graph.root : LayoutNode(id: state.id, width: state.bounds.width, height: state.bounds.height)
                node.bounds = state.bounds
                node.isGroup = state.isGroup
                node.groupFrame = state.frame
                node.groupContentBounds = state.content
                node.groupHeaderBounds = state.header
                return node
            }
        for i in nodes.indices {
            nodes[i].parent = hierarchy[i].parent.map { nodes[$0] }
            nodes[i].children = hierarchy[i].children.map { nodes[$0] }
        }
        graph.nodes = members.map { nodes[$0] }
        for (i, pair) in geometry.edges.enumerated() {
            let edge = LayoutEdge(
                source: graph.nodes[pair.source],
                target: graph.nodes[pair.target],
                data: edges[i].label
            )
            let state = edges[i]
            edge.path = state.path
            edge.labelBounds = state.labelBounds
            edge.sourcePort = state.sourcePort
            edge.targetPort = state.targetPort
            edge.sourcePortCandidates = state.sourceCandidates
            edge.targetPortCandidates = state.targetCandidates
            graph.addEdge(edge)
        }
        return (graph, nodes)
    }
}
