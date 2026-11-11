import Foundation

/// How full each corridor is while edges are routed one by one, so a router can send later edges round a corridor
/// that has no room left.
///
/// A corridor's capacity is the number of tracks its free width holds `spacing` apart, keeping half the `clearance`
/// from the nodes either side (the most `CorridorTracks` gives up before it squeezes tracks closer). Every routed
/// stretch running alongside counts against it, whichever line of the gap it was routed on, except the stretches of
/// edges joining the same two nodes as the edge being routed: parallel and reciprocal edges belong in one bundle, and
/// splitting them sends one far round for no gain. Past capacity a step costs `weight` times its length for every
/// edge over, counting at most `maximumOver`, so a crowded corridor is left when a neighbouring one is close, but not
/// at any length of detour.
final class CorridorUsage {
    private struct Entry {
        var at: Float
        var low: Float
        var high: Float
        var bundle: Int
    }

    private struct StepKey: Hashable {
        var vertical: Bool
        var at: Int32
        var low: Int32
        var high: Int32

        init(_ vertical: Bool, _ at: Float, _ low: Float, _ high: Float) {
            func quantize(_ value: Float) -> Int32 { Int32(clamping: Int((value * 16).rounded())) }
            self.vertical = vertical
            self.at = quantize(at)
            self.low = quantize(low)
            self.high = quantize(high)
        }
    }

    private struct Pair: Hashable {
        var low: ObjectIdentifier
        var high: ObjectIdentifier

        init(_ edge: LayoutEdge) {
            let a = ObjectIdentifier(edge.source)
            let b = ObjectIdentifier(edge.target)
            low = min(a, b)
            high = max(a, b)
        }
    }

    /// Extra cost per unit length of a step, per edge over capacity. On dense grids a half keeps lanes at least 3 pt
    /// apart with the fewest crossings; heavier weights trade crossings and bends for little more room.
    static let weight: Float = 0.5
    /// The most edges over capacity a step is charged for.
    static let maximumOver = 4

    let spacing: Float
    let clearance: Float
    private let walls: CorridorWalls
    /// Entries bucketed by `at` in buckets `spacing` wide, per axis: [horizontal, vertical].
    private var buckets: [[Int: [Entry]]] = [[:], [:]]
    private var gaps: [StepKey: CorridorWalls.Gap] = [:]
    private var bundles: [Pair: Int] = [:]
    /// Costs of the steps the current edge's search has asked for; they hold until it is recorded.
    private var costs: [StepKey: Float] = [:]
    /// The bundle of the edge being routed, set by `start`.
    private var current = -1

    init(walls: CorridorWalls, spacing: Float, clearance: Float) {
        self.walls = walls
        self.spacing = max(spacing, 1e-3)
        self.clearance = clearance
    }

    /// Tracks a gap holds `spacing` apart keeping `clearance` from either side, at least one.
    static func capacity(width: Float, spacing: Float, clearance: Float) -> Int {
        let usable = width - 2 * clearance
        guard usable.isFinite else { return .max }
        return usable < 0 ? 1 : Int(usable / spacing) + 1
    }

    /// Makes `edge` the one the following `cost` and `add` calls are for.
    func start(_ edge: LayoutEdge) {
        costs.removeAll(keepingCapacity: true)
        let pair = Pair(edge)
        if let bundle = bundles[pair] {
            current = bundle
        } else {
            current = bundles.count
            bundles[pair] = current
        }
    }

    /// Extra cost of routing the current edge from `a` to `b`: zero for a diagonal or while the corridor has room.
    func cost(_ a: Point, _ b: Point) -> Float {
        let vertical = abs(a.x - b.x) < 1e-4
        guard vertical || abs(a.y - b.y) < 1e-4 else { return 0 }
        let at = vertical ? a.x : a.y
        let low = vertical ? min(a.y, b.y) : min(a.x, b.x)
        let high = vertical ? max(a.y, b.y) : max(a.x, b.x)
        guard high - low > 1e-4 else { return 0 }
        let key = StepKey(vertical, at, low, high)
        let gap: CorridorWalls.Gap
        if let cached = gaps[key] {
            gap = cached
        } else {
            gap = walls.gap(vertical: vertical, at: at, from: low, to: high)
            gaps[key] = gap
        }
        guard !gap.isOpen else { return 0 }
        if let cached = costs[key] { return cached }
        let capacity = Self.capacity(width: gap.width, spacing: spacing, clearance: clearance / 2)
        let limit = capacity > Int.max - Self.maximumOver ? Int.max : capacity - 1 + Self.maximumOver
        let over = nearby(vertical ? 1 : 0, low, high, within: (gap.low, gap.high), limit: limit) + 1 - capacity
        let cost = over > 0 ? Self.weight * Float(min(over, Self.maximumOver)) * (high - low) : 0
        costs[key] = cost
        return cost
    }

    /// Records every axis-aligned stretch of the current edge's routed path.
    func add(_ path: [Point]) {
        costs.removeAll(keepingCapacity: true)
        for (a, b) in zip(path, path.dropFirst()) {
            let vertical = abs(a.x - b.x) < 1e-4
            guard vertical || abs(a.y - b.y) < 1e-4 else { continue }
            let entry =
                vertical
                ? Entry(at: a.x, low: min(a.y, b.y), high: max(a.y, b.y), bundle: current)
                : Entry(at: a.y, low: min(a.x, b.x), high: max(a.x, b.x), bundle: current)
            guard entry.high - entry.low > 1e-4 else { continue }
            buckets[vertical ? 1 : 0][bucket(entry.at), default: []].append(entry)
        }
    }

    private func bucket(_ at: Float) -> Int { Int((at / spacing).rounded(.down)) }

    /// Recorded stretches of other bundles strictly inside `within` across the axis that overlap (`low`, `high`)
    /// along it, counted up to `limit`.
    private func nearby(_ axis: Int, _ low: Float, _ high: Float, within: (Float, Float), limit: Int) -> Int {
        var count = 0
        for b in bucket(within.0)...bucket(within.1) {
            guard let entries = buckets[axis][b] else { continue }
            for entry in entries
            where entry.bundle != current && entry.at > within.0 && entry.at < within.1 && entry.low < high - 1e-4
                && entry.high > low + 1e-4
            {
                count += 1
                if count >= limit { return count }
            }
        }
        return count
    }
}
