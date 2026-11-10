import Foundation

struct DirectedExecutionSnapshot: Sendable {
    struct Node: Sendable {
        var id: String
        var bounds: Rect
    }

    struct Edge: Sendable {
        var source: Int
        var target: Int
        var sourcePort: PortConstraint
        var targetPort: PortConstraint
        var path: [Point]
    }

    var nodes: [Node]
    var edges: [Edge]

    init(_ graph: LayoutGraph) throws {
        let index = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element, $0.offset) })
        nodes = graph.nodes.map { Node(id: $0.id, bounds: $0.bounds) }
        edges = try graph.edges.map { edge in
            guard let source = index[edge.source], let target = index[edge.target] else {
                throw LayoutExecutionError.invalidInput("Directed edge endpoints must belong to the graph.")
            }
            return Edge(
                source: source,
                target: target,
                sourcePort: edge.sourcePort,
                targetPort: edge.targetPort,
                path: edge.path
            )
        }
    }

    func makeGraph() -> LayoutGraph {
        let graph = LayoutGraph()
        for state in nodes {
            let node = LayoutNode(id: state.id, width: state.bounds.width, height: state.bounds.height)
            node.bounds = state.bounds
            graph.addNode(node)
        }
        for state in edges {
            let edge = LayoutEdge(source: graph.nodes[state.source], target: graph.nodes[state.target])
            edge.sourcePort = state.sourcePort
            edge.targetPort = state.targetPort
            edge.path = state.path
            graph.addEdge(edge)
        }
        return graph
    }
}

struct DirectedExecutionResult: Sendable {
    var bounds: [Rect]
    var paths: [[Point]]
    var diagnostics: DirectedLayoutDiagnostics
    var metrics: LayoutExecutionMetrics
}
