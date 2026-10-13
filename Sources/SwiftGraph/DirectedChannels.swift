import Foundation

/// A channel segment is a vertical run between two ordered rank boundaries.
/// Its identity is independent of coordinates; disjoint runs may reuse a slot.
struct DirectedChannelSegment {
    var id: Int
    var source: Double
    var target: Double
    var low: Double { min(source, target) }
    var high: Double { max(source, target) }
}

struct DirectedChannelAllocation {
    var slots: [Int: Int]
    var count: Int

    /// Clearance is a hard separation constraint. Crossing preferences are soft: insert the
    /// strongest preferences first and reverse any that close a cycle. Pairs without a
    /// preference only need distinct slots, so they stay unoriented until the weighted order
    /// is known and are then oriented to add the least depth.
    static func solve(_ input: [DirectedChannelSegment], clearance: Double) throws -> Self {
        let segments = input.filter { abs($0.source - $0.target) > DirectedGeometry.epsilon }.sorted { $0.id < $1.id }
        struct Preference { var from: Int; var to: Int; var weight: Int }
        var preferences: [Preference] = [], neutral: [Preference] = []
        func cost(_ a: DirectedChannelSegment, _ b: DirectedChannelSegment) -> Int {
            // A lies left of B. Only A's exit and B's entrance can cross the other run.
            let crossings = (a.target > b.low && a.target < b.high ? 1 : 0)
                + (b.source > a.low && b.source < a.high ? 1 : 0)
            // Near coincident opposing arms need the opposite order to avoid sharing.
            let conflict = abs(a.target - b.source) < clearance ? 1 : 0
            return crossings * 16 + conflict * 32
        }
        func consider(_ i: Int, _ j: Int) {
            let a = segments[i], b = segments[j]
            let ab = cost(a, b), ba = cost(b, a)
            let aDown = a.target >= a.source, bDown = b.target >= b.source
            let aFirst = ab == ba
                ? (aDown != bDown ? aDown : (a.source + a.target == b.source + b.target
                    ? a.id < b.id : (aDown ? a.source + a.target > b.source + b.target : a.source + a.target < b.source + b.target)))
                : ab < ba
            let preference = Preference(from: aFirst ? i : j, to: aFirst ? j : i, weight: abs(ab - ba))
            if preference.weight == 0 { neutral.append(preference) } else { preferences.append(preference) }
        }
        // Sweep by lower bound: only segments within clearance of each other form a pair.
        var active: [Int] = []
        for i in segments.indices.sorted(by: { segments[$0].low == segments[$1].low ? $0 < $1 : segments[$0].low < segments[$1].low }) {
            try Task.checkCancellation()
            active.removeAll { segments[$0].high + clearance <= segments[i].low }
            for j in active { consider(min(i, j), max(i, j)) }
            active.append(i)
        }
        let order: (Preference, Preference) -> Bool = {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            if $0.from != $1.from { return $0.from < $1.from }
            return $0.to < $1.to
        }
        preferences.sort(by: order); neutral.sort(by: order)
        var outgoing = Array(repeating: [Int](), count: segments.count)
        var incoming = Array(repeating: [Int](), count: segments.count)
        func reaches(_ source: Int, _ target: Int) -> Bool {
            var stack = [source], seen = Set<Int>()
            while let node = stack.popLast() {
                if node == target { return true }
                if seen.insert(node).inserted { stack.append(contentsOf: outgoing[node]) }
            }
            return false
        }
        for (i, preference) in preferences.enumerated() {
            if i % 128 == 0 { try Task.checkCancellation() }
            var a = preference.from, b = preference.to
            if reaches(b, a) { swap(&a, &b) }
            outgoing[a].append(b); incoming[b].append(a)
        }
        // Longest paths from the sources (the slot) and to the sinks bound the depth.
        var level = Array(repeating: 0, count: segments.count), tail = level
        var pending = incoming.map(\.count), ready = segments.indices.filter { pending[$0] == 0 }, next = 0
        while next < ready.count {
            let node = ready[next]; next += 1
            for target in outgoing[node] {
                level[target] = max(level[target], level[node] + 1)
                pending[target] -= 1
                if pending[target] == 0 { ready.append(target) }
            }
        }
        for node in ready.reversed() { for target in outgoing[node] { tail[node] = max(tail[node], tail[target] + 1) } }
        func connect(_ a: Int, _ b: Int) {
            outgoing[a].append(b); incoming[b].append(a)
            var stack = [(b, level[a] + 1)]
            while let (node, value) = stack.popLast() {
                guard level[node] < value else { continue }
                level[node] = value; stack.append(contentsOf: outgoing[node].map { ($0, value + 1) })
            }
            stack = [(a, tail[b] + 1)]
            while let (node, value) = stack.popLast() {
                guard tail[node] < value else { continue }
                tail[node] = value; stack.append(contentsOf: incoming[node].map { ($0, value + 1) })
            }
        }
        for (i, pair) in neutral.enumerated() {
            if i % 128 == 0 { try Task.checkCancellation() }
            let a = pair.from, b = pair.to
            if reaches(a, b) || reaches(b, a) { continue }
            // Depth after each orientation is the longest chain through the new link.
            if level[b] + 1 + tail[a] < level[a] + 1 + tail[b] { connect(b, a) } else { connect(a, b) }
        }
        return Self(slots: Dictionary(uniqueKeysWithValues: segments.indices.map { (segments[$0].id, level[$0]) }),
                    count: level.max().map { $0 + 1 } ?? 0)
    }
}

