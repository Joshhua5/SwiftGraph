import Foundation

public struct DirectedLayoutDiagnostics: Sendable {
    public var unroutableEdges: [Int] = []
    public var overlappingNodeIDs: [[String]] = []
    public var fixedNodeConflicts: [[String]] = []
    public var crossings = 0
    public var sharedRuns = 0

    /// Near-parallel route pairs closer than `edgeSpacing`.
    public var proximateRuns = 0
    public var bends = 0
    public var routeLength: Float = 0.0
    public var displacement: Float = 0.0
    public var cachedComponents = 0
    public var feedbackEdgeIndices: [Int] = []
    public var bounds = Rect()
    public var stageMilliseconds: [String: Double] = [:]

    public init() {}
}
