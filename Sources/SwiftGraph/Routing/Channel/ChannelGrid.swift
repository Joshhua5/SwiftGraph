import Foundation

/// The channel router's search space: a sparse orthogonal grid with lines only where a route can usefully run.
///
/// Lines sit at node centres, at each node side offset by the clearance, at port slots along each side, and at a few
/// subdivisions of wide gaps. Every line runs across the whole scene, so a vertex is a pair of line indices and a step
/// between neighbouring lines is a *span*, however long it is: empty ground costs one step rather than one per cell.
/// Ports sit on node-aligned lines, so where an edge leaves a node does not depend on where the scene starts.
///
/// Every obstacle and group has a line through its centre, so a span between neighbouring vertices can only pass
/// through an interior if one of its ends lies inside it: blocking is a property of vertices alone. It is stored per
/// column as sorted row ranges, so memory follows the number of nodes rather than the area.
struct ChannelGrid {
    // MARK: - Nested types

    enum Axis: Int {
        case horizontal = 0
        case vertical = 1

        var other: Axis { self == .horizontal ? .vertical : .horizontal }
    }

    /// Coordinates the caller wants as lines. Anchors are kept exactly; slots are dropped when another line is near.
    struct Lines {
        var x: [Float] = []
        var y: [Float] = []
    }

    /// The columns and rows strictly inside a rectangle grown by the clearance; empty when `first > last`.
    struct Footprint {
        var firstColumn: Int
        var lastColumn: Int
        var firstRow: Int
        var lastRow: Int

        @inline(__always)
        func contains(column: Int, row: Int) -> Bool {
            column >= firstColumn && column <= lastColumn && row >= firstRow && row <= lastRow
        }
    }

    // MARK: - Properties

    /// Grids above this many vertices drop subdivisions, then slots, then merge nearby lines, to stay near it.
    static let vertexBudget = 1_000_000

    /// Bounds the lines added to one gap, however wide; a grid over budget drops subdivisions first anyway.
    private static let maxSubdivisions = 100

    let xs: [Float]
    let ys: [Float]
    let pitch: Float
    let clearance: Float

    /// Coordinates closer than this are one line, and a point this close to a footprint's edge is outside it.
    let tolerance: Float

    /// Footprints of the group nodes, in the order the caller passed them; each edge decides which are walls.
    let groups: [Footprint]

    /// Per column, the rows whose vertex lies inside an obstacle.
    private let blocked: LineRanges

    /// Grids up to this many vertices also keep `cells`, one word per vertex, for the search's inner loop.
    private static let cellLimit = 4_000_000

    static let obstacleBit: UInt64 = 1 << 63

    /// Per vertex, `obstacleBit` inside an obstacle and bit `k` strictly inside group `k`, for the first 63 groups;
    /// nil on grids above `cellLimit`, where `isBlocked` and the group footprints answer instead.
    let cells: [UInt64]?

    var columns: Int { xs.count }
    var rows: Int { ys.count }
    var vertexCount: Int { xs.count * ys.count }

    // MARK: - Init

    /// - Parameters:
    ///   - obstacles: Rectangles no route may enter; each is grown by `clearance`.
    ///   - groups: Rectangles that are walls for some edges; also grown by `clearance`.
    ///   - anchors: Lines kept exactly, such as straight-through port positions.
    ///   - slots: Lines kept only where no other line is within half a pitch, such as spare port positions.
    ///   - margin: How far the grid reaches beyond every obstacle and group.
    init(
        obstacles: [Rect],
        groups: [Rect],
        anchors: Lines,
        slots: Lines,
        pitch: Float,
        clearance: Float,
        margin: Float
    ) {
        self.pitch = pitch
        self.clearance = clearance
        let grown = obstacles.map { $0.inflated(by: clearance) }
        let walls = groups.map { $0.inflated(by: clearance) }
        var anchorX = anchors.x
        var anchorY = anchors.y
        for r in grown + walls {
            anchorX += [r.left, r.center.x, r.right]
            anchorY += [r.top, r.center.y, r.bottom]
        }
        if let first = grown.first ?? walls.first {
            let extent = (grown + walls).reduce(first) { $0.union($1) }
            anchorX += [extent.left - margin, extent.right + margin]
            anchorY += [extent.top - margin, extent.bottom + margin]
        }
        // Over budget, drop the subdivisions, then the slots, then merge lines further apart. A tolerance above half
        // the clearance could leave a small node without a line strictly inside it.
        let maxTolerance = max(0.5, clearance / 2)
        var tolerance: Float = 0.5
        var level = 0
        var xs: [Float]
        var ys: [Float]
        while true {
            let slotX = level < 2 ? slots.x : []
            let slotY = level < 2 ? slots.y : []
            xs = Self.lines(anchors: anchorX, slots: slotX, pitch: pitch, tolerance: tolerance, subdivide: level < 1)
            ys = Self.lines(anchors: anchorY, slots: slotY, pitch: pitch, tolerance: tolerance, subdivide: level < 1)
            if xs.count * ys.count <= Self.vertexBudget || (level >= 2 && tolerance >= maxTolerance) { break }
            if level >= 2 { tolerance = min(tolerance * 2, maxTolerance) }
            level += 1
        }
        self.xs = xs
        self.ys = ys
        self.tolerance = tolerance
        let footprints = grown.map { Self.footprint($0, xs, ys, tolerance) }
        self.groups = walls.map { Self.footprint($0, xs, ys, tolerance) }
        var perColumn = Array(repeating: [ClosedRange<Int>](), count: xs.count)
        for f in footprints where f.firstColumn <= f.lastColumn && f.firstRow <= f.lastRow {
            for c in f.firstColumn...f.lastColumn { perColumn[c].append(f.firstRow...f.lastRow) }
        }
        blocked = LineRanges(perColumn)
        cells = xs.count * ys.count <= Self.cellLimit ? Self.cells(xs.count, ys.count, footprints, self.groups) : nil
    }

