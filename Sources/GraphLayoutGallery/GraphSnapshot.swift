import Foundation
import SwiftGraph

/// A Sendable copy of a laid-out graph, so layout can run off the main actor
/// and the result can be handed to SwiftUI for drawing.
struct GraphSnapshot: Sendable {
    struct Node: Sendable, Identifiable {
        var id: String
        var name: String
        var frame: CGRect
        var isGroup: Bool
        var depth: Int
        var headerFrame: CGRect?
    }

    struct Edge: Sendable, Identifiable {
        var id: Int
        var points: [CGPoint]
        var label: String?
        var labelFrame: CGRect?
        var isSelfLoop: Bool
        var isBidirectional = false
    }

    var nodes: [Node]
    var edges: [Edge]
    var duration: Duration

    /// World-space rectangle enclosing every node, route and label.
    var worldBounds: CGRect {
        var rects = nodes.map(\.frame) + edges.compactMap(\.labelFrame)
        rects += edges.flatMap(\.points).map { CGRect(origin: $0, size: .zero) }
        guard let first = rects.first else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    init(graph: LayoutGraph, duration: Duration) {
        func depth(of node: LayoutNode) -> Int {
            var count = 0, cursor = node.parent
            while let parent = cursor, parent !== graph.root { count += 1; cursor = parent.parent }
            return count
        }
        // Draw outer groups first so nested groups and leaves sit on top of them.
        nodes = graph.nodes.map {
            Node(id: $0.id, name: $0.name, frame: CGRect($0.bounds), isGroup: $0.isGroup,
                 depth: depth(of: $0), headerFrame: $0.groupHeaderBounds.map(CGRect.init))
        }.sorted { ($0.isGroup ? 0 : 1, $0.depth) < ($1.isGroup ? 0 : 1, $1.depth) }
        edges = graph.edges.enumerated().map { index, edge in
            let hasLabel = edge.labelBounds.width > 0 && edge.labelBounds.height > 0
            return Edge(id: index, points: edge.path.map(CGPoint.init), label: edge.data as? String,
                        labelFrame: hasLabel ? CGRect(edge.labelBounds) : nil,
                        isSelfLoop: edge.source === edge.target,
                        isBidirectional: (edge.data as? ProductionTopology.Edge)?.bidirectional ?? false)
        }
        self.duration = duration
    }
}

extension CGRect {
    init(_ rect: Rect) {
        self.init(x: CGFloat(rect.x), y: CGFloat(rect.y), width: CGFloat(rect.width), height: CGFloat(rect.height))
    }
}

extension CGPoint {
    init(_ point: Point) { self.init(x: CGFloat(point.x), y: CGFloat(point.y)) }
}
