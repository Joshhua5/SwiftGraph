import Foundation

public struct EdgeBundlingConfiguration: Sendable {
    public var iterations = 30
    public var segments = 10
    public var k: Float = 0.1
    public var compatibilityThreshold: Float = 0.6
    public var bundlingDistance: Float = 500

    /// Clearance kept between bundled control points and other nodes.
    public var nodePadding: Float = 8

    /// Lateral gap between edges joining the same two nodes.
    public var edgeSpacing: Float = 8
    public var simplifyTolerance: Float = 2

    public init() {}

    var settings: BundlingSettings {
        BundlingSettings(
            iterations: iterations,
            segments: segments,
            k: k,
            compatibilityThreshold: compatibilityThreshold,
            bundlingDistance: bundlingDistance,
            nodePadding: nodePadding,
            edgeSpacing: edgeSpacing,
            simplifyTolerance: simplifyTolerance
        )
    }

    func validate() throws {
        guard iterations >= 0, segments >= 0, k.isFinite, k >= 0, compatibilityThreshold.isFinite,
            (0...1).contains(compatibilityThreshold), bundlingDistance.isFinite, bundlingDistance >= 0,
            nodePadding.isFinite, nodePadding >= 0, edgeSpacing.isFinite, edgeSpacing >= 0, simplifyTolerance.isFinite,
            simplifyTolerance >= 0
        else {
            throw LayoutExecutionError.invalidInput("Invalid edge bundling configuration.")
        }
    }
}