    /// One word per vertex: `obstacleBit` inside an obstacle, bit `k` strictly inside group `k` for the first 63.
    /// Obstacles are rasterised by the routing compute backend when one is active, as the lattice's cells were.
    private static func cells(
        _ columns: Int,
        _ rows: Int,
        _ obstacles: [Footprint],
        _ groups: [Footprint]
    ) -> [UInt64] {
        var cells = Array(repeating: UInt64(0), count: columns * rows)
        let solid = obstacles.filter { $0.firstColumn <= $0.lastColumn && $0.firstRow <= $0.lastRow }
        let occupied = RoutingCompute.current?
            .occupiedCells(
                solid.map { SIMD4(Int32($0.firstColumn), Int32($0.firstRow), Int32($0.lastColumn), Int32($0.lastRow)) }
            )
        if let occupied {
            for cell in occupied { cells[Int(cell.y) * columns + Int(cell.x)] |= obstacleBit }
        }
        let marks =
            (occupied == nil ? solid.map { ($0, obstacleBit) } : [])
            + groups.prefix(63).enumerated().map { ($1, UInt64(1) << $0) }
        for (f, bit) in marks where f.firstColumn <= f.lastColumn && f.firstRow <= f.lastRow {
            for r in f.firstRow...f.lastRow {
                for c in f.firstColumn...f.lastColumn { cells[r * columns + c] |= bit }
            }
        }
        return cells
    }

    // MARK: - Vertices and spans

    func vertex(column: Int, row: Int) -> Int { row * xs.count + column }
    func column(_ vertex: Int) -> Int { vertex % xs.count }
    func row(_ vertex: Int) -> Int { vertex / xs.count }
    func point(_ vertex: Int) -> Point { Point(x: xs[column(vertex)], y: ys[row(vertex)]) }

    /// A span is named by its lower vertex and its axis: `vertex * 2 + axis`.
    static func span(from vertex: Int, along axis: Axis) -> Int { vertex * 2 + axis.rawValue }

    /// The span joining two neighbouring vertices.
    static func span(between a: Int, _ b: Int, along axis: Axis) -> Int { span(from: min(a, b), along: axis) }

    /// The neighbour one line away along `axis` (`step` is 1 or -1), or nil at the edge of the grid.
    func neighbour(of vertex: Int, along axis: Axis, step: Int) -> Int? {
        switch axis {
        case .horizontal:
            let next = column(vertex) + step
            return next >= 0 && next < xs.count ? vertex + step : nil
        case .vertical:
            let next = row(vertex) + step
            return next >= 0 && next < ys.count ? vertex + step * xs.count : nil
        }
    }

    /// Whether the vertex at `column`, `row` lies inside an obstacle.
    @inline(__always)
    func isBlocked(column: Int, row: Int) -> Bool { blocked.contains(column, row) }

    /// Whether `vertex` lies inside an obstacle or strictly inside one of the groups indexed by `walls`.
    func isBlocked(_ vertex: Int, walls: [Int]) -> Bool {
        let c = column(vertex)
        let r = row(vertex)
        return blocked.contains(c, r) || walls.contains { groups[$0].contains(column: c, row: r) }
    }

    /// The `cells` bits for an obstacle or any of `walls`, and the walls `cells` has no bit for.
    func mask(walls: [Int]) -> (bits: UInt64, unmarked: [Footprint]) {
        guard cells != nil else { return (0, walls.map { groups[$0] }) }
        let bits = walls.filter { $0 < 63 }.reduce(Self.obstacleBit) { $0 | UInt64(1) << UInt64($1) }
        return (bits, walls.filter { $0 >= 63 }.map { groups[$0] })
    }

