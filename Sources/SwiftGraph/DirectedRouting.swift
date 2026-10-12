import Foundation

enum DirectedGeometry {
    static let epsilon = 0.0001
    struct Segment {
        var a: Point, b: Point
        var horizontal: Bool { abs(a.y - b.y) < epsilon }
        var length: Double { abs(a.x - b.x) + abs(a.y - b.y) }
    }
    struct Score {
        var missing = 0, overlaps = 0, crossings = 0, shared = 0, bends = 0
        var length = 0.0, area = 0.0
        func precedes(_ b: Score) -> Bool {
            let aValues = [Double(missing + overlaps), Double(shared), Double(crossings), Double(bends), length, area]
            let bValues = [Double(b.missing + b.overlaps), Double(b.shared), Double(b.crossings), Double(b.bends), b.length, b.area]
            for (a, b) in zip(aValues, bValues) where a != b { return a < b }
            return false
        }
    }
    static func segments(_ path: [Point]) -> [Segment] { zip(path, path.dropFirst()).map { Segment(a: $0, b: $1) } }
    static func shared(_ a: Segment, _ b: Segment) -> Bool {
        if a.horizontal != b.horizontal { return false }
        if a.horizontal {
            return abs(a.a.y - b.a.y) < epsilon && min(max(a.a.x, a.b.x), max(b.a.x, b.b.x)) - max(min(a.a.x, a.b.x), min(b.a.x, b.b.x)) > epsilon
        }
        return abs(a.a.x - b.a.x) < epsilon && min(max(a.a.y, a.b.y), max(b.a.y, b.b.y)) - max(min(a.a.y, a.b.y), min(b.a.y, b.b.y)) > epsilon
    }
    static func nearShared(_ a: Segment, _ b: Segment, spacing: Double, minimumLength: Double = 12) -> Bool {
        guard a.horizontal == b.horizontal else { return false }
        if a.horizontal {
            return abs(a.a.y - b.a.y) < spacing && min(max(a.a.x, a.b.x), max(b.a.x, b.b.x)) - max(min(a.a.x, a.b.x), min(b.a.x, b.b.x)) > minimumLength
        }
        return abs(a.a.x - b.a.x) < spacing && min(max(a.a.y, a.b.y), max(b.a.y, b.b.y)) - max(min(a.a.y, a.b.y), min(b.a.y, b.b.y)) > minimumLength
    }
    static func crossing(_ a: Segment, _ b: Segment) -> Point? {
        guard a.horizontal != b.horizontal else { return nil }
        let h = a.horizontal ? a : b, v = a.horizontal ? b : a
        let p = Point(x: v.a.x, y: h.a.y)
        return p.x > min(h.a.x, h.b.x) + epsilon && p.x < max(h.a.x, h.b.x) - epsilon
            && p.y > min(v.a.y, v.b.y) + epsilon && p.y < max(v.a.y, v.b.y) - epsilon ? p : nil
    }
    static func measure(nodes: [LayoutNode], edges: [LayoutEdge]) throws -> Score {
        var score = Score()
        let lines = edges.map { segments($0.path) }
        for i in nodes.indices { for j in nodes.indices where j > i && nodes[i].bounds.intersects(nodes[j].bounds) { score.overlaps += 1 } }
        for i in edges.indices {
            try Task.checkCancellation()
            if edges[i].path.count < 2 { score.missing += 1 }
            score.bends += max(0, edges[i].path.count - 2)
            score.length += lines[i].reduce(0) { $0 + $1.length }
            for j in edges.indices where j > i {
                var hits: Set<Point> = [], sharing = false
                for a in lines[i] { for b in lines[j] {
                    if let p = crossing(a, b) { hits.insert(p) }
                    sharing = sharing || shared(a, b)
                } }
                score.crossings += hits.count
                if sharing { score.shared += 1 }
            }
        }
        let rect = bounds(nodes: nodes, edges: edges); score.area = rect.width * rect.height
        return score
    }
    static func bounds(nodes: [LayoutNode], edges: [LayoutEdge]) -> Rect {
        let points = nodes.flatMap { [Point(x: $0.bounds.left, y: $0.bounds.top), Point(x: $0.bounds.right, y: $0.bounds.bottom)] } + edges.flatMap(\.path)
        guard let first = points.first else { return Rect() }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    static func compact(_ path: [Point]) -> [Point] {
        var result: [Point] = []
        for p in path {
            if result.last == p { continue }
            if result.count >= 2 {
                let a = result[result.count - 2], b = result.last!, u = b - a, v = p - b
                if abs(u.x * v.y - u.y * v.x) < epsilon && u.x * v.x + u.y * v.y >= 0 { result.removeLast() }
            }
            result.append(p)
        }
        return result
    }
    static func clear(_ a: Point, _ b: Point, bodies: [Rect]) -> Bool {
        if abs(a.x - b.x) > epsilon && abs(a.y - b.y) > epsilon { return false }
        return !bodies.contains { r in
            if abs(a.x - b.x) < epsilon {
                return a.x > r.left + epsilon && a.x < r.right - epsilon
                    && max(a.y, b.y) > r.top + epsilon && min(a.y, b.y) < r.bottom - epsilon
            }
            return a.y > r.top + epsilon && a.y < r.bottom - epsilon
                && max(a.x, b.x) > r.left + epsilon && min(a.x, b.x) < r.right - epsilon
        }
    }
}

/// Port assignment and corridor candidates share obstacle geometry for the whole component.
/// The exact-coordinate search is a repair path, not the common case for every edge.
final class DirectedRouter {
    let nodes: [LayoutNode], edges: [LayoutEdge], feedback: Set<LayoutEdge>
    let edgeIndices: [LayoutEdge: Int], configuration: DirectedLayoutConfiguration, pitch: Double
    var bodies: [Rect], obstacles: [Rect]
    var occupied: [DirectedGeometry.Segment] = []
    var ports: [LayoutEdge: (Point, Point, Point, Point)] = [:]
    let clearance: Double
    let trackClearance: Double
    private var coordinated = false

