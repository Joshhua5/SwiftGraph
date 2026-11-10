import Foundation

/// Uniform bucket index over axis-aligned segments. Queries return only segments whose
/// bucket overlaps the (margin-inflated) query box, so pair scans stay near-linear.
final class DirectedSegmentGrid {
    private struct Cell: Hashable { var x: Int, y: Int }

    private let size: Float
    private(set) var segments: [DirectedGeometry.Segment] = []
    private var owners: [Int] = []
    private var cells: [Cell: [Int]] = [:]
    private var stamps: [Int] = []
    private var current = 0

    init(cellSize: Float = 64) { size = cellSize }

    func removeAll() {
        segments.removeAll(keepingCapacity: true)
        owners.removeAll(keepingCapacity: true)
        cells.removeAll(keepingCapacity: true)
        stamps.removeAll(keepingCapacity: true)
    }

    func insert(_ segment: DirectedGeometry.Segment, owner: Int) {
        let index = segments.count
        segments.append(segment)
        owners.append(owner)
        stamps.append(0)
        let (xs, ys) = span(segment, margin: 0)
        for x in xs { for y in ys { cells[Cell(x: x, y: y), default: []].append(index) } }
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
