import Foundation

extension LayeredRouter {
    /// Only obstacles and occupied runs within this edge's horizontal span consume
    /// outer lanes. Unrelated edges elsewhere cannot push a feedback route outward.
    func exteriorLanes(from start: Point, to end: Point) -> [Float] {
        let left = min(start.x, end.x)
        let right = max(start.x, end.x)
        let local = obstacles.filter { $0.right >= left && $0.left <= right }
        let top = min(start.y, end.y, local.map(\.top).min() ?? start.y) - clearance
        let bottom = max(start.y, end.y, local.map(\.bottom).max() ?? start.y) + clearance
        return [(top, Float(-1.0)), (bottom, Float(1.0))]
            .map { initial, direction in
                var y = initial
                for _ in 0...occupied.segments.count {
                    let line = DirectedGeometry.Segment(a: Point(x: left, y: y), b: Point(x: right, y: y))
                    var blocked = false
                    occupied.forEach(near: line, margin: spacing) { _, other in
                        if DirectedGeometry.nearShared(line, other, spacing: spacing, minimumLength: 0) {
                            blocked = true
                        }
                    }
                    if !blocked { break }
                    y += direction * spacing
                }
                return y
            }
    }

    /// All forward edges crossing one rank gap use the same corridor. Sorting tracks
    /// against adjacent virtual nodes preserves the hierarchy's crossing reduction.
    func hierarchyPaths() -> [LayoutEdge: [Point]] {
        struct Transition {
            var edge: LayoutEdge
            var part: Int
            var a: Point
            var b: Point
        }
        let ranks = Array(Set(nodes.map { $0.center.x })).sorted()
        guard ranks.count > 1 else { return [:] }
        var corridors: [Int: [Transition]] = [:]
        var chains: [LayoutEdge: [Point]] = [:]
        for edge in edges where !feedback.contains(edge) && edge.source.center.x != edge.target.center.x {
            // A backward edge runs through the corridors like a forward one, with its points taken in rank order.
            let backward = edge.source.center.x > edge.target.center.x
            guard edge.path.count >= 2,
                let first = ranks.firstIndex(of: min(edge.source.center.x, edge.target.center.x)),
                let last = ranks.firstIndex(of: max(edge.source.center.x, edge.target.center.x)),
                edge.path.count == last - first + 1
            else { continue }
            let (start, end, sd, td) = ports[required: edge]
            guard backward ? (sd.x < 0 && td.x > 0) : (sd.x > 0 && td.x < 0) else { continue }
            let points = [start + sd * clearance] + edge.path.dropFirst().dropLast() + [end + td * clearance]
            chains[edge] = backward ? Array(points.reversed()) : Array(points)
            for part in 0..<(points.count - 1) {
                corridors[first + part, default: []]
                    .append(Transition(edge: edge, part: part, a: points[part], b: points[part + 1]))
            }
        }
        var tracks: [LayoutEdge: [Int: Float]] = [:]
        for rank in corridors.keys.sorted() {
            var list = corridors[required: rank]
                .sorted {
                    let ad = $0.b.y >= $0.a.y
                    let bd = $1.b.y >= $1.a.y
                    if ad != bd { return ad }
                    let ay = $0.a.y + $0.b.y
                    let by = $1.a.y + $1.b.y
                    if ay != by { return ad ? ay > by : ay < by }
                    return edgeIndices[required: $0.edge] < edgeIndices[required: $1.edge]
                }
            let low =
                (nodes.filter { $0.center.x == ranks[rank] }.map { $0.bounds.right }.max() ?? ranks[rank]) + clearance
            let high =
                (nodes.filter { $0.center.x == ranks[rank + 1] }.map { $0.bounds.left }.min() ?? ranks[rank + 1])
                - clearance
            func pairCrossings(_ a: Transition, _ b: Transition) -> Int {
                let x1 = low + (high - low) / 3
                let x2 = low + (high - low) * 2 / 3
                let p = DirectedGeometry.segments([a.a, Point(x: x1, y: a.a.y), Point(x: x1, y: a.b.y), a.b])
                let q = DirectedGeometry.segments([b.a, Point(x: x2, y: b.a.y), Point(x: x2, y: b.b.y), b.b])
                return p.reduce(0) { count, segment in
                    count + q.filter { DirectedGeometry.crossing(segment, $0) != nil }.count
                }
            }
            if list.count > 1 {
                for _ in 0..<8 {
                    var changed = false
                    for i in 0..<(list.count - 1)
                    where pairCrossings(list[i + 1], list[i]) < pairCrossings(list[i], list[i + 1]) {
                        list.swapAt(i, i + 1)
                        changed = true
                    }
                    if !changed { break }
                }
            }
            for (i, transition) in list.enumerated() {
                tracks[transition.edge, default: [:]][transition.part] =
                    low + (high - low) * Float(i + 1) / Float(list.count + 1)
            }
        }
        var result: [LayoutEdge: [Point]] = [:]
        for (edge, points) in chains {
            var path = [points[0]]
            for part in 0..<(points.count - 1) {
                let a = points[part]
                let b = points[part + 1]
                guard let x = tracks[required: edge][part] else {
                    preconditionFailure("Every transition of a hierarchy chain is assigned a track")
                }
                path += [Point(x: x, y: a.y), Point(x: x, y: b.y), b]
            }
            result[edge] = DirectedGeometry.compact(
                edge.source.center.x > edge.target.center.x ? path.reversed() : path
            )
        }
        return result
    }

    func pathCost(_ path: [Point], minimumRun: Float = 12) -> Float {
        var value = Float(max(0, path.count - 2)) * 24
        for segment in DirectedGeometry.segments(path) {
            value += segment.length
            var blocked = false
            occupied.forEach(near: segment, margin: spacing) { _, other in
                if DirectedGeometry.shared(segment, other)
                    || DirectedGeometry.nearShared(segment, other, spacing: spacing, minimumLength: minimumRun)
                {
                    blocked = true
                } else if DirectedGeometry.crossing(segment, other) != nil {
                    value += 350
                }
            }
            if blocked { return .infinity }
        }
        return value
    }
}
