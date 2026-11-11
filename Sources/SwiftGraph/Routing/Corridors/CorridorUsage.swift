import Foundation

/// How full each corridor is while edges are routed one by one, so a router can send later edges round a corridor
/// that has no room left. A corridor's capacity is the number of tracks its free width holds at `spacing`, keeping
/// `clearance` from the nodes either side. Every routed stretch running alongside counts against it, whichever line of
/// the gap it was routed on; past capacity a step costs its length again for every edge over.
final class CorridorUsage {
    private struct Entry {
        var at: Float
        var low: Float
        var high: Float
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

    static let weight = Float(ProcessInfo.processInfo.environment["CW"] ?? "0.5") ?? 0.5
    static let probe = Int(ProcessInfo.processInfo.environment["CPROBE"] ?? "0") ?? 0
    static let cap = Int(ProcessInfo.processInfo.environment["CCAP"] ?? "4") ?? 4
    let spacing: Float
    let clearance: Float
    private let walls: CorridorWalls
    /// Entries bucketed by `at` in buckets `spacing` wide, per axis: [horizontal, vertical].
    private var buckets: [[Int: [Entry]]] = [[:], [:]]
    private var gaps: [StepKey: CorridorWalls.Gap] = [:]

    init(walls: CorridorWalls, spacing: Float, clearance: Float) {
        self.walls = walls
        self.spacing = max(spacing, 1e-3)
        self.clearance = clearance
    }

    /// Tracks a gap holds at full spacing, at least one.
    static func capacity(width: Float, spacing: Float, clearance: Float) -> Int {
        let usable = width - 2 * clearance
        guard usable.isFinite else { return .max }
        return usable < 0 ? 1 : Int(usable / spacing) + 1
    }

    /// Extra cost of routing one more edge from `a` to `b`: zero for a diagonal or while the corridor has room.
    func cost(_ a: Point, _ b: Point) -> Float {
        let vertical = abs(a.x - b.x) < 1e-4
        guard vertical || abs(a.y - b.y) < 1e-4 else { return 0 }
        let at = vertical ? a.x : a.y
        let low = vertical ? min(a.y, b.y) : min(a.x, b.x)
        let high = vertical ? max(a.y, b.y) : max(a.x, b.x)
        guard high - low > 1e-4 else { return 0 }
        let axis = vertical ? 1 : 0
        if Self.probe == 1 { return 0 }
        let key = StepKey(vertical, at, low, high)
        let gap: CorridorWalls.Gap
        if let cached = gaps[key] {
            gap = cached
        } else {
            gap = walls.gap(vertical: vertical, at: at, from: low, to: high)
            gaps[key] = gap
        }
        guard !gap.isOpen else { return 0 }
        if Self.probe == 2 { return 0 }
        let capacity = Self.capacity(width: gap.width, spacing: spacing, clearance: clearance)
        let over = nearby(axis, at, low, high, within: (gap.low, gap.high)) + 1 - capacity
        return over > 0 ? Self.weight * Float(min(over, Self.cap)) * (high - low) : 0
    }

    /// Records every axis-aligned stretch of a routed path.
    func add(_ path: [Point]) {
        for (a, b) in zip(path, path.dropFirst()) {
            let vertical = abs(a.x - b.x) < 1e-4
            guard vertical || abs(a.y - b.y) < 1e-4 else { continue }
            let entry =
                vertical
                ? Entry(at: a.x, low: min(a.y, b.y), high: max(a.y, b.y))
                : Entry(at: a.y, low: min(a.x, b.x), high: max(a.x, b.x))
            guard entry.high - entry.low > 1e-4 else { continue }
            buckets[vertical ? 1 : 0][bucket(entry.at), default: []].append(entry)
        }
    }

    private func bucket(_ at: Float) -> Int { Int((at / spacing).rounded(.down)) }

    /// Recorded stretches strictly inside `within` across the axis that overlap (`low`, `high`) along it.
    private func nearby(_ axis: Int, _ at: Float, _ low: Float, _ high: Float, within: (Float, Float)) -> Int {
        var count = 0
        for b in bucket(within.0)...bucket(within.1) {
            guard let entries = buckets[axis][b] else { continue }
            for entry in entries
            where entry.at > within.0 && entry.at < within.1 && entry.low < high - 1e-4 && entry.high > low + 1e-4 {
                count += 1
            }
        }
        return count
    }
}
