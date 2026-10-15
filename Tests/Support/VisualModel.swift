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
    var framedGroups = false
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
                  noLabelOverlaps: try c.decodeIfPresent(Bool.self, forKey: .noLabelOverlaps) ?? false,
                  framedGroups: try c.decodeIfPresent(Bool.self, forKey: .framedGroups) ?? false)
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
    var contentBounds: Rect? = nil
    var headerBounds: Rect? = nil
}

struct VisualEdge: Codable, Equatable, Sendable {
    var id: String
    var source: String
    var target: String
    var path: [Point]
    var label: String?
    var labelBounds: Rect
    var width: Float = 1.5
    var fallback = false
    // Optional so existing v1 snapshots without this field still decode.
    var bidirectional: Bool? = nil
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
                       parent: $0.parent === drawing.graph.root ? nil : $0.parent?.id, group: $0.isGroup,
                       contentBounds: $0.groupContentBounds, headerBounds: $0.groupHeaderBounds)
        }
        edges = drawing.graph.edges.enumerated().map { index, edge in
            VisualEdge(id: "e\(index)", source: edge.source.id, target: edge.target.id,
                       path: edge.path, label: edge.data as? String, labelBounds: edge.labelBounds,
                       width: drawing.edgeWidths.indices.contains(index) ? drawing.edgeWidths[index] : 1.5,
                       fallback: drawing.fallbackEdges.contains(index),
                       bidirectional: drawing.bidirectionalEdges.contains(index) ? true : nil)
        }
        previousBounds = drawing.previousBounds; fixedCenters = drawing.fixedCenters
        reportedMetrics = drawing.reportedMetrics; notes = drawing.notes
    }

    var isFinite: Bool {
        nodes.allSatisfy { valid($0.bounds) && $0.contentBounds.map(valid) != false && $0.headerBounds.map(valid) != false } && edges.allSatisfy {
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
    var edgeWidths: [Float] = []
    var reportedMetrics: [String: Double] = [:]
    var notes: [String] = []
    var additionalFailures: [VisualFinding] = []
    var bidirectionalEdges: Set<Int> = []
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
    static let epsilon: Float = 1e-5
    static func cross(_ a: Point, _ b: Point) -> Float { a.x * b.y - a.y * b.x }
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
    // Advisory thresholds (world units / radians) for the routing-quality metrics.
    static let bendTolerance = Float(2.0 * Double.pi / 180)
    static let parallelAngle = Float(3.0 * Double.pi / 180)
    static let parallelSpacing: Float = 8.0, parallelOverlap: Float = 12.0
    static let endpointInset: Float = 0.5, cornerRadius: Float = 3.0, microLength: Float = 4.0, tightClearance: Float = 2.0
    static func turn(_ a: Point, _ b: Point) -> Float { atan2(abs(cross(a, b)), a.x * b.x + a.y * b.y) }
    // Near-parallel, closer than `parallelSpacing`, with projected overlap beyond `parallelOverlap` (includes exact overlap).
    static func nearParallel(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        let u = b - a, v = d - c, lu = u.length, lv = v.length
        guard lu > epsilon, lv > epsilon, abs(cross(u, v)) / (lu * lv) < sin(parallelAngle) else { return false }
        guard max(abs(cross(u, c - a)), abs(cross(u, d - a))) / lu < parallelSpacing else { return false }
        let t = ((c.x - a.x) * u.x + (c.y - a.y) * u.y) / lu, s = ((d.x - a.x) * u.x + (d.y - a.y) * u.y) / lu
        return min(lu, max(t, s)) - max(0, min(t, s)) > parallelOverlap
    }
    static func distance(_ p: Point, toSegment a: Point, _ b: Point) -> Float {
        let u = b - a, l2 = u.lengthSquared
        let t = l2 > epsilon ? min(1, max(0, ((p.x - a.x) * u.x + (p.y - a.y) * u.y) / l2)) : 0
        return (p - (a + u * t)).length
    }
    static func distance(_ p: Point, to r: Rect) -> Float { hypot(max(r.left - p.x, 0, p.x - r.right), max(r.top - p.y, 0, p.y - r.bottom)) }
    static func corners(_ r: Rect) -> [Point] { [Point(x: r.left, y: r.top), Point(x: r.right, y: r.top), Point(x: r.right, y: r.bottom), Point(x: r.left, y: r.bottom)] }
    // Disjoint convex shapes: the minimum is attained at a segment endpoint or a rectangle corner.
    static func distance(_ a: Point, _ b: Point, to r: Rect) -> Float {
        if r.intersectsLine(a, b) { return 0 }
        return min(distance(a, to: r), distance(b, to: r), corners(r).map { distance($0, toSegment: a, b) }.min()!)
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
        var length = 0.0, bends = 0, displacement = 0.0, clearance: Float?
        for node in nodes {
            if let previous = snapshot.previousBounds[node.id] { displacement += Double((previous.center - node.bounds.center).length) }
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
                length += Double((b - a).length)
                if snapshot.contracts.orthogonal && (snapshot.contracts.orthogonalSelfLoops || edge.source != edge.target)
                    && abs(a.x - b.x) > epsilon && abs(a.y - b.y) > epsilon {
                    failures.append(.init(kind: "nonorthogonal-segment", elements: [edge.id]))
                }
            }
            for (first, second) in zip(segments, segments.dropFirst()) {
                if turn(first.1 - first.0, second.1 - second.0) > bendTolerance { bends += 1 }
            }
            if segments.count > 1 {
                for _ in segments.filter({ ($0.1 - $0.0).length < microLength }) { findings.append(.init(kind: "micro-segment", elements: [edge.id])) }
            }
            if edge.path.count > 1, let source = byID[edge.source], let target = byID[edge.target] {
                for (point, node) in [(edge.path[0], source), (edge.path[edge.path.count - 1], target)] {
                    if node.bounds.inflated(by: -endpointInset).contains(point) && node.bounds.width > 2 * endpointInset && node.bounds.height > 2 * endpointInset {
                        findings.append(.init(kind: "endpoint-inside-node", elements: [edge.id, node.id]))
                    }
                    if corners(node.bounds).contains(where: { ($0 - point).length <= cornerRadius }) {
                        findings.append(.init(kind: "endpoint-at-corner", elements: [edge.id, node.id]))
                    }
                }
            }
            // Leaf nodes only, excluding the endpoints and anything inside an endpoint group.
            for node in nodes where !node.group && node.id != edge.source && node.id != edge.target
                && !ancestor(edge.source, of: node) && !ancestor(edge.target, of: node) {
                guard let d = segments.map({ distance($0.0, $0.1, to: node.bounds) }).min() else { continue }
                clearance = min(clearance ?? d, d)
                if d < tightClearance { findings.append(.init(kind: "edge-node-clearance", elements: [edge.id, node.id])) }
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
                    if nearParallel(a, b, c, d) { findings.append(.init(kind: "near-parallel-run", elements: [edge.id, edges[j].id])) }
                } }
            }
        }
        if snapshot.contracts.framedGroups {
            func contains(_ outer: Rect, _ inner: Rect) -> Bool {
                let magnitude = [outer.left, outer.right, outer.top, outer.bottom, inner.left, inner.right, inner.top, inner.bottom].map(abs).max() ?? 0
                let allowance = max(epsilon, magnitude.ulp * 4)
                return inner.left >= outer.left - allowance && inner.right <= outer.right + allowance &&
                inner.top >= outer.top - allowance && inner.bottom <= outer.bottom + allowance
            }
            for node in nodes {
                if let parent = node.parent.flatMap({ byID[$0] }), let content = parent.contentBounds,
                   !contains(content, node.bounds) {
                    failures.append(.init(kind: "frame-content-overflow", elements: [parent.id, node.id]))
                }
            }
            for (i, edge) in edges.enumerated() {
                guard let source = byID[edge.source], let target = byID[edge.target] else { continue }
                for frame in nodes where frame.group {
                    if frame.id != source.id && frame.id != target.id && !ancestor(frame.id, of: source) && !ancestor(frame.id, of: target),
                       paths[i].contains(where: { frame.bounds.inflated(by: -epsilon).intersectsLine($0.0, $0.1) }) {
                        failures.append(.init(kind: "edge-frame-intersection", elements: [edge.id, frame.id]))
                    }
                    if let header = frame.headerBounds, header.height > 0,
                       paths[i].contains(where: { header.inflated(by: -epsilon).intersectsLine($0.0, $0.1) }) {
                        failures.append(.init(kind: "edge-header-intersection", elements: [edge.id, frame.id]))
                    }
                    if ancestor(frame.id, of: source) && ancestor(frame.id, of: target), let content = frame.contentBounds {
                        if !edge.path.allSatisfy({ content.inflated(by: epsilon).contains($0) }) ||
                           (edge.labelBounds.width > 0 && edge.labelBounds.height > 0 && !contains(content, edge.labelBounds)) {
                            failures.append(.init(kind: "frame-route-overflow", elements: [edge.id, frame.id]))
                        }
                    }
                }
            }
            findings += failures.filter { $0.kind.hasPrefix("frame-") || $0.kind == "edge-frame-intersection" || $0.kind == "edge-header-intersection" }
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
            "nearParallelRuns": count("near-parallel-run"), "endpointsInsideNodes": count("endpoint-inside-node"),
            "endpointsAtCorners": count("endpoint-at-corner"), "microSegments": count("micro-segment"),
            "displacement": displacement, "drawingWidth": Double(bounds.width), "drawingHeight": Double(bounds.height)]
        let leafRects = nodes.filter { !$0.group }.map(\.bounds)
        let nodeBounds = leafRects.first.map { first in leafRects.dropFirst().reduce(first) { $0.union($1) } } ?? Rect()
        let nodeArea = leafRects.reduce(0.0) { $0 + Double($1.width) * Double($1.height) }
        let routeLengths = paths.map { $0.reduce(0.0) { $0 + Double(($1.1 - $1.0).length) } }.sorted()
        func percentile(_ p: Double) -> Double {
            guard !routeLengths.isEmpty else { return 0 }
            return routeLengths[min(routeLengths.count - 1, Int(ceil(p * Double(routeLengths.count))) - 1)]
        }
        values["nodeAreaUtilization"] = nodeBounds.width * nodeBounds.height > 0 ? nodeArea / (Double(nodeBounds.width) * Double(nodeBounds.height)) : 0
        values["medianEdgeLength"] = percentile(0.5); values["p95EdgeLength"] = percentile(0.95)
        if let clearance { values["minEdgeNodeClearance"] = Double(clearance) } // absent when no edge/node pair exists
        for (key, value) in snapshot.reportedMetrics { values["reported.\(key)"] = value }
        return VisualMetrics(values: values, findings: findings, failures: failures)
    }
}
