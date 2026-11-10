import Foundation

/// Keeps rank membership, port escapes, and virtual-chain identity through coordinate
/// assignment. No merged paths: slot reuse is only allowed for disjoint intervals.
final class DirectedChannelPlan {
    struct Chain {
        var edge: LayoutEdge
        var firstRank: Int
        var points: [Point]
    }

    let nodes: [LayoutNode]
    let ranks: [Float]
    let nodeRanks: [LayoutNode: Int]
    let clearance: Float
    let spacing: Float
    var chains: [Chain]

    init(
        nodes: [LayoutNode],
        edges: [LayoutEdge],
        feedback: Set<LayoutEdge>,
        ports: [LayoutEdge: (Point, Point, Point, Point)],
        edgeIndices: [LayoutEdge: Int],
        clearance: Float,
        spacing: Float
    ) {
        self.nodes = nodes
        self.clearance = clearance
        self.spacing = spacing
        ranks = Array(Set(nodes.map { $0.center.x })).sorted()
        let byCoordinate = Dictionary(uniqueKeysWithValues: ranks.enumerated().map { ($0.element, $0.offset) })
        nodeRanks = Dictionary(uniqueKeysWithValues: nodes.map { ($0, byCoordinate[required: $0.center.x]) })
        chains = []
        for edge in edges.sorted(by: { edgeIndices[required: $0] < edgeIndices[required: $1] })
        where !feedback.contains(edge) {
            let from = nodeRanks[required: edge.source]
            let to = nodeRanks[required: edge.target]
            // A backward edge is planned as the forward chain between the same ranks, then reversed.
            let backward = from > to
            let first = min(from, to)
            let last = max(from, to)
            guard first < last, edge.path.count == last - first + 1, let (start, end, sd, td) = ports[edge],
                backward ? (sd.x < 0 && td.x > 0) : (sd.x > 0 && td.x < 0)
            else { continue }
            let points = [start + sd * clearance] + edge.path.dropFirst().dropLast() + [end + td * clearance]
            chains.append(Chain(edge: edge, firstRank: first, points: backward ? Array(points.reversed()) : points))
        }
    }

    /// Align maximal consecutive virtual runs inside the same free, ordered channel.
    /// Real nodes and other chains bound each interval, so alignment cannot exchange
    /// edge order at a rank or sweep a long edge through a node.
    func straighten() throws {
        let order = chains.indices.sorted {
            chains[$0].points.count == chains[$1].points.count
                ? $0 < $1 : chains[$0].points.count > chains[$1].points.count
        }
        for index in order {
            try Task.checkCancellation()
            let chain = chains[index]
            guard chain.points.count > 2 else { continue }
            var intervals: [(Float, Float)] = []
            for part in 1..<(chain.points.count - 1) {
                let rank = chain.firstRank + part
                let y = chain.points[part].y
                var low = -Float.infinity
                var high = Float.infinity
                for node in nodes where nodeRanks[node] == rank {
                    let r = node.bounds.inflated(by: clearance)
                    if r.bottom <= y {
                        low = max(low, r.bottom)
                    } else if r.top >= y {
                        high = min(high, r.top)
                    } else {
                        low = y
                        high = y
                    }
                }
                for other in chains.indices where other != index {
                    let p = rank - chains[other].firstRank
                    guard p >= 0 && p < chains[other].points.count else { continue }
                    let neighbor = chains[other].points[p].y
                    if neighbor < y || (neighbor == y && other < index) {
                        low = max(low, neighbor + spacing)
                    } else {
                        high = min(high, neighbor - spacing)
                    }
                }
                intervals.append(low <= high ? (low, high) : (y, y))
            }
            var begin = 0
            while begin < intervals.count {
                var end = begin
                var low = intervals[begin].0
                var high = intervals[begin].1
                while end + 1 < intervals.count {
                    let l = max(low, intervals[end + 1].0)
                    let h = min(high, intervals[end + 1].1)
                    if l > h { break }
                    end += 1
                    low = l
                    high = h
                }
                // Endpoint-aligned runs save two bends when the shared interval allows it.
                // `chain.points[0]` is read alongside, so the chain is non-empty.
                let candidates =
                    [chain.points[0].y, chain.points.last!.y]
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
    func apply(minimumGap: Float) throws -> [LayoutEdge: [Point]] {
        guard ranks.count > 1 else { return [:] }
        try straighten()
        struct Transition {
            var chain: Int
            var part: Int
            var segment: DirectedChannelSegment
        }
        var corridors = Array(repeating: [Transition](), count: ranks.count - 1)
        var identity = 0
        for i in chains.indices {
            for part in 0..<(chains[i].points.count - 1) {
                let segment = DirectedChannelSegment(
                    id: identity,
                    source: chains[i].points[part].y,
                    target: chains[i].points[part + 1].y
                )
                corridors[chains[i].firstRank + part].append(Transition(chain: i, part: part, segment: segment))
                identity += 1
            }
        }
        let widths = ranks.indices.map { rank in nodes.filter { nodeRanks[$0] == rank }.map(\.width).max() ?? 0 }
        var coordinates = [ranks[0]]
        var allocations: [DirectedChannelAllocation] = []
        for rank in corridors.indices {
            let allocation = try DirectedChannelAllocation.solve(corridors[rank].map(\.segment), clearance: spacing)
            allocations.append(allocation)
            let gap = max(minimumGap, Float(allocation.count + 1) * spacing + clearance * 2)
            coordinates.append(coordinates[rank] + widths[rank] / 2 + gap + widths[rank + 1] / 2)
        }
        for node in nodes { node.center.x = coordinates[nodeRanks[required: node]] }
        let paths = chains.map { chain -> [Point] in
            var p = chain.points
            for i in p.indices {
                let rank = chain.firstRank + i
                p[i].x += coordinates[rank] - ranks[rank]
            }
            return p
        }
        var tracks: [Int: [Int: Float]] = [:]
        for rank in corridors.indices {
            let allocation = allocations[rank]
            let low = coordinates[rank] + widths[rank] / 2 + clearance
            let high = coordinates[rank + 1] - widths[rank + 1] / 2 - clearance
            // The gap formula leaves room for every slot at `spacing`; spread the tracks across
            // the channel rather than packing them around its centre.
            let step = (high - low) / Float(allocation.count + 1)
            for transition in corridors[rank] {
                tracks[transition.chain, default: [:]][transition.part] =
                    low + Float((allocation.slots[transition.segment.id] ?? 0) + 1) * step
            }
        }
        var result: [LayoutEdge: [Point]] = [:]
        for i in chains.indices {
            let points = paths[i]
            var path = [points[0]]
            for part in 0..<(points.count - 1) {
                let a = points[part]
                let b = points[part + 1]
                guard let x = tracks[required: i][part] else {
                    preconditionFailure("Every transition of a channel chain is assigned a track")
                }
                if abs(a.y - b.y) > DirectedGeometry.epsilon { path += [Point(x: x, y: a.y), Point(x: x, y: b.y)] }
                path.append(b)
            }
            let edge = chains[i].edge
            result[edge] = DirectedGeometry.compact(
                nodeRanks[required: edge.source] > nodeRanks[required: edge.target] ? path.reversed() : path
            )
        }
        return result
    }
}
