import Foundation

/// Assigns the runs that share one corridor to ordered tracks: overlapping runs get distinct tracks, disjoint runs
/// may share one, and the order keeps arms from crossing other runs where it can. Shared by the directed layout's
/// rank channels and by the BSP and grouped routers' corridors.
struct TrackAllocation {
    var slots: [Int: Int]
    var count: Int

    private static let epsilon: Float = 0.0001

    /// Clearance is a hard separation constraint. Crossing preferences are soft: insert the
    /// strongest preferences first and reverse any that close a cycle. Pairs without a
    /// preference only need distinct slots, so they stay unoriented until the weighted order
    /// is known and are then oriented to add the least depth.
    static func solve(_ input: [TrackSegment], clearance: Float) throws -> Self {
        let segments = input.filter { abs($0.source - $0.target) > epsilon }.sorted { $0.id < $1.id }
        struct Preference {
            var from: Int
            var to: Int
            var weight: Int
        }
        var preferences: [Preference] = []
        var neutral: [Preference] = []
        func arms(_ s: TrackSegment, heading side: TrackSegment.Side) -> [Float] {
            (s.sourceSide == side ? [s.source] : []) + (s.targetSide == side ? [s.target] : [])
        }
        func cost(_ a: TrackSegment, _ b: TrackSegment) -> Int {
            // A takes the lower track. Only A's arms towards the high side and B's towards the low side pass the
            // other run, and they cross it when they leave from inside its extent.
            let rising = arms(a, heading: .high)
            let falling = arms(b, heading: .low)
            let crossings =
                rising.filter { $0 > b.low && $0 < b.high }.count + falling.filter { $0 > a.low && $0 < a.high }.count
            // Near coincident opposing arms need the opposite order to avoid sharing.
            let conflicts = rising.reduce(0) { total, r in total + falling.filter { abs(r - $0) < clearance }.count }
            return crossings * 16 + conflicts * 32
        }
        func consider(_ i: Int, _ j: Int) {
            let a = segments[i]
            let b = segments[j]
            let ab = cost(a, b)
            let ba = cost(b, a)
            let aDown = a.target >= a.source
            let bDown = b.target >= b.source
            let aFirst =
                ab == ba
                ? (aDown != bDown
                    ? aDown
                    : (a.source + a.target == b.source + b.target
                        ? a.id < b.id
                        : (aDown
                            ? a.source + a.target > b.source + b.target : a.source + a.target < b.source + b.target)))
                : ab < ba
            let preference = Preference(from: aFirst ? i : j, to: aFirst ? j : i, weight: abs(ab - ba))
            if preference.weight == 0 { neutral.append(preference) } else { preferences.append(preference) }
        }
        // Sweep by lower bound: only segments within clearance of each other form a pair.
        var active: [Int] = []
        for i in segments.indices.sorted(by: {
            segments[$0].low == segments[$1].low ? $0 < $1 : segments[$0].low < segments[$1].low
        }) {
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
        preferences.sort(by: order)
        neutral.sort(by: order)
        var outgoing = Array(repeating: [Int](), count: segments.count)
        var incoming = Array(repeating: [Int](), count: segments.count)
        func reaches(_ source: Int, _ target: Int) -> Bool {
            var stack = [source]
            var seen = Set<Int>()
            while let node = stack.popLast() {
                if node == target { return true }
                if seen.insert(node).inserted { stack.append(contentsOf: outgoing[node]) }
            }
            return false
        }
        for (i, preference) in preferences.enumerated() {
            if i % 128 == 0 { try Task.checkCancellation() }
            var a = preference.from
            var b = preference.to
            if reaches(b, a) { swap(&a, &b) }
            outgoing[a].append(b)
            incoming[b].append(a)
        }
        // Longest paths from the sources (the slot) and to the sinks bound the depth.
        var level = Array(repeating: 0, count: segments.count)
        var tail = level
        var pending = incoming.map(\.count)
        var ready = segments.indices.filter { pending[$0] == 0 }
        var next = 0
        while next < ready.count {
            let node = ready[next]
            next += 1
            for target in outgoing[node] {
                level[target] = max(level[target], level[node] + 1)
                pending[target] -= 1
                if pending[target] == 0 { ready.append(target) }
            }
        }
        for node in ready.reversed() { for target in outgoing[node] { tail[node] = max(tail[node], tail[target] + 1) } }
        func connect(_ a: Int, _ b: Int) {
            outgoing[a].append(b)
            incoming[b].append(a)
            var stack = [(b, level[a] + 1)]
            while let (node, value) = stack.popLast() {
                guard level[node] < value else { continue }
                level[node] = value
                stack.append(contentsOf: outgoing[node].map { ($0, value + 1) })
            }
            stack = [(a, tail[b] + 1)]
            while let (node, value) = stack.popLast() {
                guard tail[node] < value else { continue }
                tail[node] = value
                stack.append(contentsOf: incoming[node].map { ($0, value + 1) })
            }
        }
        for (i, pair) in neutral.enumerated() {
            if i % 128 == 0 { try Task.checkCancellation() }
            let a = pair.from
            let b = pair.to
            if reaches(a, b) || reaches(b, a) { continue }
            // Depth after each orientation is the longest chain through the new link.
            if level[b] + 1 + tail[a] < level[a] + 1 + tail[b] { connect(b, a) } else { connect(a, b) }
        }
        return Self(
            slots: Dictionary(uniqueKeysWithValues: segments.indices.map { (segments[$0].id, level[$0]) }),
            count: level.max().map { $0 + 1 } ?? 0
        )
    }
}
