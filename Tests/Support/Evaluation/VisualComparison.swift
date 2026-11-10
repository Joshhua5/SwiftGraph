import Foundation
import SwiftGraph

#if canImport(CryptoKit)
import CryptoKit
#endif

struct VisualDifference: Codable, Equatable {
    var changedNodes: [String] = []
    var changedEdges: [String] = []
    var configurationChanged = false
    var metricDeltas: [String: Double] = [:]
    var qualityFlags: [String] = []
    var changed: Bool { !changedNodes.isEmpty || !changedEdges.isEmpty || configurationChanged }
}

enum VisualComparison {
    static func equal(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-6 }

    /// 1e-5, widened to a few ulps where Float resolution is coarser (above ~256 one ulp alone exceeds 1e-5),
    /// so rounding noise is never reported as a geometry change.
    static func tolerance(_ a: Float, _ b: Float) -> Float { max(1e-5, 4 * max(abs(a), abs(b)).ulp) }

    static func equal(_ a: Float, _ b: Float) -> Bool { abs(a - b) <= tolerance(a, b) }

    static func equal(_ a: Point, _ b: Point) -> Bool { equal(a.x, b.x) && equal(a.y, b.y) }

    static func equal(_ a: Rect, _ b: Rect) -> Bool {
        equal(a.x, b.x) && equal(a.y, b.y) && equal(a.width, b.width) && equal(a.height, b.height)
    }

    static func equal(_ a: Rect?, _ b: Rect?) -> Bool {
        switch (a, b) {
        case (let a?, let b?): equal(a, b)
        case (nil, nil): true
        default: false
        }
    }

    static func compare(_ before: VisualSnapshot, _ after: VisualSnapshot) -> VisualDifference {
        var diff = VisualDifference()
        let aNodes = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
        let bNodes = Dictionary(uniqueKeysWithValues: after.nodes.map { ($0.id, $0) })
        for id in Set(aNodes.keys).union(bNodes.keys).sorted() {
            guard let a = aNodes[id], let b = bNodes[id] else {
                diff.changedNodes.append(id)
                continue
            }
            if !equal(a.bounds, b.bounds) || !equal(a.contentBounds, b.contentBounds)
                || !equal(a.headerBounds, b.headerBounds)
                || a.name != b.name || a.parent != b.parent || a.group != b.group
            {
                diff.changedNodes.append(id)
            }
        }
        let aEdges = Dictionary(uniqueKeysWithValues: before.edges.map { ($0.id, $0) })
        let bEdges = Dictionary(uniqueKeysWithValues: after.edges.map { ($0.id, $0) })
        for id in Set(aEdges.keys).union(bEdges.keys).sorted() {
            guard let a = aEdges[id], let b = bEdges[id] else {
                diff.changedEdges.append(id)
                continue
            }
            if a.source != b.source || a.target != b.target || a.path.count != b.path.count
                || !zip(a.path, b.path).allSatisfy({ equal($0, $1) })
                || a.label != b.label || !equal(a.labelBounds, b.labelBounds) || !equal(a.width, b.width)
                || (a.bidirectional ?? false) != (b.bidirectional ?? false)
            {
                diff.changedEdges.append(id)
            }
        }
        // Reference fixtures describe raw geometry, not the visual tool's recipe metadata.
        diff.configurationChanged =
            after.family != "reference"
            && (before.configuration != after.configuration || before.contracts != after.contracts)
        let a = VisualGeometry.measure(before).values
        let b = VisualGeometry.measure(after).values
        let lowerIsUsuallyBetter: Set<String> = [
            "nodeOverlaps", "edgeNodeIntersections", "crossings", "sharedSegments", "missingRoutes", "fallbackRoutes",
            "labelNodeOverlaps", "labelLabelOverlaps", "bends", "routeLength", "displacement",
            "nearParallelRuns", "endpointsInsideNodes", "endpointsAtCorners", "microSegments",
        ]
        let higherIsUsuallyBetter: Set<String> = ["minEdgeNodeClearance"]
        for key in Set(a.keys).union(b.keys).sorted() {
            // The C# corpus stores paths and bounds, but no fallback classifications.
            if before.configuration["oracle"] == "csharp-paths-and-bounds" && key == "fallbackRoutes" { continue }
            // Clearance is absent when a drawing has no edge/node pair, so it is only comparable when both sides report
            // it.
            if higherIsUsuallyBetter.contains(key) && (a[key] == nil || b[key] == nil) { continue }
            let delta = b[key, default: 0] - a[key, default: 0]
            if abs(delta) > 1e-6 {
                diff.metricDeltas[key] = delta
                if (delta > 0 && lowerIsUsuallyBetter.contains(key))
                    || (delta < 0 && higherIsUsuallyBetter.contains(key))
                {
                    diff.qualityFlags.append(key)
                }
            }
        }
        return diff
    }
}
