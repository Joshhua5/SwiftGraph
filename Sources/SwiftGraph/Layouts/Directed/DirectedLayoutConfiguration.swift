import Foundation

public struct DirectedLayoutConfiguration: Hashable, Sendable {
    public var mode: DirectedLayoutMode = .fresh
    public var canvasAspectRatio: Float = 1.6
    public var nodeSpacing: Float = 32
    public var layerSpacing: Float = 100
    public var componentSpacing: Float = 60
    public var portSpacing: Float = 12
    public var clearance: Float = 10

    /// Preferred separation between parallel edge runs. Strokes never touch below it, but parallel
    /// runs closer than this are avoided, tracks keep this spacing, and compaction never goes below it.
    public var edgeSpacing: Float = 10
    public var candidateCount: Int = 5

    /// Indices into the original edge array. A fresh layout ranks and routes these as reversed edges between the ranks.
    public var feedbackEdges: Set<Int> = []
    public var edgeWidths: [Float] = []
    public var fixedNodeIDs: Set<String> = []
    public var previousPaths: [Int: [Point]] = [:]
    public var previousBounds: [String: Rect] = [:]

    /// Placement hints for newly expanded/collapsed nodes, not constraints.
    public var insertionOrigins: [String: Point] = [:]

    public init() {}
}
