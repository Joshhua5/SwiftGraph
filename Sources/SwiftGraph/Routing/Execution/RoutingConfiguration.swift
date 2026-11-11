import Foundation

public struct RoutingConfiguration: Sendable {
    public var kind: RoutingKind
    public var padding: Float = 10
    public var edgeSpacing: Float = 10
    public var gridSize: Int = 20

    public var channelBendPenalty: Int {
        get { Int(exactly: bendPenalty) ?? 0 }
        set { bendPenalty = Float(newValue) }
    }

    public var congestionPenalty: Int = 2
    public var busSpacing: Float = 20
    public var margin: Float = 20
    public var bendPenalty: Float = 40
    public var bundleSpacing: Float = 10
    public var obstacleMargin: Float = 10
    /// Grouped routing only: lets the router slide nodes to widen crowded corridors. Off by default so routing never
    /// changes placement; see `OrthogonalGroupedEdgeRouter.movesNodesToWidenCorridors`.
    public var movesNodesToWidenCorridors = false

    public var parallelEdgeSpacing: Float {
        get { edgeSpacing }
        set { edgeSpacing = newValue }
    }

    public var spacing: Float {
        get { edgeSpacing }
        set { edgeSpacing = newValue }
    }

    public var loopSize: Float = 16
    public var curveIterations: Int = 2
    public var labelIterations: Int = 200

    public var iterations: Int {
        get { kind == .curveFitting ? curveIterations : labelIterations }
        set { if kind == .curveFitting { curveIterations = newValue } else { labelIterations = newValue } }
    }

    /// Automatic selection uses edge count; routing has no organic iteration threshold.
    public var minimumMetalEdgeCount: Int = 256

    public init(_ kind: RoutingKind) {
        self.kind = kind
        if kind == .orthogonalGrouped { bendPenalty = 100 }
        if kind == .channel { bendPenalty = 2 }
        if kind == .parallelEdges { edgeSpacing = 20 }
    }

    func validate() throws {
        let values: [Float]
        switch kind {
        case .polyline, .givenCoordinates: values = [padding, edgeSpacing]
        case .channel:
            guard gridSize > 0, Int(exactly: bendPenalty) != nil else {
                throw LayoutExecutionError.invalidInput("Channel grid size must be positive and bend penalty integral.")
            }
            values = []
        case .bus: values = [busSpacing]
        case .bsp: values = [margin, bendPenalty, edgeSpacing]
        case .orthogonalGrouped: values = [bundleSpacing, obstacleMargin, bendPenalty]
        case .parallelEdges, .edgeSeparation: values = [edgeSpacing]
        case .selfLoops: values = [loopSize]
        case .curveFitting:
            guard curveIterations >= 0 else {
                throw LayoutExecutionError.invalidInput("Curve iterations must be nonnegative.")
            }
            values = []
        case .labelLayout:
            guard labelIterations >= 0 else {
                throw LayoutExecutionError.invalidInput("Label iterations must be nonnegative.")
            }
            values = []
        case .octilinear, .endpointClipping, .labelPlacement: values = []
        }
        guard values.allSatisfy(\.isFinite), minimumMetalEdgeCount >= 0 else {
            throw LayoutExecutionError.invalidInput("Routing parameters must be finite.")
        }
    }
}
