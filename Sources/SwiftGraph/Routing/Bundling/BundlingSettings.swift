import Foundation

struct BundlingSettings: Sendable {
    var iterations = 30
    var segments = 10
    var k: Float = 0.1
    var compatibilityThreshold: Float = 0.6
    var bundlingDistance: Float = 500.0

    /// Clearance kept between bundled control points and other nodes.
    var nodePadding: Float = 8.0

    /// Lateral gap between edges joining the same two nodes.
    var edgeSpacing: Float = 8.0

    /// Control points closer than this to the line through their neighbours are dropped.
    var simplifyTolerance: Float = 2.0
}
