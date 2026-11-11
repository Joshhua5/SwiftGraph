import Foundation

/// Force-directed edge bundling (Holten and van Wijk) that starts from the routes edges already have. Edges attract
/// each other when their angle, length, position and visibility are compatible; control points are subdivided over a
/// coarse-to-fine schedule, pushed out of node rectangles, and edges joining the same nodes are fanned apart
/// afterwards.
/// The result is smoothed and simplified, so edges nothing bundles with come out as plain lines.
///
/// The iteration kernel (spring plus unit attraction towards compatible edges) is the one the Metal path runs, in
/// coordinates scaled so a typical edge is about 100 units long; everything else is shared CPU work.
public final class EdgeBundlingRouter: EdgeRouter {
    public var iterations = 30
    public var segments = 10
    public var k: Float = 0.1
    public var compatibilityThreshold: Float = 0.6
    public var bundlingDistance: Float = 500
    public var nodePadding: Float = 8
    public var edgeSpacing: Float = 8
    public var simplifyTolerance: Float = 2

    /// Unroutable edges are those obstacle repair could not clear, before or after bundling.
    public private(set) var report = RoutingReport()

    @available(*, deprecated, message: "Use report.unroutable or report.unroutableEdges(in:)")
    public var unroutableEdges: [LayoutEdge] { failed }

    private var failed: [LayoutEdge] = []

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

    public func routeEdges(_ graph: LayoutGraph) {
        failed = ObstaclePolyline.repair(graph, spacing: 0)
        defer { report = RoutingReport(graph, unroutable: failed) }
        let edges = graph.edges.filter { $0.source !== $0.target }
        let index = Dictionary(
            graph.nodes.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { a, _ in a }
        )
        var bundler = EdgeBundler(
            settings,
            nodes: graph.nodes.map(\.bounds),
            solid: graph.nodes.map { !$0.isGroup },
            edges: edges.map {
                .init(
                    source: index[$0.source] ?? -1,
                    target: index[$0.target] ?? -1,
                    from: $0.source.center,
                    to: $0.target.center,
                    path: $0.path
                )
            }
        )
        guard bundler.runCPU() else { return }
        for (edge, path) in zip(edges, bundler.paths()) { edge.path = path }
        failed = ObstaclePolyline.repair(graph, spacing: 0, shortenDetours: true)
    }
}
