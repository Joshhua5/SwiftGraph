import Foundation

public struct TreeLayoutConfiguration: Sendable {
    public var nodeSeparation: Float = 50
    public var levelSeparation: Float = 50
    public var minRadius: Float = 50
    public var layerDistance: Float = 80
    public var siblingDistance: Float = 40
    public var padding: Float = 5

    public init() {}

    func validate(_ style: TreeLayoutStyle) throws {
        let values: [Float]
        switch style {
        case .tree: values = [nodeSeparation, levelSeparation]
        case .balloon: values = [minRadius]
        case .orgChart: values = [layerDistance, siblingDistance]
        case .treeMap: values = [padding]
        }
        guard values.allSatisfy(\.isFinite) else {
            throw LayoutExecutionError.invalidInput("Tree layout parameters must be finite.")
        }
    }

    func algorithm(_ style: TreeLayoutStyle) -> any LayoutAlgorithm {
        switch style {
        case .tree:
            let a = TreeLayoutAlgorithm()
            a.nodeSeparation = nodeSeparation
            a.levelSeparation = levelSeparation
            return a
        case .balloon:
            let a = BalloonLayoutAlgorithm()
            a.minRadius = minRadius
            return a
        case .orgChart:
            let a = OrgChartLayoutAlgorithm()
            a.layerDistance = layerDistance
            a.siblingDistance = siblingDistance
            return a
        case .treeMap:
            let a = TreeMapLayoutAlgorithm()
            a.padding = padding
            return a
        }
    }
}