    init(nodes: [LayoutNode], edges: [LayoutEdge], feedback: Set<LayoutEdge>, edgeIndices: [LayoutEdge: Int], configuration: DirectedLayoutConfiguration, pitch: Double) {
        self.nodes = nodes; self.edges = edges; self.feedback = feedback; self.edgeIndices = edgeIndices
        self.configuration = configuration; self.pitch = pitch
        trackClearance = (configuration.edgeWidths.max() ?? 1) + 1
        clearance = max(configuration.clearance, ((configuration.edgeWidths.max() ?? 1) * 2.5 + 4) / 2 + 2)
        bodies = nodes.map(\.bounds)
        let padding = clearance
        obstacles = nodes.map { $0.bounds.inflated(by: padding) }
    }

    func route(coordinated: Bool = true) throws {
        self.coordinated = coordinated && configuration.mode == .fresh
        assignPorts()
        var channels: [LayoutEdge: [Point]]
        if self.coordinated {
            let priorX = Dictionary(uniqueKeysWithValues: nodes.map { ($0, $0.center.x) })
            let plan = DirectedChannelPlan(nodes: nodes, edges: edges, feedback: feedback, ports: ports,
                edgeIndices: edgeIndices, clearance: clearance, spacing: max(6, trackClearance + 2))
            channels = try plan.apply(minimumGap: configuration.layerSpacing)
            for edge in edges {
                var p = ports[edge]!
                p.0.x += edge.source.center.x - priorX[edge.source]!
                p.1.x += edge.target.center.x - priorX[edge.target]!
                ports[edge] = p
            }
            bodies = nodes.map(\.bounds)
            obstacles = bodies.map { $0.inflated(by: clearance) }
        } else { channels = hierarchyPaths() }
        let guides = edges.map(\.path)
        try routePass(reverse: false, channelPaths: channels)
        let missing = edges.filter { $0.path.isEmpty }.count
        guard missing > 0 else { return }
        let first = edges.map(\.path)
        for (edge, guide) in zip(edges, guides) { edge.path = guide }
        occupied.removeAll(keepingCapacity: true)
        try routePass(reverse: true, channelPaths: channels)
        if edges.filter({ $0.path.isEmpty }).count > missing {
            for (edge, path) in zip(edges, first) { edge.path = path }
        }
    }