/// Keeps rank membership, port escapes, and virtual-chain identity through coordinate
/// assignment. No merged paths: slot reuse is only allowed for disjoint intervals.
final class DirectedChannelPlan {
    struct Chain {
        var edge: LayoutEdge
        var firstRank: Int
        var points: [Point]
    }
    let nodes: [LayoutNode]
    let ranks: [Double]
    let nodeRanks: [LayoutNode: Int]
    let clearance: Double, spacing: Double
    var chains: [Chain]

    init(nodes: [LayoutNode], edges: [LayoutEdge], feedback: Set<LayoutEdge>,
         ports: [LayoutEdge: (Point, Point, Point, Point)], edgeIndices: [LayoutEdge: Int],
         clearance: Double, spacing: Double) {
        self.nodes = nodes; self.clearance = clearance; self.spacing = spacing
        ranks = Array(Set(nodes.map { $0.center.x })).sorted()
        let byCoordinate = Dictionary(uniqueKeysWithValues: ranks.enumerated().map { ($0.element, $0.offset) })
        nodeRanks = Dictionary(uniqueKeysWithValues: nodes.map { ($0, byCoordinate[$0.center.x]!) })
        chains = []
        for edge in edges.sorted(by: { edgeIndices[$0]! < edgeIndices[$1]! }) where !feedback.contains(edge) {
            let from = nodeRanks[edge.source]!, to = nodeRanks[edge.target]!
            // A backward edge is planned as the forward chain between the same ranks, then reversed.
            let backward = from > to, first = min(from, to), last = max(from, to)
            guard first < last, edge.path.count == last - first + 1, let (start, end, sd, td) = ports[edge],
                  backward ? (sd.x < 0 && td.x > 0) : (sd.x > 0 && td.x < 0) else { continue }
            let points = [start + sd * clearance] + edge.path.dropFirst().dropLast() + [end + td * clearance]
            chains.append(Chain(edge: edge, firstRank: first, points: backward ? Array(points.reversed()) : points))
        }
    }

