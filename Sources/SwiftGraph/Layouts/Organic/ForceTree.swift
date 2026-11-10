import Foundation

/// Barnes–Hut baseline. Cells intersecting the 500-unit cutoff are opened rather than approximated.
struct ForceTree {
    struct Cell {
        var center: SIMD2<Float>
        var size: Float
        var massCenter: SIMD2<Float>
        var bodies: [Int]
        var children: [Int]
        var mass: Int
    }

    var cells: [Cell] = []
    let positions: [SIMD2<Float>]
    let theta: Float

    init(_ positions: [SIMD2<Float>], theta: Float) {
        self.positions = positions
        self.theta = theta
        guard !positions.isEmpty else { return }
        // The guard above leaves `positions` non-empty, so every min/max below has a value.
        let minX = positions.map(\.x).min()!
        let maxX = positions.map(\.x).max()!
        let minY = positions.map(\.y).min()!
        let maxY = positions.map(\.y).max()!
        _ = build(
            Array(positions.indices),
            center: SIMD2((minX + maxX) / 2, (minY + maxY) / 2),
            size: max(1, max(maxX - minX, maxY - minY) * 1.001),
            depth: 0
        )
    }

    mutating func build(_ indices: [Int], center: SIMD2<Float>, size: Float, depth: Int) -> Int {
        let index = cells.count
        let mean = indices.reduce(SIMD2<Float>.zero) { $0 + positions[$1] } / Float(indices.count)
        cells.append(Cell(center: center, size: size, massCenter: mean, bodies: [], children: [], mass: indices.count))
        if indices.count <= 1 || depth >= 32 || size < 0.001 {
            cells[index].bodies = indices
            return index
        }
        var groups = Array(repeating: [Int](), count: 4)
        for i in indices {
            groups[(positions[i].x >= center.x ? 1 : 0) + (positions[i].y >= center.y ? 2 : 0)].append(i)
        }
        var children: [Int] = []
        for q in 0..<4 where !groups[q].isEmpty {
            let offset = SIMD2<Float>(q & 1 == 0 ? -1 : 1, q & 2 == 0 ? -1 : 1) * (size / 4)
            children.append(build(groups[q], center: center + offset, size: size / 2, depth: depth + 1))
        }
        cells[index].children = children
        return index
    }

    func force(on i: Int, strength: Float) -> SIMD2<Float> {
        guard !cells.isEmpty else { return .zero }
        let point = positions[i]
        var stack = [0]
        var force = SIMD2<Float>.zero
        while let index = stack.popLast() {
            let cell = cells[index]
            if cell.children.isEmpty {
                for j in cell.bodies where i != j {
                    force += repulsiveForce(point, positions[j], index: i, otherIndex: j, strength: strength)
                }
                continue
            }
            let offset = point - cell.center
            let half = cell.size / 2
            let nearX = max(0, abs(offset.x) - half)
            let nearY = max(0, abs(offset.y) - half)
            if nearX * nearX + nearY * nearY > 250_000 { continue }
            let farX = abs(offset.x) + half
            let farY = abs(offset.y) + half
            let delta = point - cell.massCenter
            let squared = delta.x * delta.x + delta.y * delta.y
            let containsSelf = abs(offset.x) <= half && abs(offset.y) <= half
            if !containsSelf && farX * farX + farY * farY <= 250_000 && cell.size * cell.size < theta * theta * squared
            {
                force += delta * (strength * Float(cell.mass) / max(squared, 0.02))
            } else {
                stack.append(contentsOf: cell.children.reversed())
            }
        }
        return force
    }
}
