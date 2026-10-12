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

    /// Clearance is a hard separation constraint. Crossing preferences are soft:
    /// insert the strongest preferences first and reverse any that close a cycle.
    static func solve(_ input: [DirectedChannelSegment], clearance: Double) throws -> Self {
        let segments = input.filter { abs($0.source - $0.target) > DirectedGeometry.epsilon }.sorted { $0.id < $1.id }
        struct Preference { var from: Int; var to: Int; var weight: Int }
        var preferences: [Preference] = []
        func cost(_ a: DirectedChannelSegment, _ b: DirectedChannelSegment) -> Int {
            // A lies left of B. Only A's exit and B's entrance can cross the other run.
            let crossings = (a.target > b.low && a.target < b.high ? 1 : 0)
                + (b.source > a.low && b.source < a.high ? 1 : 0)
            // Near coincident opposing arms need the opposite order to avoid sharing.
            let conflict = abs(a.target - b.source) < clearance ? 1 : 0
            return crossings * 16 + conflict * 32
        }
        for i in segments.indices {
            try Task.checkCancellation()
            for j in segments.indices where j > i {
                let a = segments[i], b = segments[j]
                guard a.low < b.high + clearance && b.low < a.high + clearance else { continue }
                let ab = cost(a, b), ba = cost(b, a)
                let aDown = a.target >= a.source, bDown = b.target >= b.source
                let aFirst = ab == ba
                    ? (aDown != bDown ? aDown : (a.source + a.target == b.source + b.target
                        ? a.id < b.id : (aDown ? a.source + a.target > b.source + b.target : a.source + a.target < b.source + b.target)))
                    : ab < ba
                preferences.append(Preference(from: aFirst ? i : j, to: aFirst ? j : i, weight: abs(ab - ba)))
            }
        }
        preferences.sort {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            if $0.from != $1.from { return $0.from < $1.from }
            return $0.to < $1.to
        }
        var outgoing = Array(repeating: [Int](), count: segments.count)
        var incoming = Array(repeating: 0, count: segments.count)
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
            outgoing[a].append(b); incoming[b] += 1
        }
        var slots = Array(repeating: 0, count: segments.count)
        var ready = segments.indices.filter { incoming[$0] == 0 }, next = 0
        while next < ready.count {
            let node = ready[next]; next += 1
            for target in outgoing[node] {
                slots[target] = max(slots[target], slots[node] + 1)
                incoming[target] -= 1
                if incoming[target] == 0 { ready.append(target) }
            }
        }
        return Self(slots: Dictionary(uniqueKeysWithValues: segments.indices.map { (segments[$0].id, slots[$0]) }),
                    count: slots.max().map { $0 + 1 } ?? 0)
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
            let first = nodeRanks[edge.source]!, last = nodeRanks[edge.target]!
            guard first < last, edge.path.count == last - first + 1, let (start, end, sd, td) = ports[edge],
                  sd.x > 0, td.x < 0 else { continue }
            chains.append(Chain(edge: edge, firstRank: first,
                points: [start + sd * clearance] + edge.path.dropFirst().dropLast() + [end + td * clearance]))
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
            let origin = (low + high - Double(max(0, allocation.count - 1)) * spacing) / 2
            for transition in corridors[rank] {
                tracks[transition.chain, default: [:]][transition.part] = origin + Double(allocation.slots[transition.segment.id] ?? 0) * spacing
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
            result[chains[i].edge] = DirectedGeometry.compact(path)
        }
        return result
    }
}
