import Foundation

/// Remove excess empty strips without changing the drawing's topology. Node and
/// escape-zone projections are rigid; every other coordinate gap keeps `spacing` per
/// track. Gaps between node columns keep the layer spacing (between node rows, the node
/// spacing) measured between node bodies, so compaction never squeezes the layout itself.
/// The strictly increasing maps preserve crossings, port offsets, orthogonality and node
/// dimensions in both axes.
enum DirectedDrawingCompaction {
    static func apply(nodes: [LayoutNode], edges: [LayoutEdge], clearance: Double, spacing: Double,
                      layerSpacing: Double, nodeSpacing: Double) throws {
        for horizontal in [true, false] {
            try Task.checkCancellation()
            let projections = nodes.map { node -> (Double, Double) in
                let r = node.bounds.inflated(by: clearance)
                return horizontal ? (r.left, r.right) : (r.top, r.bottom)
            }.sorted { $0.0 < $1.0 }
            var intervals: [(Double, Double)] = []
            for p in projections {
                if let last = intervals.last, p.0 <= last.1 { intervals[intervals.count - 1].1 = max(last.1, p.1) }
                else { intervals.append(p) }
            }
            let points = edges.flatMap(\.path) + nodes.flatMap {
                [Point(x: $0.bounds.left, y: $0.bounds.top), $0.center, Point(x: $0.bounds.right, y: $0.bounds.bottom)]
            }
            let coordinates = Array(Set(points.map { horizontal ? $0.x : $0.y } + intervals.flatMap { [$0.0, $0.1] })).sorted()
            guard let first = coordinates.first else { continue }
            // Bodies are `clearance` inside the padded intervals, so the padded gap keeps the body gap.
            let required = max(0, (horizontal ? layerSpacing : nodeSpacing) - 2 * clearance)
            var steps = [0.0], gaps: [Int: [Int]] = [:], interval = 0
            for i in coordinates.indices.dropFirst() {
                let a = coordinates[i - 1], b = coordinates[i]
                while interval < intervals.count && intervals[interval].1 <= a { interval += 1 }
                let rigid = interval < intervals.count && intervals[interval].0 < b
                steps.append(rigid ? b - a : min(b - a, spacing))
                if !rigid && interval > 0 && interval < intervals.count { gaps[interval, default: []].append(i) }
            }
            // Within a gap between two blocks, the tracks keep their spacing; the gap as a whole
            // is stretched back up to the required spacing (never beyond its original width).
            for indices in gaps.values {
                let kept = indices.reduce(0.0) { $0 + steps[$1] }
                let original = indices.reduce(0.0) { $0 + coordinates[$1] - coordinates[$1 - 1] }
                let target = min(original, required)
                if kept > 0 && kept < target { for i in indices { steps[i] *= target / kept } }
            }
            var mapped = [first]
            for i in coordinates.indices.dropFirst() { mapped.append(mapped.last! + steps[i]) }
            let values = Dictionary(uniqueKeysWithValues: zip(coordinates, mapped))
            for node in nodes {
                if horizontal { node.x = values[node.bounds.left]! }
                else { node.y = values[node.bounds.top]! }
            }
            for edge in edges {
                edge.path = edge.path.map { p in
                    horizontal ? Point(x: values[p.x]!, y: p.y) : Point(x: p.x, y: values[p.y]!)
                }
            }
        }
    }
}
