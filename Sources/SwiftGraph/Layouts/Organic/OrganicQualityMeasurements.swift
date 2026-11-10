import Foundation

/// Placement measurements, before any edge router is run. Lower values are preferred.
public struct OrganicQualityMeasurements: Sendable, Equatable {
    public var clearanceViolations: Int
    public var edgeNodeIntersections: Int
    public var crossings: Int
    public var edgeLength: Float
    public var drawingArea: Float

    func precedes(_ other: Self) -> Bool {
        let lhs = [Float(clearanceViolations), Float(edgeNodeIntersections), Float(crossings), edgeLength, drawingArea]
        let rhs = [
            Float(other.clearanceViolations), Float(other.edgeNodeIntersections), Float(other.crossings),
            other.edgeLength, other.drawingArea,
        ]
        for (a, b) in zip(lhs, rhs) where a != b { return a < b }
        return false
    }
}
