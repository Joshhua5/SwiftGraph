import Foundation
import SwiftGraph

/// Compact topology: array positions are node IDs, and parents/endpoints are zero-based indices.
struct GraphTopology: Decodable, Sendable {
    struct Node: Decodable, Sendable { var parent: Int? }
    struct Edge: Decodable, Sendable {
        var source: Int
        var target: Int
        var bidirectional: Bool
    }
    var nodes: [Node]
    var edges: [Edge]

    static func bundledURL() throws -> URL {
        guard let input = Bundle.module.url(forResource: "graph-topology", withExtension: "json", subdirectory: "Fixtures") else {
            throw EvaluationError.message("Missing bundled graph-topology.json")
        }
        return input
    }

    static func load(from url: URL? = nil) throws -> GraphTopology {
        let input = try url ?? bundledURL()
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: input))
    }

    func makeGraph() throws -> LayoutGraph {
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent, !nodes.indices.contains(parent) {
                throw EvaluationError.message("Node \(index) has invalid parent index \(parent)")
            }
        }
        for index in nodes.indices {
            var cursor: Int? = index, seen = Set<Int>()
            while let current = cursor {
                guard seen.insert(current).inserted else {
                    throw EvaluationError.message("Cyclic parent hierarchy at node \(index)")
                }
                cursor = nodes[current].parent
            }
        }
        for (index, edge) in edges.enumerated() {
            guard nodes.indices.contains(edge.source), nodes.indices.contains(edge.target) else {
                throw EvaluationError.message("Edge \(index) has invalid endpoint indices \(edge.source), \(edge.target)")
            }
        }

        let graph = LayoutGraph(), groups = Set(nodes.compactMap(\.parent))
        for index in nodes.indices {
            let node = LayoutNode(id: "\(index)", width: 80, height: 32)
            node.isGroup = groups.contains(index)
            if node.isGroup { node.groupFrame = GroupFrameOptions(headerSize: Size(width: 80, height: 20)) }
            // Deterministic starting positions also exercise presets initialized from current geometry.
            node.center = Point(x: Double(index % 16) * 120, y: Double(index / 16) * 80)
            graph.addNode(node)
        }
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent { try graph.moveNode(graph.nodes[index], to: graph.nodes[parent]) }
        }
        for edge in edges {
            // One route per record. Bidirectionality is presentation data, not a duplicate reverse route.
            graph.addEdge(LayoutEdge(source: graph.nodes[edge.source], target: graph.nodes[edge.target], data: edge))
        }
        return graph
    }

    func drawing(_ graph: LayoutGraph) -> VisualDrawing {
        VisualDrawing(graph: graph, bidirectionalEdges: Set(edges.indices.filter { edges[$0].bidirectional }))
    }
}
