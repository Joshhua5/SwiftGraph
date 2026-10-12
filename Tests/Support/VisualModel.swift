import Foundation
import SwiftGraph

struct VisualContracts: Codable, Equatable, Sendable {
    var routesRequired = true
    var noNodeOverlaps = false
    var noObstacleIntersections = false
    var orthogonal = false
    var orthogonalSelfLoops = true
    var expectMissingRoutes = false
    var noLabelOverlaps = false
}

extension VisualContracts {
    // Early v1 snapshots checked every segment; the later per-loop override defaults to that behavior.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(routesRequired: try c.decode(Bool.self, forKey: .routesRequired),
                  noNodeOverlaps: try c.decode(Bool.self, forKey: .noNodeOverlaps),
                  noObstacleIntersections: try c.decode(Bool.self, forKey: .noObstacleIntersections),
                  orthogonal: try c.decode(Bool.self, forKey: .orthogonal),
                  orthogonalSelfLoops: try c.decodeIfPresent(Bool.self, forKey: .orthogonalSelfLoops) ?? true,
                  expectMissingRoutes: try c.decode(Bool.self, forKey: .expectMissingRoutes),
                  noLabelOverlaps: try c.decodeIfPresent(Bool.self, forKey: .noLabelOverlaps) ?? false)
    }
}

struct VisualFinding: Codable, Equatable, Sendable {
    var kind: String
    var elements: [String]
}

struct VisualNode: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var bounds: Rect
    var parent: String?
    var group: Bool
}

struct VisualEdge: Codable, Equatable, Sendable {
    var id: String
    var source: String
    var target: String
    var path: [Point]
    var label: String?
    var labelBounds: Rect
    var width: Double = 1.5
    var fallback = false
}

struct VisualSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var id: String
    var family: String
    var title: String
    var configuration: [String: String]
    var contracts: VisualContracts
    var nodes: [VisualNode]
    var edges: [VisualEdge]
    var previousBounds: [String: Rect] = [:]
    var fixedCenters: [String: Point] = [:]
    var reportedMetrics: [String: Double] = [:]
    var measuredMetrics: [String: Double]?
    var notes: [String] = []

    init(case item: VisualCase, drawing: VisualDrawing) {
        id = item.id; family = item.family; title = item.title
        configuration = item.configuration; contracts = item.contracts
        nodes = drawing.graph.nodes.map {
            VisualNode(id: $0.id, name: $0.name, bounds: $0.bounds,
                       parent: $0.parent === drawing.graph.root ? nil : $0.parent?.id, group: $0.isGroup)
        }
        edges = drawing.graph.edges.enumerated().map { index, edge in
            VisualEdge(id: "e\(index)", source: edge.source.id, target: edge.target.id,
                       path: edge.path, label: edge.data as? String, labelBounds: edge.labelBounds,
                       width: drawing.edgeWidths.indices.contains(index) ? drawing.edgeWidths[index] : 1.5,
                       fallback: drawing.fallbackEdges.contains(index))
        }
        previousBounds = drawing.previousBounds; fixedCenters = drawing.fixedCenters
        reportedMetrics = drawing.reportedMetrics; notes = drawing.notes
    }

    var isFinite: Bool {
        nodes.allSatisfy { valid($0.bounds) } && edges.allSatisfy {
            valid($0.labelBounds) && $0.width.isFinite && $0.width > 0 && $0.path.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        } && previousBounds.values.allSatisfy(valid) && fixedCenters.values.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }
}

func valid(_ r: Rect) -> Bool {
    [r.x, r.y, r.width, r.height, r.right, r.bottom].allSatisfy(\.isFinite) && r.width >= 0 && r.height >= 0
}

struct VisualDrawing {
    var graph: LayoutGraph
    var previousBounds: [String: Rect] = [:]
    var fixedCenters: [String: Point] = [:]
    var fallbackEdges: [Int] = []
    var edgeWidths: [Double] = []
    var reportedMetrics: [String: Double] = [:]
    var notes: [String] = []
    var additionalFailures: [VisualFinding] = []
}

