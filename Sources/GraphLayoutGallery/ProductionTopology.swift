import Foundation
import SwiftGraph
import SwiftGraphUI

/// A production graph exported as compact topology JSON (the same format as `Tests/Fixtures/graph-topology.json`):
/// array positions are node IDs, and `parent`/`source`/`target` are zero-based indices into `nodes`.
struct ProductionTopology: Decodable, Sendable {
    struct Node: Decodable, Sendable { var parent: Int? }

    struct Edge: Decodable, Sendable, GraphEdgeDescriptor {
        var source: Int
        var target: Int
        var bidirectional: Bool

        var isBidirectional: Bool { bidirectional }
    }

    var nodes: [Node]
    var edges: [Edge]

    struct InvalidTopology: Error, CustomStringConvertible { var description: String }

    static func load(from url: URL) throws -> ProductionTopology {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func makeGraph() throws -> LayoutGraph {
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent, !nodes.indices.contains(parent) {
                throw InvalidTopology(description: "Node \(index) has invalid parent index \(parent)")
            }
        }
        for index in nodes.indices {
            var cursor: Int? = index
            var seen = Set<Int>()
            while let current = cursor {
                guard seen.insert(current).inserted else {
                    throw InvalidTopology(description: "Cyclic parent hierarchy at node \(index)")
                }
                cursor = nodes[current].parent
            }
        }
        for (index, edge) in edges.enumerated() {
            guard nodes.indices.contains(edge.source), nodes.indices.contains(edge.target) else {
                throw InvalidTopology(
                    description: "Edge \(index) has invalid endpoint indices \(edge.source), \(edge.target)"
                )
            }
        }

        let graph = LayoutGraph()
        let groups = Set(nodes.compactMap(\.parent))
        for index in nodes.indices {
            let node = LayoutNode(id: "\(index)", width: 80, height: 32)
            node.isGroup = groups.contains(index)
            if node.isGroup {
                node.groupFrame = GroupFrameOptions(
                    padding: LayoutInsets(top: 16, left: 20, bottom: 20, right: 20),
                    headerSize: Size(width: 80, height: 22)
                )
            }
            // Deterministic starting positions, so presets that start from current geometry are reproducible.
            node.center = Point(x: Float(index % 16) * 120, y: Float(index / 16) * 80)
            graph.addNode(node)
        }
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent { try graph.moveNode(graph.nodes[index], to: graph.nodes[parent]) }
        }
        for edge in edges {
            // One route per record; bidirectionality is drawn as a second arrowhead, not a reverse edge.
            graph.addEdge(LayoutEdge(source: graph.nodes[edge.source], target: graph.nodes[edge.target], data: edge))
        }
        return graph
    }
}

// MARK: - Library folder
