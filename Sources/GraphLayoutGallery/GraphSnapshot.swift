import CoreGraphics
import Foundation
import SwiftGraph

/// A Sendable copy of a laid-out graph, so layout can run off the main actor
/// and the result can be handed to SwiftUI for drawing.
struct GraphSnapshot: Sendable {
    struct Lane: Sendable, Identifiable {
        var id: Int
        var title: String
        var frame: CGRect
        var headerHeight: CGFloat = 28
    }

    struct Node: Sendable, Identifiable {
        var id: String
        var name: String
        var frame: CGRect
        var isGroup: Bool
        var depth: Int
        var headerFrame: CGRect?
    }

    struct Bridge: Sendable {
        var start: CGPoint
        var end: CGPoint
    }

    struct Edge: Sendable, Identifiable {
        var id: Int
        var points: [CGPoint]
        var bridges: [Bridge] = []
        var label: String?
        var labelFrame: CGRect?
        var isSelfLoop: Bool
        var isBidirectional = false
    }

    var lanes: [Lane]
    var nodes: [Node]
    var edges: [Edge]
    var duration: Duration

    /// World-space rectangle enclosing every lane, node, route and label.
    var worldBounds: CGRect {
        var rects = lanes.map(\.frame) + nodes.map(\.frame) + edges.compactMap(\.labelFrame)
        rects += edges.flatMap(\.points).map { CGRect(origin: $0, size: .zero) }
        guard let first = rects.first else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    init(graph: LayoutGraph, duration: Duration, lanes: [Lane] = []) {
        func depth(of node: LayoutNode) -> Int {
            var count = 0, cursor = node.parent
            while let parent = cursor, parent !== graph.root { count += 1; cursor = parent.parent }
            return count
        }
        let storedLanes = (graph.root.data as? [Lane]) ?? []
        self.lanes = lanes.isEmpty ? storedLanes : lanes

        // Draw outer groups first so nested groups and leaves sit on top of them.
        nodes = graph.nodes.map {
            Node(id: $0.id, name: $0.name, frame: CGRect($0.bounds), isGroup: $0.isGroup,
                 depth: depth(of: $0), headerFrame: $0.groupHeaderBounds.map(CGRect.init))
        }.sorted { ($0.isGroup ? 0 : 1, $0.depth) < ($1.isGroup ? 0 : 1, $1.depth) }

        let computeBridges = graph.edges.count <= 200
        var drawnSegments: [(CGPoint, CGPoint)] = []
        edges = graph.edges.enumerated().map { index, edge in
            let points = Self.deduplicated(edge.path.map(CGPoint.init))
            let isSelfLoop = edge.source === edge.target
            var bridges: [Bridge] = []
            if computeBridges, !isSelfLoop, points.count >= 2 {
                let segments = Array(zip(points, points.dropFirst()))
                for (a, b) in segments {
                    let dx = b.x - a.x, dy = b.y - a.y
                    let len = hypot(dx, dy)
                    guard len > 10 else { continue }
                    let ux = dx / len, uy = dy / len
                    for (c, d) in drawnSegments {
                        guard let t = Self.intersectionParameter(a, b, c, d) else { continue }
                        let hit = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
                        let half = min(3.5, min(t * len, (1 - t) * len) * 0.42)
                        if half > 0.8 {
                            bridges.append(Bridge(
                                start: CGPoint(x: hit.x - ux * half, y: hit.y - uy * half),
                                end: CGPoint(x: hit.x + ux * half, y: hit.y + uy * half)
                            ))
                        }
                    }
                }
                drawnSegments.append(contentsOf: segments)
            }
            let hasLabel = edge.labelBounds.width > 0 && edge.labelBounds.height > 0
            return Edge(id: index, points: points, bridges: bridges, label: edge.data as? String,
                        labelFrame: hasLabel ? CGRect(edge.labelBounds) : nil,
                        isSelfLoop: isSelfLoop,
                        isBidirectional: (edge.data as? ProductionTopology.Edge)?.bidirectional ?? false)
        }
        self.duration = duration
    }

    private static func deduplicated(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(points.count)
        for p in points {
            if let last = out.last, hypot(p.x - last.x, p.y - last.y) < 0.25 { continue }
            out.append(p)
        }
        if out.count == 1, let last = points.last, points.count >= 2 {
            out.append(last)
        }
        return out
    }

    /// sin(25°): crossings shallower than this get no bridge.
    private static let minimumBridgeAngleSine: CGFloat = 0.42

    /// Returns parameter `t` in `(0, 1)` along `(a, b)` if `(a, b)` properly crosses `(c, d)`.
    private static func intersectionParameter(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat? {
        let minABX = min(a.x, b.x), maxABX = max(a.x, b.x)
        let minCDX = min(c.x, d.x), maxCDX = max(c.x, d.x)
        guard maxABX >= minCDX, maxCDX >= minABX else { return nil }
        let minABY = min(a.y, b.y), maxABY = max(a.y, b.y)
        let minCDY = min(c.y, d.y), maxCDY = max(c.y, d.y)
        guard maxABY >= minCDY, maxCDY >= minABY else { return nil }

        let ux = b.x - a.x, uy = b.y - a.y
        let vx = d.x - c.x, vy = d.y - c.y
        let denom = ux * vy - uy * vx
        // Only bridge clear crossings (about 25° or more). Shallow crossings are shared or bundled
        // tracks, where a bridge halo would chop the track into dashes.
        let lengths = hypot(ux, uy) * hypot(vx, vy)
        guard lengths > 1e-4, abs(denom) / lengths >= minimumBridgeAngleSine else { return nil }
        let wx = c.x - a.x, wy = c.y - a.y
        let t = (wx * vy - wy * vx) / denom
        let s = (wx * uy - wy * ux) / denom
        guard t > 0.06, t < 0.94, s > 0.06, s < 0.94 else { return nil }
        return t
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