    // MARK: - Lines

    /// The index of the line at `value`, if one lies within the tolerance.
    func line(at value: Float, axis: Axis) -> Int? {
        let lines = axis == .horizontal ? xs : ys
        let i = Self.firstIndex(in: lines, atLeast: value - tolerance)
        return i < lines.count && lines[i] <= value + tolerance ? i : nil
    }

    /// Indices of the lines within `range`, in order.
    func lines(in range: ClosedRange<Float>, axis: Axis) -> Range<Int> {
        let lines = axis == .horizontal ? xs : ys
        let low = Self.firstIndex(in: lines, atLeast: range.lowerBound - tolerance)
        let high = Self.firstIndex(in: lines, above: range.upperBound + tolerance)
        return low..<max(low, high)
    }

    /// The first index whose value exceeds `value`. Comparisons are inclusive or strict on purpose: at coordinates
    /// so large that the tolerance rounds away, a line must still match itself.
    private static func firstIndex(in lines: [Float], above value: Float) -> Int {
        firstIndex(in: lines) { $0 > value }
    }

    /// The first index whose value is at least `value`.
    private static func firstIndex(in lines: [Float], atLeast value: Float) -> Int {
        firstIndex(in: lines) { $0 >= value }
    }

    /// The first index where `isPast` holds, for a predicate that holds from some index to the end.
    private static func firstIndex(in lines: [Float], where isPast: (Float) -> Bool) -> Int {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if isPast(lines[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// Anchors merged within the tolerance, then slots kept where no line is within half a pitch, then gaps wider than
    /// two pitches split evenly into tracks about a pitch apart, so a corridor offers as many parallel routes as the
    /// old lattice did rather than only its two clearance lines.
    private static func lines(
        anchors: [Float],
        slots: [Float],
        pitch: Float,
        tolerance: Float,
        subdivide: Bool
    ) -> [Float] {
        var accepted: [Float] = []
        for value in anchors.filter(\.isFinite).sorted() where accepted.last.map({ value - $0 > tolerance }) ?? true {
            accepted.append(value)
        }
        let spacing = pitch / 2
        var kept: [Float] = []
        var a = 0
        for value in slots.filter(\.isFinite).sorted() {
            while a < accepted.count && accepted[a] < value { a += 1 }
            let below = a > 0 ? value - accepted[a - 1] : .infinity
            let above = a < accepted.count ? accepted[a] - value : .infinity
            let previous = kept.last.map { value - $0 } ?? .infinity
            if below >= spacing && above >= spacing && previous >= spacing { kept.append(value) }
        }
        let base = (accepted + kept).sorted()
        guard subdivide else { return base }
        var result: [Float] = []
        result.reserveCapacity(base.count)
        for (low, high) in zip(base, base.dropFirst()) {
            result.append(low)
            let gap = high - low
            guard gap > 2 * pitch else { continue }
            let count = min(Int(gap / pitch) - 1, maxSubdivisions)
            for k in 1...count { result.append(low + gap * Float(k) / Float(count + 1)) }
        }
        if let last = base.last { result.append(last) }
        return result
    }

    private static func footprint(_ rect: Rect, _ xs: [Float], _ ys: [Float], _ tolerance: Float) -> Footprint {
        Footprint(
            firstColumn: firstIndex(in: xs, above: rect.left + tolerance),
            lastColumn: firstIndex(in: xs, atLeast: rect.right - tolerance) - 1,
            firstRow: firstIndex(in: ys, above: rect.top + tolerance),
            lastRow: firstIndex(in: ys, atLeast: rect.bottom - tolerance) - 1
        )
    }
}

/// Sorted, merged index ranges per line, stored flat: `starts[line]..<starts[line + 1]` indexes `lows` and `highs`.
private struct LineRanges {
    private var starts: [Int]
    private var lows: [Int]
    private var highs: [Int]

    init(_ perLine: [[ClosedRange<Int>]]) {
        starts = [0]
        lows = []
        highs = []
        for ranges in perLine {
            var current: ClosedRange<Int>?
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let c = current, range.lowerBound <= c.upperBound + 1 {
                    current = c.lowerBound...max(c.upperBound, range.upperBound)
                } else {
                    if let c = current {
                        lows.append(c.lowerBound)
                        highs.append(c.upperBound)
                    }
                    current = range
                }
            }
            if let c = current {
                lows.append(c.lowerBound)
                highs.append(c.upperBound)
            }
            starts.append(lows.count)
        }
    }

    @inline(__always)
    func contains(_ line: Int, _ value: Int) -> Bool {
        var low = starts[line]
        var high = starts[line + 1]
        if low == high { return false }
        let first = low
        // The last range starting at or below `value` is the only one that can hold it.
        while low < high {
            let mid = (low + high) / 2
            if lows[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low > first && highs[low - 1] >= value
    }
}
