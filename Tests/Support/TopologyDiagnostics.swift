import Foundation
import SwiftGraph

/// Linear edge/node checks, avoiding the gallery's exhaustive edge/edge crossing audit.
struct TopologyDiagnostics: Codable, Sendable {
    struct Detour: Codable, Sendable {
        var edge: String
        var length: Float
        var directDistance: Float
        var ratio: Float
    }
    var drawingBounds: Rect
    var nodeBounds: Rect
    var escapedChildren: [String] = []
    var leafOverlaps: [[String]] = []
    var obstacleIntersections: [[String]] = []
    var headerIntersections: [[String]] = []
    var missingRoutes: [String] = []
    var endpointMismatches: [String] = []
    var detours: [Detour] = []
    var routeLength: Float = 0

    var passes: Bool {
        escapedChildren.isEmpty && leafOverlaps.isEmpty && obstacleIntersections.isEmpty && headerIntersections.isEmpty && missingRoutes.isEmpty && endpointMismatches.isEmpty
    }

    init(_ snapshot: VisualSnapshot) {
        drawingBounds = VisualScene(snapshot: snapshot, crossingJumps: false).bounds
        nodeBounds = snapshot.nodes.first.map { first in snapshot.nodes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) } } ?? Rect()
        let byID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        let epsilon: Float = 0.01
        func contains(_ outer: Rect, _ inner: Rect) -> Bool {
            inner.left >= outer.left - epsilon && inner.right <= outer.right + epsilon && inner.top >= outer.top - epsilon && inner.bottom <= outer.bottom + epsilon
        }
        func ancestor(_ id: String, _ node: VisualNode) -> Bool {
            var parent = node.parent, seen = Set<String>()
            while let p = parent, seen.insert(p).inserted {
                if p == id { return true }; parent = byID[p]?.parent
            }
            return false
        }
        for node in snapshot.nodes {
            if let parent = node.parent.flatMap({ byID[$0] }), let content = parent.contentBounds, !contains(content, node.bounds) {
                escapedChildren.append(node.id)
            }
        }
        let leaves = snapshot.nodes.filter { !$0.group }
        for (i, node) in leaves.enumerated() {
            for other in leaves.dropFirst(i + 1) where node.bounds.inflated(by: -epsilon).intersects(other.bounds) {
                leafOverlaps.append([node.id, other.id])
            }
        }
        for edge in snapshot.edges {
            guard edge.path.count >= 2, edge.path.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                missingRoutes.append(edge.id); continue
            }
            let segments = Array(zip(edge.path, edge.path.dropFirst())), envelope = pointBounds(edge.path)
            let length = segments.reduce(Float(0)) { $0 + ($1.1 - $1.0).length }
            routeLength += length
            guard let source = byID[edge.source], let target = byID[edge.target] else { missingRoutes.append(edge.id); continue }
            func attached(_ point: Point, _ rect: Rect) -> Bool {
                let magnitude = [rect.left, rect.right, rect.top, rect.bottom].map(abs).max() ?? 0
                let tolerance = max(1.51, magnitude.ulp * 4)
                return rect.inflated(by: tolerance).contains(point) &&
                    min(abs(point.x - rect.left), abs(point.x - rect.right), abs(point.y - rect.top), abs(point.y - rect.bottom)) <= tolerance
            }
            if !attached(edge.path[0], source.bounds) || !attached(edge.path[edge.path.count - 1], target.bounds) { endpointMismatches.append(edge.id) }
            let direct = (source.bounds.center - target.bounds.center).length
            if direct > epsilon && length > 4 * direct {
                detours.append(.init(edge: edge.id, length: length, directDistance: direct, ratio: length / direct))
            }
            for node in snapshot.nodes {
                if node.id != source.id && node.id != target.id &&
                    !(node.group && (ancestor(node.id, source) || ancestor(node.id, target))) {
                    let r = node.bounds.inflated(by: -epsilon)
                    if r.width > 0 && r.height > 0 && r.intersects(envelope.inflated(by: epsilon)) && segments.contains(where: { r.intersectsLine($0, $1) }) {
                        obstacleIntersections.append([edge.id, node.id])
                    }
                }
                if node.id != source.id && node.id != target.id, let header = node.headerBounds {
                    let r = header.inflated(by: -epsilon)
                    if r.width > 0 && r.height > 0 && r.intersects(envelope.inflated(by: epsilon)) && segments.contains(where: { r.intersectsLine($0, $1) }) {
                        headerIntersections.append([edge.id, node.id])
                    }
                }
            }
        }
        detours.sort { $0.ratio == $1.ratio ? $0.edge < $1.edge : $0.ratio > $1.ratio }
    }
}