    /// Refine the selected drawing with every other route present. The initial pass
    /// sees only earlier edges, so a valid hierarchy guide can retain avoidable jogs.
    /// Each accepted shortcut is obstacle-safe and cannot add crossings or length.
    func refine() throws {
        let ordered = edges.sorted {
            let a = $0.path.count, b = $1.path.count
            return a == b ? edgeIndices[$0]! < edgeIndices[$1]! : a > b
        }
        for edge in ordered where edge.path.count > 4 {
            try Task.checkCancellation()
            occupied = edges.filter { $0 !== edge }.flatMap { DirectedGeometry.segments($0.path) }
            let others = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
            func quality(_ path: [Point]) -> (crossings: Int, length: Double)? {
                var crossings = 0, length = 0.0
                for segment in DirectedGeometry.segments(path) {
                    if !DirectedGeometry.clear(segment.a, segment.b, bodies: bodies)
                        || !DirectedGeometry.clear(segment.a, segment.b, bodies: others) { return nil }
                    length += segment.length
                    for other in occupied {
                        if DirectedGeometry.shared(segment, other) || DirectedGeometry.nearShared(segment, other, spacing: trackClearance) { return nil }
                        if DirectedGeometry.crossing(segment, other) != nil { crossings += 1 }
                    }
                }
                return (crossings, length)
            }
            var path = edge.path
            guard var score = quality(path) else { continue }
            // Preserve the first and last segments, and therefore the port direction
            // and arrowhead approach. Bound work even for unusually winding inputs.
            for _ in 0..<2 {
                var changed = false
                let count = path.count
                guard count > 4 else { break }
                outer: for span in stride(from: min(count - 3, 10), through: 2, by: -1) {
                    for i in 1..<(count - 1 - span) {
                        let j = i + span, a = path[i], b = path[j]
                        for elbow in [Point(x: a.x, y: b.y), Point(x: b.x, y: a.y)] {
                            let candidate = DirectedGeometry.compact(Array(path[...i]) + [elbow] + Array(path[j...]))
                            guard candidate.count < path.count, let next = quality(candidate),
                                  next.crossings <= score.crossings, next.length <= score.length + 0.0001 else { continue }
                            path = candidate; score = next; changed = true; break outer
                        }
                    }
                }
                if !changed { break }
            }
            edge.path = path
        }
    }

    /// Bounded rip-up and reroute of the worst remaining paths. Unlike the initial
    /// pass, each trial sees every other route. Endpoint approaches stay fixed and
    /// acceptance is Pareto-monotone in crossings, bends and Manhattan length.
    func improveWorstRoutes() throws {
        coordinated = true
        for _ in 0..<2 {
            var changed = false
            let worst = edges.filter { $0.path.count > 3 }.sorted {
                if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
                return edgeIndices[$0]! < edgeIndices[$1]!
            }.prefix(16)
            for edge in worst {
                try Task.checkCancellation()
                let original = edge.path
                let others = edges.filter { $0 !== edge }.map { DirectedGeometry.segments($0.path) }
                occupied = others.flatMap { $0 }
                let nonEndpoints = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
                func quality(_ path: [Point]) -> (crossings: Int, bends: Int, length: Double)? {
                    let segments = DirectedGeometry.segments(path)
                    guard path.count >= 2, segments.allSatisfy({ DirectedGeometry.clear($0.a, $0.b, bodies: bodies)
                        && DirectedGeometry.clear($0.a, $0.b, bodies: nonEndpoints) }) else { return nil }
                    var crossings = 0
                    for route in others {
                        var hits: Set<Point> = []
                        for a in segments { for b in route {
                            if DirectedGeometry.shared(a, b) || DirectedGeometry.nearShared(a, b, spacing: trackClearance) { return nil }
                            if let p = DirectedGeometry.crossing(a, b) { hits.insert(p) }
                        } }
                        crossings += hits.count
                    }
                    return (crossings, max(0, path.count - 2), segments.reduce(0) { $0 + $1.length })
                }
                guard var score = quality(original) else { continue }
                let start = original[0], end = original.last!
                let u = original[1] - start, v = original[original.count - 2] - end
                let escape = start + u / u.length * min(clearance, u.length)
                let entry = end + v / v.length * min(clearance, v.length)
                var best = original
                func consider(_ middle: [Point]) {
                    guard zip(middle, middle.dropFirst()).allSatisfy({ DirectedGeometry.clear($0, $1, bodies: obstacles) }) else { return }
                    let candidate = DirectedGeometry.compact([start] + middle + [end])
                    guard let next = quality(candidate), next.crossings <= score.crossings, next.bends <= score.bends,
                          next.length <= score.length + DirectedGeometry.epsilon,
                          next.crossings < score.crossings || next.bends < score.bends || next.length < score.length - DirectedGeometry.epsilon else { return }
                    best = candidate; score = next
                }
                let xs = Array(Set(original.map(\.x) + [(escape.x + entry.x) / 2])).sorted()
                let ys = Array(Set(original.map(\.y) + [(escape.y + entry.y) / 2] + exteriorLanes(from: escape, to: entry))).sorted()
                for x in xs { consider([escape, Point(x: x, y: escape.y), Point(x: x, y: entry.y), entry]) }
                for y in ys { consider([escape, Point(x: escape.x, y: y), Point(x: entry.x, y: y), entry]) }
                if best == original, let repaired = try search(from: escape, to: entry, ordinal: edgeIndices[edge]!, visitLimit: 4096) {
                    consider(repaired)
                }
                if best != original { edge.path = best; changed = true }
            }
            if !changed { break }
        }
    }