    /// Align maximal consecutive virtual runs inside the same free, ordered channel.
    /// Real nodes and other chains bound each interval, so alignment cannot exchange
    /// edge order at a rank or sweep a long edge through a node.
    func straighten() throws {
        let order = chains.indices.sorted {
            chains[$0].points.count == chains[$1].points.count ? $0 < $1 : chains[$0].points.count > chains[$1].points.count
        }
        for index in order {
            try Task.checkCancellation()
            let chain = chains[index]
            guard chain.points.count > 2 else { continue }
            var intervals: [(Double, Double)] = []
            for part in 1..<(chain.points.count - 1) {
                let rank = chain.firstRank + part, y = chain.points[part].y
                var low = -Double.infinity, high = Double.infinity
                for node in nodes where nodeRanks[node] == rank {
                    let r = node.bounds.inflated(by: clearance)
                    if r.bottom <= y { low = max(low, r.bottom) }
                    else if r.top >= y { high = min(high, r.top) }
                    else { low = y; high = y }
                }
                for other in chains.indices where other != index {
                    let p = rank - chains[other].firstRank
                    guard p >= 0 && p < chains[other].points.count else { continue }
                    let neighbor = chains[other].points[p].y
                    if neighbor < y || (neighbor == y && other < index) { low = max(low, neighbor + spacing) }
                    else { high = min(high, neighbor - spacing) }
                }
                intervals.append(low <= high ? (low, high) : (y, y))
            }
            var begin = 0
            while begin < intervals.count {
                var end = begin, low = intervals[begin].0, high = intervals[begin].1
                while end + 1 < intervals.count {
                    let l = max(low, intervals[end + 1].0), h = min(high, intervals[end + 1].1)
                    if l > h { break }
                    end += 1; low = l; high = h
                }
                // Endpoint-aligned runs save two bends when the shared interval allows it.
                let candidates = [chain.points[0].y, chain.points.last!.y]
                    + Array(chain.points[(begin + 1)...(end + 1)]).map(\.y)
                let median = candidates.sorted()[candidates.count / 2]
                let y = candidates.prefix(2).first(where: { $0 >= low && $0 <= high }) ?? min(high, max(low, median))
                for part in begin...end { chains[index].points[part + 1].y = y }
                begin = end + 1
            }
        }
    }

    /// Slot demand sets the distance between rank columns, with the configured gap
    /// as a lower bound. Coordinates are then materialized from the same allocation.
    func apply(minimumGap: Double) throws -> [LayoutEdge: [Point]] {
        guard ranks.count > 1 else { return [:] }
        try straighten()
        struct Transition { var chain: Int; var part: Int; var segment: DirectedChannelSegment }
        var corridors = Array(repeating: [Transition](), count: ranks.count - 1)
        var identity = 0
        for i in chains.indices {
            for part in 0..<(chains[i].points.count - 1) {
                let segment = DirectedChannelSegment(id: identity, source: chains[i].points[part].y, target: chains[i].points[part + 1].y)
                corridors[chains[i].firstRank + part].append(Transition(chain: i, part: part, segment: segment))
                identity += 1
            }
        }
        let widths = ranks.indices.map { rank in nodes.filter { nodeRanks[$0] == rank }.map(\.width).max() ?? 0 }
        var coordinates = [ranks[0]], allocations: [DirectedChannelAllocation] = []
        for rank in corridors.indices {
            let allocation = try DirectedChannelAllocation.solve(corridors[rank].map(\.segment), clearance: spacing)
            allocations.append(allocation)
            let gap = max(minimumGap, Double(allocation.count + 1) * spacing + clearance * 2)
            coordinates.append(coordinates[rank] + widths[rank] / 2 + gap + widths[rank + 1] / 2)
        }
        for node in nodes { node.center.x = coordinates[nodeRanks[node]!] }
        let paths = chains.map { chain -> [Point] in
            var p = chain.points
            for i in p.indices {
                let rank = chain.firstRank + i
                p[i].x += coordinates[rank] - ranks[rank]
            }
            return p
        }
        var tracks: [Int: [Int: Double]] = [:]
        for rank in corridors.indices {
            let allocation = allocations[rank]
            let low = coordinates[rank] + widths[rank] / 2 + clearance
            let high = coordinates[rank + 1] - widths[rank + 1] / 2 - clearance
            // The gap formula leaves room for every slot at `spacing`; spread the tracks across
            // the channel rather than packing them around its centre.
            let step = (high - low) / Double(allocation.count + 1)
            for transition in corridors[rank] {
                tracks[transition.chain, default: [:]][transition.part] = low + Double((allocation.slots[transition.segment.id] ?? 0) + 1) * step
            }
        }
        var result: [LayoutEdge: [Point]] = [:]
        for i in chains.indices {
            let points = paths[i]
            var path = [points[0]]
            for part in 0..<(points.count - 1) {
                let a = points[part], b = points[part + 1], x = tracks[i]![part]!
                if abs(a.y - b.y) > DirectedGeometry.epsilon { path += [Point(x: x, y: a.y), Point(x: x, y: b.y)] }
                path.append(b)
            }
            let edge = chains[i].edge
            result[edge] = DirectedGeometry.compact(nodeRanks[edge.source]! > nodeRanks[edge.target]! ? path.reversed() : path)
        }
        return result
    }
}
