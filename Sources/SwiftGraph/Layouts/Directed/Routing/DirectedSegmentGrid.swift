import Foundation

/// Uniform bucket index over axis-aligned segments. Queries return only segments whose
/// bucket overlaps the (margin-inflated) query box, so pair scans stay near-linear.
///
/// `segments` stays dense: removing an owner moves the last slot into each hole. Visiting order
/// therefore depends on the history of inserts and removals, so callers must not depend on it.
final class DirectedSegmentGrid {
    private struct Cell: Hashable { var x: Int, y: Int }

    private let size: Float
    private(set) var segments: [DirectedGeometry.Segment] = []
    private var owners: [Int] = []
    private var cells: [Cell: [Int]] = [:]
    /// Slots held by each owner, so one route can leave the index without a rebuild.
    private var slots: [Int: [Int]] = [:]
    private var stamps: [Int] = []
    private var current = 0

    init(cellSize: Float = 64) { size = cellSize }

    func removeAll() {
        segments.removeAll(keepingCapacity: true)
        owners.removeAll(keepingCapacity: true)
        cells.removeAll(keepingCapacity: true)
        slots.removeAll(keepingCapacity: true)
        stamps.removeAll(keepingCapacity: true)
    }

    func insert(_ segment: DirectedGeometry.Segment, owner: Int) {
        let index = segments.count
        segments.append(segment)
        owners.append(owner)
        stamps.append(0)
        slots[owner, default: []].append(index)
        let (xs, ys) = span(segment, margin: 0)
        for x in xs { for y in ys { cells[Cell(x: x, y: y), default: []].append(index) } }
    }

    func insert(_ path: [Point], owner: Int) {
        for segment in DirectedGeometry.segments(path) { insert(segment, owner: owner) }
    }

    /// Removes every segment `owner` holds, touching only the buckets those segments (and the
    /// slots moved into their place) occupy.
    func remove(owner: Int) {
        guard let held = slots.removeValue(forKey: owner) else { return }
        // Highest slot first: the slot moved into each hole is then never one still to be removed.
        for index in held.sorted(by: >) { removeSlot(index) }
    }

    private func removeSlot(_ index: Int) {
        let (xs, ys) = span(segments[index], margin: 0)
        for x in xs { for y in ys { relabel(index, as: nil, in: Cell(x: x, y: y)) } }
        let last = segments.count - 1
        if index != last {
            let moved = segments[last]
            let movedOwner = owners[last]
            let (xs, ys) = span(moved, margin: 0)
            for x in xs { for y in ys { relabel(last, as: index, in: Cell(x: x, y: y)) } }
            segments[index] = moved
            owners[index] = movedOwner
            stamps[index] = stamps[last]
            if let position = slots[movedOwner]?.firstIndex(of: last) { slots[movedOwner]?[position] = index }
        }
        segments.removeLast()
        owners.removeLast()
        stamps.removeLast()
    }

    /// Replaces `slot` in one bucket with `replacement`, or drops it when there is none.
    private func relabel(_ slot: Int, as replacement: Int?, in cell: Cell) {
        guard var list = cells[cell], let position = list.firstIndex(of: slot) else { return }
        if let replacement {
            list[position] = replacement
        } else {
            list.swapAt(position, list.count - 1)
            list.removeLast()
        }
        cells[cell] = list.isEmpty ? nil : list
    }

    private func bucket(_ value: Float) -> Int { Int(max(-1e9, min(1e9, (value / size).rounded(.down)))) }

    private func span(_ s: DirectedGeometry.Segment, margin: Float) -> (ClosedRange<Int>, ClosedRange<Int>) {
        (
            bucket(min(s.a.x, s.b.x) - margin)...bucket(max(s.a.x, s.b.x) + margin),
            bucket(min(s.a.y, s.b.y) - margin)...bucket(max(s.a.y, s.b.y) + margin)
        )
    }

    /// Visits each indexed segment once whose bucket meets the query box. Callers apply the exact tests.
    func forEach(near query: DirectedGeometry.Segment, margin: Float, _ body: (Int, DirectedGeometry.Segment) -> Void) {
        let (xs, ys) = span(query, margin: max(margin, DirectedGeometry.epsilon * 2))
        if xs.count * ys.count > segments.count {
            for i in segments.indices { body(owners[i], segments[i]) }
            return
        }
        current += 1
        for x in xs {
            for y in ys {
                guard let list = cells[Cell(x: x, y: y)] else { continue }
                for i in list where stamps[i] != current {
                    stamps[i] = current
                    body(owners[i], segments[i])
                }
            }
        }
    }
}