    private func routePass(reverse: Bool, channelPaths: [LayoutEdge: [Point]]) throws {
        var retained: Set<LayoutEdge> = []
        if configuration.mode != .fresh {
            for edge in edges {
                guard let old = configuration.previousPaths[edgeIndices[edge]!], old.count >= 2 else { continue }
                let (start, end, sd, td) = ports[edge]!
                guard (old[0] - start).length < 0.001, (old.last! - end).length < 0.001 else { continue }
                var path = old
                path[0] = start; path[path.count - 1] = end
                if sd.x != 0 { path[1].y = start.y } else { path[1].x = start.x }
                if td.x != 0 { path[path.count - 2].y = end.y } else { path[path.count - 2].x = end.x }
                let others = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
                if zip(path, path.dropFirst()).allSatisfy({ DirectedGeometry.clear($0, $1, bodies: bodies) && DirectedGeometry.clear($0, $1, bodies: others) }) && pathCost(path).isFinite {
                    edge.path = path; retained.insert(edge); occupied += DirectedGeometry.segments(path)
                }
            }
        }
        var order = edges.sorted {
            let a = abs($0.source.center.x - $0.target.center.x), b = abs($1.source.center.x - $1.target.center.x)
            return a == b ? edgeIndices[$0]! < edgeIndices[$1]! : a < b
        }
        if reverse { order.reverse() }
        let trackOrder = edges.sorted {
            let a = ports[$0]!, b = ports[$1]!
            let ad = a.1.y >= a.0.y, bd = b.1.y >= b.0.y
            if ad != bd { return ad }
            let ay = a.0.y + a.1.y, by = b.0.y + b.1.y
            if ay == by { return edgeIndices[$0]! < edgeIndices[$1]! }
            return ad ? ay > by : ay < by
        }
        let trackIndex = Dictionary(uniqueKeysWithValues: trackOrder.enumerated().map { ($0.element, $0.offset) })
        for edge in order {
            try Task.checkCancellation()
            if retained.contains(edge) { continue }
            let (start, end, sd, td) = ports[edge]!
            let escape = start + sd * clearance, entry = end + td * clearance
            // Endpoints are never exempted from body validation (including self-loops).
            guard DirectedGeometry.clear(start, escape, bodies: bodies), DirectedGeometry.clear(entry, end, bodies: bodies) else { edge.path = []; continue }
            let ordinal = edgeIndices[edge]!
            let fraction = (Double(trackIndex[edge]!) + 1) / Double(edges.count + 1)
            let otherObstacles = nodes.filter { $0 !== edge.source && $0 !== edge.target }.map { $0.bounds.inflated(by: clearance) }
            var candidates: [[Point]] = []
            func add(_ middle: [Point]) {
                let path = DirectedGeometry.compact([start] + middle + [end])
                if path.count >= 2 && zip(path, path.dropFirst()).allSatisfy({ DirectedGeometry.clear($0, $1, bodies: bodies) })
                    && zip(path, path.dropFirst()).allSatisfy({ DirectedGeometry.clear($0, $1, bodies: otherObstacles) })
                    && zip(middle, middle.dropFirst()).allSatisfy({ DirectedGeometry.clear($0, $1, bodies: obstacles) }) { candidates.append(path) }
            }
            if let guided = channelPaths[edge] { add(guided) }
            let guided = candidates.first.flatMap { pathCost($0).isFinite ? $0 : nil }
            let xs = [escape.x + (entry.x - escape.x) * (0.2 + fraction * 0.6),
                      escape.x + (entry.x - escape.x) * (0.8 - fraction * 0.6)]
            for x in xs { add([escape, Point(x: x, y: escape.y), Point(x: x, y: entry.y), entry]) }
            let ys = [escape.y + (entry.y - escape.y) * (0.2 + fraction * 0.6),
                      escape.y + (entry.y - escape.y) * (0.8 - fraction * 0.6)]
            for y in ys { add([escape, Point(x: escape.x, y: y), Point(x: entry.x, y: y), entry]) }
            // Feedback and loops get independent exterior lanes; no diagonal loop shortcut.
            if sd.y != 0 || td.y != 0 || candidates.isEmpty {
                let lanes: [Double]
                if coordinated { lanes = exteriorLanes(from: escape, to: entry) }
                else {
                    lanes = [(obstacles.map(\.top).min() ?? 0) - clearance - Double(ordinal) * pitch,
                             (obstacles.map(\.bottom).max() ?? 0) + clearance + Double(ordinal) * pitch]
                }
                for y in lanes { add([escape, Point(x: escape.x, y: y), Point(x: entry.x, y: y), entry]) }
            }
            if !coordinated, let guided { candidates = [guided] }
            var best: [Point]?, bestCost = Double.infinity
            for candidate in candidates {
                let cost = pathCost(candidate)
                if cost < bestCost { best = candidate; bestCost = cost }
            }
            if best == nil {
                var repaired = try search(from: escape, to: entry, ordinal: ordinal)
                if repaired == nil { repaired = try search(from: escape, to: entry, ordinal: ordinal, occupiedCoordinates: true) }
                if let repaired { add(repaired); best = candidates.last.flatMap { pathCost($0).isFinite ? $0 : nil } }
            }
            edge.path = best ?? []
            occupied += DirectedGeometry.segments(edge.path)
        }
    }

