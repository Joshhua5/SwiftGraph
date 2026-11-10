import Foundation

extension GeometrySnapshot {
    func prepareBarycenter(
        fixed: [Bool],
        neighbors: [[Int]],
        tolerance: Float
    ) throws -> (state: ForceState, origin: Point) {
        let centers = nodes.map { $0.bounds.center }
        guard
            let minX = centers.map(\.x).min(),
            let maxX = centers.map(\.x).max(),
            let minY = centers.map(\.y).min(),
            let maxY = centers.map(\.y).max()
        else {
            preconditionFailure("prepareBarycenter requires nodes; the executor sends empty graphs to the CPU path")
        }
        let origin = Point(x: minX + (maxX - minX) / 2, y: minY + (maxY - minY) / 2)
        let extent = max(maxX - minX, maxY - minY)
        let degree = neighbors.map(\.count).max() ?? 0
        guard extent.isFinite, extent.ulp <= tolerance,
            Double(extent) * Double(max(1, degree)) < Double(Float.greatestFiniteMagnitude) / 4
        else {
            throw LayoutExecutionError.precisionLimit
        }
        var flat: [UInt32] = []
        var offsets: [UInt32] = [0]
        for adjacent in neighbors {
            guard flat.count + adjacent.count < Int(UInt32.max) else {
                throw LayoutExecutionError.invalidInput("Too many barycenter neighbors.")
            }
            flat.append(contentsOf: adjacent.map(UInt32.init))
            offsets.append(UInt32(flat.count))
        }
        return (
            ForceState(
                positions: centers.map { SIMD2($0.x - origin.x, $0.y - origin.y) },
                fixed: fixed.map { $0 ? 1 : 0 },
                offsets: offsets,
                neighbors: flat
            ), origin
        )
    }
}
