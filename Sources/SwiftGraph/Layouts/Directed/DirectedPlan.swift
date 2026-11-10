import Foundation

/// Everything the backends share about one request: the work graph, port-sized nodes and components.
final class DirectedPlan {
    let graph: LayoutGraph
    let nodes: [LayoutNode]
    let edges: [LayoutEdge]
    let edgeIndex: [LayoutEdge: Int]
    let pitch: Float
    let components: [[Int]]

    /// Feedback routed as top lanes outside the ranks; `reversed` feedback is laid out and routed between them like any
    /// edge.
    let feedback: Set<LayoutEdge>
    let reversed: Set<LayoutEdge>
    let start: ContinuousClock.Instant
    let original: LayoutGraph
    var diagnostics: DirectedLayoutDiagnostics
    var placementTime = 0.0
    var routingTime = 0.0
    var drawings: [(nodes: [LayoutNode], edges: [LayoutEdge], bounds: Rect)] = []

    /// Progress ranges for each component inside the 5%–90% component band, weighted by node count.
    var componentSlices: [(from: Double, to: Double)] {
        LayoutStageScope.slices(components.map { Double($0.count) })
            .map { (0.05 + 0.85 * $0.from, 0.05 + 0.85 * $0.to) }
    }

    init(
        graph: LayoutGraph,
        nodes: [LayoutNode],
        edges: [LayoutEdge],
        edgeIndex: [LayoutEdge: Int],
        feedback: Set<LayoutEdge>,
        reversed: Set<LayoutEdge>,
        pitch: Float,
        components: [[Int]],
        diagnostics: DirectedLayoutDiagnostics,
        start: ContinuousClock.Instant,
        original: LayoutGraph
    ) {
        self.graph = graph
        self.nodes = nodes
        self.edges = edges
        self.edgeIndex = edgeIndex
        self.feedback = feedback
        self.reversed = reversed
        self.pitch = pitch
        self.components = components
        self.diagnostics = diagnostics
        self.start = start
        self.original = original
    }
}