    /// Only obstacles and occupied runs within this edge's horizontal span consume
    /// outer lanes. Unrelated edges elsewhere cannot push a feedback route outward.
    private func exteriorLanes(from start: Point, to end: Point) -> [Double] {
        let left = min(start.x, end.x), right = max(start.x, end.x)
        let local = obstacles.filter { $0.right >= left && $0.left <= right }
        let top = min(start.y, end.y, local.map(\.top).min() ?? start.y) - clearance
        let bottom = max(start.y, end.y, local.map(\.bottom).max() ?? start.y) + clearance
        return [(top, -1.0), (bottom, 1.0)].map { initial, direction in
            var y = initial
            for _ in 0...occupied.count {
                let line = DirectedGeometry.Segment(a: Point(x: left, y: y), b: Point(x: right, y: y))
                if !occupied.contains(where: { DirectedGeometry.nearShared(line, $0, spacing: trackClearance, minimumLength: 0) }) { break }
                y += direction * max(6, trackClearance + 2)
            }
            return y
        }
    }

    /// All forward edges crossing one rank gap use the same corridor. Sorting tracks
    /// against adjacent virtual nodes preserves the hierarchy's crossing reduction.
    private func hierarchyPaths() -> [LayoutEdge: [Point]] {
        struct Transition { var edge: LayoutEdge; var part: Int; var a: Point; var b: Point }
        let ranks = Array(Set(nodes.map { $0.center.x })).sorted()
        guard ranks.count > 1 else { return [:] }
        var corridors: [Int: [Transition]] = [:]
        var chains: [LayoutEdge: [Point]] = [:]
        for edge in edges where !feedback.contains(edge) && edge.source.center.x < edge.target.center.x {
            guard edge.path.count >= 2,
                  let first = ranks.firstIndex(of: edge.source.center.x),
                  let last = ranks.firstIndex(of: edge.target.center.x),
                  edge.path.count == last - first + 1 else { continue }
            let (start, end, sd, td) = ports[edge]!
            guard sd.x > 0 && td.x < 0 else { continue }
            let points = [start + sd * clearance] + edge.path.dropFirst().dropLast() + [end + td * clearance]
            chains[edge] = Array(points)
            for part in 0..<(points.count - 1) {
                corridors[first + part, default: []].append(Transition(edge: edge, part: part, a: points[part], b: points[part + 1]))
            }
        }
        var tracks: [LayoutEdge: [Int: Double]] = [:]
        for rank in corridors.keys.sorted() {
            var list = corridors[rank]!.sorted {
                let ad = $0.b.y >= $0.a.y, bd = $1.b.y >= $1.a.y
                if ad != bd { return ad }
                let ay = $0.a.y + $0.b.y, by = $1.a.y + $1.b.y
                if ay != by { return ad ? ay > by : ay < by }
                return edgeIndices[$0.edge]! < edgeIndices[$1.edge]!
            }
            let low = (nodes.filter { $0.center.x == ranks[rank] }.map { $0.bounds.right }.max() ?? ranks[rank]) + clearance
            let high = (nodes.filter { $0.center.x == ranks[rank + 1] }.map { $0.bounds.left }.min() ?? ranks[rank + 1]) - clearance
            func pairCrossings(_ a: Transition, _ b: Transition) -> Int {
                let x1 = low + (high - low) / 3, x2 = low + (high - low) * 2 / 3
                let p = DirectedGeometry.segments([a.a, Point(x: x1, y: a.a.y), Point(x: x1, y: a.b.y), a.b])
                let q = DirectedGeometry.segments([b.a, Point(x: x2, y: b.a.y), Point(x: x2, y: b.b.y), b.b])
                return p.reduce(0) { count, segment in count + q.filter { DirectedGeometry.crossing(segment, $0) != nil }.count }
            }
            if list.count > 1 {
                for _ in 0..<8 {
                    var changed = false
                    for i in 0..<(list.count - 1) {
                        if pairCrossings(list[i + 1], list[i]) < pairCrossings(list[i], list[i + 1]) {
                            list.swapAt(i, i + 1); changed = true
                        }
                    }
                    if !changed { break }
                }
            }
            for (i, transition) in list.enumerated() {
                tracks[transition.edge, default: [:]][transition.part] = low + (high - low) * Double(i + 1) / Double(list.count + 1)
            }
        }
        var result: [LayoutEdge: [Point]] = [:]
        for (edge, points) in chains {
            var path = [points[0]]
            for part in 0..<(points.count - 1) {
                let a = points[part], b = points[part + 1], x = tracks[edge]![part]!
                path += [Point(x: x, y: a.y), Point(x: x, y: b.y), b]
            }
            result[edge] = DirectedGeometry.compact(path)
        }
        return result
    }

