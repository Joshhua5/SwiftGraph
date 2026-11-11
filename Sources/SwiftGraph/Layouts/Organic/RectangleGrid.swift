import Foundation

/// Rectangles bucketed into square cells, so the rectangles that may intersect a query are found without scanning all
/// of them.
///
/// Each rectangle is filed under every cell its closed extent touches, and a query visits every cell its closed extent
/// touches. Cell indices come from flooring coordinates divided by the cell size, which is monotonic, so two
/// rectangles whose closed extents overlap always share a cell: the candidates are a superset of the true hits.
struct RectangleGrid {
    private struct Cell: Hashable {
        var x: Int
        var y: Int
    }

    private struct CellRange {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
    }

    private let cellSize: Float
    private var cells: [Cell: [Int]] = [:]
    private var ranges: [CellRange] = []

    /// A cell size of at least the largest rectangle side keeps each rectangle in at most four cells.
    init(_ rects: [Rect], cellSize: Float) {
        self.cellSize = cellSize.isFinite && cellSize > 0 ? cellSize : 1
        ranges.reserveCapacity(rects.count)
        for (index, rect) in rects.enumerated() {
            let range = self.range(rect)
            ranges.append(range)
            insert(index, range)
        }
    }

    // MARK: - Updating

    /// Refiles rectangle `index`, which now covers `rect`.
    mutating func move(_ index: Int, to rect: Rect) {
        let old = ranges[index]
        let new = range(rect)
        guard old.minX != new.minX || old.maxX != new.maxX || old.minY != new.minY || old.maxY != new.maxY else {
            return
        }
        for x in old.minX...old.maxX {
            for y in old.minY...old.maxY {
                cells[Cell(x: x, y: y)]?.removeAll { $0 == index }
            }
        }
        ranges[index] = new
        insert(index, new)
    }

    // MARK: - Querying

    /// Calls `body` with every rectangle filed in a cell that `rect` touches. A rectangle in several of those cells
    /// is passed once per cell.
    func forEachCandidate(near rect: Rect, _ body: (Int) -> Void) {
        let range = range(rect)
        for x in range.minX...range.maxX {
            for y in range.minY...range.maxY {
                guard let members = cells[Cell(x: x, y: y)] else { continue }
                for index in members { body(index) }
            }
        }
    }

    // MARK: - Cells

    private mutating func insert(_ index: Int, _ range: CellRange) {
        for x in range.minX...range.maxX {
            for y in range.minY...range.maxY {
                cells[Cell(x: x, y: y), default: []].append(index)
            }
        }
    }

    private func range(_ rect: Rect) -> CellRange {
        CellRange(
            minX: cell(rect.left),
            maxX: max(cell(rect.left), cell(rect.right)),
            minY: cell(rect.top),
            maxY: max(cell(rect.top), cell(rect.bottom))
        )
    }

    /// Clamping keeps the mapping monotonic while bounding it, so far-flung coordinates cannot overflow `Int`. A NaN
    /// coordinate intersects nothing, so any cell will do.
    private func cell(_ value: Float) -> Int {
        let index = (value / cellSize).rounded(.down)
        guard !index.isNaN else { return 0 }
        return Int(min(max(index, -1_000_000_000), 1_000_000_000))
    }
}
