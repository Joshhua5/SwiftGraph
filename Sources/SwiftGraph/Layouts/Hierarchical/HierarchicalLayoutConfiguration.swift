import Foundation

public struct HierarchicalLayoutConfiguration: Sendable {
    /// The gap between layers; a minimum when `routesEdges` is on (see `HierarchicalLayoutAlgorithm`).
    public var layerSeparation: Float = 50
    public var nodeSeparation: Float = 50
    public var maxNodesPerRank: Int?
    public var routesEdges = true

    public var rankSeparation: Float {
        get { layerSeparation }
        set { layerSeparation = newValue }
    }

    public init() {}

    func validate() throws {
        guard layerSeparation.isFinite, nodeSeparation.isFinite else {
            throw LayoutExecutionError.invalidInput("Hierarchy spacing must be finite.")
        }
    }
}