    private func pathCost(_ path: [Point], minimumRun: Double = 12) -> Double {
        var value = Double(max(0, path.count - 2)) * 24
        for segment in DirectedGeometry.segments(path) {
            value += segment.length
            for other in occupied {
                if DirectedGeometry.shared(segment, other) || DirectedGeometry.nearShared(segment, other, spacing: trackClearance, minimumLength: minimumRun) { return .infinity }
                if DirectedGeometry.crossing(segment, other) != nil { value += 350 }
            }
        }
        return value
    }

    private struct End { var edge: LayoutEdge; var source: Bool; var neighbor: Point }
    private struct SideKey: Hashable { var node: LayoutNode; var side: PortConstraint }
    private func assignPorts() {
        var ends: [SideKey: [End]] = [:]
        var assigned: [LayoutEdge: [Point]] = [:]
        for edge in edges {
            let a = edge.source.bounds, b = edge.target.bounds
            let sides: (PortConstraint, PortConstraint)
            if edge.source === edge.target { sides = (.top, .top) }
            else if feedback.contains(edge) {
                // Reporting links use the facing horizontal sides when vertically separated.
                // Forcing both ends onto the top sends lower targets around unrelated ranks.
                if a.bottom + clearance * 2 < b.top { sides = (.bottom, .top) }
                else if b.bottom + clearance * 2 < a.top { sides = (.top, .bottom) }
                else { sides = (.top, .top) }
            }
            else if edge.sourcePort != .none && edge.targetPort != .none { sides = (edge.sourcePort, edge.targetPort) }
            else if a.center.x < b.center.x { sides = (.right, .left) }
            else { sides = (.left, .right) }
            ends[SideKey(node: edge.source, side: sides.0), default: []].append(End(edge: edge, source: true, neighbor: edge.path.count > 2 ? edge.path[1] : b.center))
            ends[SideKey(node: edge.target, side: sides.1), default: []].append(End(edge: edge, source: false, neighbor: edge.path.count > 2 ? edge.path[edge.path.count - 2] : a.center))
            assigned[edge] = [.zero, .zero, .zero, .zero]
        }
        for (key, unsorted) in ends {
            let vertical = key.side == .left || key.side == .right
            let sorted = unsorted.sorted {
                let a = vertical ? $0.neighbor.y : $0.neighbor.x, b = vertical ? $1.neighbor.y : $1.neighbor.x
                if a != b { return a < b }
                let ai = edgeIndices[$0.edge]!, bi = edgeIndices[$1.edge]!
                return ai == bi ? $0.source && !$1.source : ai < bi
            }
            let r = key.node.bounds, extent = vertical ? r.height : r.width
            let priorPorts = sorted.compactMap { endpoint -> Point? in
                guard configuration.mode != .fresh, let path = configuration.previousPaths[edgeIndices[endpoint.edge]!], path.count >= 2 else { return nil }
                let point = endpoint.source ? path[0] : path.last!
                let onSide: Bool
                switch key.side {
                case .left: onSide = abs(point.x - r.left) < 0.001 && point.y >= r.top + 6 && point.y <= r.bottom - 6
                case .right: onSide = abs(point.x - r.right) < 0.001 && point.y >= r.top + 6 && point.y <= r.bottom - 6
                case .top: onSide = abs(point.y - r.top) < 0.001 && point.x >= r.left + 6 && point.x <= r.right - 6
                case .bottom: onSide = abs(point.y - r.bottom) < 0.001 && point.x >= r.left + 6 && point.x <= r.right - 6
                case .none: onSide = false
                }
                return onSide ? point : nil
            }
            let spacing = min(pitch, max(0, extent - 24) / Double(max(1, sorted.count - 1)))
            for (i, end) in sorted.enumerated() {
                let offset = (Double(i) - Double(sorted.count - 1) / 2) * spacing
                let p: Point, d: Point
                switch key.side {
                case .left: p = Point(x: r.left, y: r.center.y + offset); d = Point(x: -1, y: 0)
                case .right: p = Point(x: r.right, y: r.center.y + offset); d = Point(x: 1, y: 0)
                case .top: p = Point(x: r.center.x + offset, y: r.top); d = Point(x: 0, y: -1)
                case .bottom: p = Point(x: r.center.x + offset, y: r.bottom); d = Point(x: 0, y: 1)
                case .none: continue
                }
                let kept = priorPorts.count == sorted.count ? priorPorts[i] : p
                let port = vertical ? Point(x: p.x, y: kept.y) : Point(x: kept.x, y: p.y)
                assigned[end.edge]![end.source ? 0 : 1] = port
                assigned[end.edge]![end.source ? 2 : 3] = d
            }
        }
        for (edge, p) in assigned { ports[edge] = (p[0], p[1], p[2], p[3]) }
    }