struct VisualCase {
    var id: String
    var family: String
    var title: String
    var configuration: [String: String] = [:]
    var contracts = VisualContracts()
    var smoke = false
    var metal = false
    var run: () async throws -> VisualDrawing
}

struct VisualMetrics: Codable, Equatable, Sendable {
    var values: [String: Double]
    var findings: [VisualFinding]
    var failures: [VisualFinding]
}

enum VisualGeometry {
    static let epsilon = 1e-6
    static func cross(_ a: Point, _ b: Point) -> Double { a.x * b.y - a.y * b.x }
    static func segments(_ points: [Point]) -> [(Point, Point)] {
        zip(points, points.dropFirst()).filter { ($0.1 - $0.0).length > epsilon }.map { ($0.0, $0.1) }
    }
    // Proper intersections exclude touching endpoints. Shared collinear runs are a separate metric.
    static func crossing(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        let u = b - a, v = d - c, denominator = cross(u, v)
        guard abs(denominator) > epsilon else { return false }
        let t = cross(c - a, v) / denominator, s = cross(c - a, u) / denominator
        return t > epsilon && t < 1 - epsilon && s > epsilon && s < 1 - epsilon
    }
    static func shared(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        let u = b - a, length = u.length
        guard length > epsilon, abs(cross(u, c - a)) / length < epsilon,
              abs(cross(u, d - a)) / length < epsilon else { return false }
        let t = ((c.x - a.x) * u.x + (c.y - a.y) * u.y) / length
        let s = ((d.x - a.x) * u.x + (d.y - a.y) * u.y) / length
        return min(length, max(t, s)) - max(0, min(t, s)) > epsilon
    }
    static func measure(_ snapshot: VisualSnapshot) -> VisualMetrics {
        guard snapshot.isFinite else {
            return VisualMetrics(values: [:], findings: [], failures: [.init(kind: "nonfinite-or-negative-geometry", elements: [])])
        }
        let nodes = snapshot.nodes, edges = snapshot.edges
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        func ancestor(_ parent: String, of child: VisualNode) -> Bool {
            var cursor = child.parent, seen = Set<String>()
            while let id = cursor, seen.insert(id).inserted {
                if id == parent { return true }; cursor = byID[id]?.parent
            }
            return false
        }
        var findings: [VisualFinding] = [], failures: [VisualFinding] = []
        for (i, a) in nodes.enumerated() {
            for b in nodes.dropFirst(i + 1) where !ancestor(a.id, of: b) && !ancestor(b.id, of: a) {
                if a.bounds.intersects(b.bounds) { findings.append(.init(kind: "node-overlap", elements: [a.id, b.id])) }
            }
        }
        var length = 0.0, bends = 0, displacement = 0.0
        for node in nodes {
            if let previous = snapshot.previousBounds[node.id] { displacement += (previous.center - node.bounds.center).length }
            if let center = snapshot.fixedCenters[node.id], (center - node.bounds.center).length > epsilon {
                failures.append(.init(kind: "fixed-center-moved", elements: [node.id]))
            }
        }
        let paths = edges.map { segments($0.path) }
        for (i, edge) in edges.enumerated() {
            let segments = paths[i]
            if edge.path.count < 2 { findings.append(.init(kind: "missing-route", elements: [edge.id])) }
            if edge.fallback { findings.append(.init(kind: "fallback-route", elements: [edge.id])) }
            for (a, b) in segments {
                length += (b - a).length
                if snapshot.contracts.orthogonal && (snapshot.contracts.orthogonalSelfLoops || edge.source != edge.target)
                    && abs(a.x - b.x) > epsilon && abs(a.y - b.y) > epsilon {
                    failures.append(.init(kind: "nonorthogonal-segment", elements: [edge.id]))
                }
            }
            for (first, second) in zip(segments, segments.dropFirst()) {
                let a = first.1 - first.0, b = second.1 - second.0
                if abs(cross(a, b)) / max(epsilon, a.length * b.length) > epsilon || a.x * b.x + a.y * b.y < 0 { bends += 1 }
            }
            for node in nodes where !node.group && node.id != edge.source && node.id != edge.target {
                let inner = node.bounds.inflated(by: -epsilon)
                if inner.width > 0 && inner.height > 0 && segments.contains(where: { inner.intersectsLine($0.0, $0.1) }) {
                    findings.append(.init(kind: "edge-node-intersection", elements: [edge.id, node.id]))
                }
            }
            if edge.label != nil && edge.labelBounds.width > 0 {
                for node in nodes where !node.group && node.bounds.intersects(edge.labelBounds) {
                    findings.append(.init(kind: "label-node-overlap", elements: [edge.id, node.id]))
                }
            }
            for j in edges.indices where j > i {
                if edge.label != nil && edges[j].label != nil && edge.labelBounds.width > 0 && edge.labelBounds.height > 0
                    && edges[j].labelBounds.width > 0 && edges[j].labelBounds.height > 0 && edge.labelBounds.intersects(edges[j].labelBounds) {
                    findings.append(.init(kind: "label-label-overlap", elements: [edge.id, edges[j].id]))
                }
                for (a, b) in segments { for (c, d) in paths[j] {
                    if crossing(a, b, c, d) { findings.append(.init(kind: "crossing", elements: [edge.id, edges[j].id])) }
                    if shared(a, b, c, d) { findings.append(.init(kind: "shared-segment", elements: [edge.id, edges[j].id])) }
                } }
            }
        }
        func count(_ kind: String) -> Double { Double(findings.filter { $0.kind == kind }.count) }
        for finding in findings {
            if (finding.kind == "missing-route" && snapshot.contracts.routesRequired)
                || (finding.kind == "node-overlap" && snapshot.contracts.noNodeOverlaps)
                || (finding.kind == "edge-node-intersection" && snapshot.contracts.noObstacleIntersections)
                || (["label-label-overlap", "label-node-overlap"].contains(finding.kind) && snapshot.contracts.noLabelOverlaps) { failures.append(finding) }
        }
        if snapshot.contracts.expectMissingRoutes && count("missing-route") == 0 {
            failures.append(.init(kind: "expected-unroutable-diagnostic", elements: []))
        }
        let bounds = VisualScene(snapshot: snapshot).bounds
        var values: [String: Double] = ["nodes": Double(nodes.count), "edges": Double(edges.count),
            "nodeOverlaps": count("node-overlap"), "edgeNodeIntersections": count("edge-node-intersection"),
            "crossings": count("crossing"), "sharedSegments": count("shared-segment"),
            "missingRoutes": count("missing-route"), "fallbackRoutes": count("fallback-route"),
            "labelNodeOverlaps": count("label-node-overlap"), "labelLabelOverlaps": count("label-label-overlap"), "bends": Double(bends), "routeLength": length,
            "displacement": displacement, "drawingWidth": bounds.width, "drawingHeight": bounds.height]
        let leafRects = nodes.filter { !$0.group }.map(\.bounds)
        let nodeBounds = leafRects.first.map { first in leafRects.dropFirst().reduce(first) { $0.union($1) } } ?? Rect()
        let nodeArea = leafRects.reduce(0.0) { $0 + $1.width * $1.height }
        let routeLengths = paths.map { $0.reduce(0.0) { $0 + ($1.1 - $1.0).length } }.sorted()
        func percentile(_ p: Double) -> Double {
            guard !routeLengths.isEmpty else { return 0 }
            return routeLengths[min(routeLengths.count - 1, Int(ceil(p * Double(routeLengths.count))) - 1)]
        }
        values["nodeAreaUtilization"] = nodeBounds.width * nodeBounds.height > 0 ? nodeArea / (nodeBounds.width * nodeBounds.height) : 0
        values["medianEdgeLength"] = percentile(0.5); values["p95EdgeLength"] = percentile(0.95)
        for (key, value) in snapshot.reportedMetrics { values["reported.\(key)"] = value }
        return VisualMetrics(values: values, findings: findings, failures: failures)
    }
}
