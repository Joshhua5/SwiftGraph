import Foundation

/// Remove excess empty strips without changing the drawing's topology. Node and
/// escape-zone projections are rigid; every other coordinate gap keeps enough
/// room for separate strokes. The strictly increasing maps preserve crossings,
/// port offsets, orthogonality and node dimensions in both axes.
enum DirectedDrawingCompaction {
    static func apply(nodes: [LayoutNode], edges: [LayoutEdge], clearance: Double, spacing: Double) throws {
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
            var mapped = [first], interval = 0
            for i in coordinates.indices.dropFirst() {
                let a = coordinates[i - 1], b = coordinates[i]
                while interval < intervals.count && intervals[interval].1 <= a { interval += 1 }
                let rigid = interval < intervals.count && intervals[interval].0 < b
                mapped.append(mapped.last! + (rigid ? b - a : min(b - a, spacing)))
            }
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