    /// Rasterize exact-coordinate visibility links once per repair search. Obstacle and
    /// occupied-track costs are then O(1) per A* step, rather than scanning every edge.
    private func prepareGrid(xs: [Double], ys: [Double]) throws -> (horizontal: [Double], vertical: [Double]) {
        let width = xs.count, count = width * ys.count
        var horizontal = Array(repeating: 0.0, count: count), vertical = horizontal
        func lower(_ values: [Double], _ value: Double) -> Int {
            var low = 0, high = values.count
            while low < high { let mid = (low + high) / 2; if values[mid] < value { low = mid + 1 } else { high = mid } }
            return low
        }
        func points(_ values: [Double], _ low: Double, _ high: Double) -> Range<Int> {
            let first = lower(values, low + DirectedGeometry.epsilon)
            return first..<max(first, lower(values, high - DirectedGeometry.epsilon))
        }
        func links(_ values: [Double], _ low: Double, _ high: Double) -> Range<Int> {
            let first = max(0, lower(values, low + DirectedGeometry.epsilon) - 1)
            return first..<max(first, min(values.count - 1, lower(values, high - DirectedGeometry.epsilon)))
        }
        for rect in obstacles {
            try Task.checkCancellation()
            for y in points(ys, rect.top, rect.bottom) { for x in links(xs, rect.left, rect.right) { horizontal[y * width + x] = .infinity } }
            for x in points(xs, rect.left, rect.right) { for y in links(ys, rect.top, rect.bottom) { vertical[y * width + x] = .infinity } }
        }
        for (i, segment) in occupied.enumerated() {
            if i % 128 == 0 { try Task.checkCancellation() }
            if segment.horizontal {
                for y in points(ys, segment.a.y - trackClearance, segment.a.y + trackClearance) {
                    for x in links(xs, min(segment.a.x, segment.b.x), max(segment.a.x, segment.b.x)) { horizontal[y * width + x] = .infinity }
                }
                let row = lower(ys, segment.a.y)
                for x in points(xs, min(segment.a.x, segment.b.x), max(segment.a.x, segment.b.x)) {
                    if row > 0 { vertical[(row - 1) * width + x] += 350 }
                    if row < ys.count - 1 && ys[row] == segment.a.y { vertical[row * width + x] += 350 }
                }
            } else {
                for x in points(xs, segment.a.x - trackClearance, segment.a.x + trackClearance) {
                    for y in links(ys, min(segment.a.y, segment.b.y), max(segment.a.y, segment.b.y)) { vertical[y * width + x] = .infinity }
                }
                let column = lower(xs, segment.a.x)
                for y in points(ys, min(segment.a.y, segment.b.y), max(segment.a.y, segment.b.y)) {
                    if column > 0 { horizontal[y * width + column - 1] += 350 }
                    if column < width - 1 && xs[column] == segment.a.x { horizontal[y * width + column] += 350 }
                }
            }
        }
        return (horizontal, vertical)
    }

