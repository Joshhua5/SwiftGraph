import Foundation

/// Value-only serialization of the production ForceQuadTree insertion policy.
/// Topology is rebuilt on CPU; traversal, approximation/cutoff decisions and force
/// integration execute in Metal. This is distinct from the benchmark spike's tree.
struct OrganicForceTree: Sendable {
    struct Cell {
        var bounds: Rect
        var center = Point.zero
        var mass = 0
        var children: [Int] = []
        var bodies: [Int] = []
    }
    var cells: [Cell] = []
    var positions: [Point]
    init(_ positions: [SIMD2<Float>]) throws {
        self.positions = positions.map { Point(x: Double($0.x), y: Double($0.y)) }
        guard !positions.isEmpty else { return }
        let minX = self.positions.map(\.x).min()!, minY = self.positions.map(\.y).min()!
        let size = max(1, max(self.positions.map(\.x).max()! - minX, self.positions.map(\.y).max()! - minY)) + 1e-6
        cells.append(Cell(bounds: Rect(x: minX, y: minY, width: size, height: size), center: self.positions[0]))
        for i in positions.indices {
            if i % 128 == 0 { try Task.checkCancellation() }
            insert(i, into: 0, depth: 0)
        }
    }
    private func quadrant(_ point: Point, _ cell: Int) -> Int {
        (point.x >= cells[cell].bounds.center.x ? 1 : 0) + (point.y >= cells[cell].bounds.center.y ? 2 : 0)
    }
    private mutating func insert(_ body: Int, into index: Int, depth: Int) {
        let mass = cells[index].mass
        cells[index].center = (cells[index].center * Double(mass) + positions[body]) / Double(mass + 1)
        cells[index].mass += 1
        if cells[index].children.isEmpty && (cells[index].bodies.isEmpty || depth >= 40) {
            cells[index].bodies.append(body); return
        }
        if cells[index].children.isEmpty {
            let r = cells[index].bounds, half = r.width / 2
            let first = cells.count
            for q in 0..<4 {
                cells.append(Cell(bounds: Rect(x: r.x + Double(q % 2) * half, y: r.y + Double(q / 2) * half, width: half, height: half)))
            }
            cells[index].children = Array(first..<(first + 4))
            let previous = cells[index].bodies; cells[index].bodies = []
            for old in previous { insert(old, into: cells[index].children[quadrant(positions[old], index)], depth: depth + 1) }
        }
        insert(body, into: cells[index].children[quadrant(positions[body], index)], depth: depth + 1)
    }
    var gpuBounds: [SIMD4<Float>] { cells.map { SIMD4(Float($0.bounds.x), Float($0.bounds.y), Float($0.bounds.width), Float($0.bounds.height)) } }
    var gpuCenters: [SIMD4<Float>] { cells.map { SIMD4(Float($0.center.x), Float($0.center.y), Float($0.mass), 0) } }
    var gpuChildren: [SIMD4<UInt32>] {
        cells.map { cell in
            cell.children.isEmpty ? SIMD4(repeating: UInt32.max) : SIMD4(UInt32(cell.children[0]), UInt32(cell.children[1]), UInt32(cell.children[2]), UInt32(cell.children[3]))
        }
    }
    var gpuLeaves: (ranges: [SIMD2<UInt32>], bodies: [UInt32]) {
        var ranges: [SIMD2<UInt32>] = [], bodies: [UInt32] = []
        for cell in cells { ranges.append(SIMD2(UInt32(bodies.count), UInt32(cell.bodies.count))); bodies.append(contentsOf: cell.bodies.map(UInt32.init)) }
        return (ranges, bodies)
    }
}