    private func search(from start: Point, to end: Point, ordinal: Int, occupiedCoordinates: Bool = false, visitLimit: Int? = nil) throws -> [Point]? {
        // A small edge-specific offset provides alternate tracks without sharing obstacle outlines.
        let offset = coordinated ? 1 : 1 + Double(ordinal + 1) * 0.1875
        let extraX = occupiedCoordinates ? occupied.filter { !$0.horizontal }.flatMap { [$0.a.x - trackClearance, $0.a.x + trackClearance] } : []
        let extraY = occupiedCoordinates ? occupied.filter(\.horizontal).flatMap { [$0.a.y - trackClearance, $0.a.y + trackClearance] } : []
        let xs = Array(Set(obstacles.flatMap { [$0.left - offset, $0.right + offset] } + [start.x, end.x] + extraX)).sorted()
        let ys = Array(Set(obstacles.flatMap { [$0.top - offset, $0.bottom + offset] } + [start.y, end.y] + extraY)).sorted()
        let width = xs.count, height = ys.count
        if visitLimit != nil && width * height > 65_536 { return nil }
        let first = ys.firstIndex(of: start.y)! * width + xs.firstIndex(of: start.x)!
        let last = ys.firstIndex(of: end.y)! * width + xs.firstIndex(of: end.x)!
        func point(_ cell: Int) -> Point { Point(x: xs[cell % width], y: ys[cell / width]) }
        func heuristic(_ cell: Int) -> Double { let p = point(cell); return abs(p.x - end.x) + abs(p.y - end.y) }
        var costs = [Double](repeating: .infinity, count: width * height * 3)
        var previous = [Int](repeating: -1, count: costs.count)
        var closed = [Bool](repeating: false, count: costs.count)
        var queue = DirectedMinHeap()
        let grid = try prepareGrid(xs: xs, ys: ys)
        let initial = first * 3
        costs[initial] = 0; queue.push(initial, priority: heuristic(first))
        var visited = 0
        while let current = queue.pop() {
            visited += 1
            if let visitLimit, visited > visitLimit { return nil }
            if visited % 128 == 0 { try Task.checkCancellation() }
            if closed[current] { continue }; closed[current] = true
            let cell = current / 3, direction = current % 3
            if cell == last {
                var at = current, path: [Point] = []
                while at != -1 { path.append(point(at / 3)); at = previous[at] }
                return DirectedGeometry.compact(path.reversed())
            }
            let x = cell % width, y = cell / width
            for (dx, dy, nextDirection) in [(1, 0, 1), (-1, 0, 1), (0, 1, 2), (0, -1, 2)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let nextCell = ny * width + nx, next = nextCell * 3 + nextDirection
                let key = min(cell, nextCell) * 2 + (dy == 0 ? 0 : 1)
                let a = point(cell), b = point(nextCell)
                let congestion = dy == 0 ? grid.horizontal[key / 2] : grid.vertical[key / 2]
                let travel = abs(a.x - b.x) + abs(a.y - b.y) + congestion
                let cost = costs[current] + travel + (direction != 0 && direction != nextDirection ? 24 : 0)
                if cost < costs[next] { costs[next] = cost; previous[next] = current; queue.push(next, priority: cost + heuristic(nextCell)) }
            }
        }
        return nil
    }
}

private struct DirectedMinHeap {
    private var values: [(state: Int, priority: Double)] = []
    mutating func push(_ state: Int, priority: Double) {
        values.append((state, priority)); var i = values.count - 1
        while i > 0 { let parent = (i - 1) / 2; guard less(i, parent) else { break }; values.swapAt(i, parent); i = parent }
    }
    mutating func pop() -> Int? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast().state }
        let result = values[0].state; values[0] = values.removeLast(); var i = 0
        while i * 2 + 1 < values.count {
            var child = i * 2 + 1
            if child + 1 < values.count && less(child + 1, child) { child += 1 }
            guard less(child, i) else { break }; values.swapAt(child, i); i = child
        }
        return result
    }
    private func less(_ a: Int, _ b: Int) -> Bool {
        values[a].priority == values[b].priority ? values[a].state < values[b].state : values[a].priority < values[b].priority
    }
}
