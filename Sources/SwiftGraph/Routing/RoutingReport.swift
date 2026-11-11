import Foundation

/// What one routing pass could not do, in the same shape for every router.
///
/// Each list holds indices into `graph.edges` of the graph that was routed, ascending and without duplicates. Routers
/// that only adjust existing routes (curve fitting, port distribution) report nothing, and a router that does not
/// override `EdgeRouter.report` always reports an empty pass.
public struct RoutingReport: Equatable, Sendable {
    // MARK: - Properties

    /// Edges whose drawn route is not clear: it cuts a node, or the router gave up and drew a stand-in so the edge
    /// stays visible.
    public var unroutable: [Int]
    /// Edges still sharing a stretch with another after lane separation: the corridor had no room for lanes, or the
    /// lanes would have cut a node.
    public var unseparated: [Int]
    /// Edges drawn by a fallback instead of the router's own method: port constraints dropped, a flat retry, a detour
    /// round a blocked lane, an obstacle-aware polyline, an L/Z or a straight line. An edge here that is not also in
    /// `unroutable` got a clear route from the fallback.
    public var fallbacks: [Int]

    /// Whether every edge got a clear, separated route from the router's own method.
    public var isEmpty: Bool {
        unroutable.isEmpty && unseparated.isEmpty && fallbacks.isEmpty
    }

    // MARK: - Init

    public init(unroutable: [Int] = [], unseparated: [Int] = [], fallbacks: [Int] = []) {
        self.unroutable = Self.normalised(unroutable)
        self.unseparated = Self.normalised(unseparated)
        self.fallbacks = Self.normalised(fallbacks)
    }

    /// Builds a report from edge references, keeping only edges that belong to `graph`.
    init(
        _ graph: LayoutGraph,
        unroutable: [LayoutEdge] = [],
        unseparated: [LayoutEdge] = [],
        fallbacks: [LayoutEdge] = []
    ) {
        guard !(unroutable.isEmpty && unseparated.isEmpty && fallbacks.isEmpty) else {
            self.init()
            return
        }
        let positions = Dictionary(
            graph.edges.enumerated().map { (ObjectIdentifier($0.element), $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        func indices(_ edges: [LayoutEdge]) -> [Int] {
            edges.compactMap { positions[ObjectIdentifier($0)] }
        }
        self.init(
            unroutable: indices(unroutable),
            unseparated: indices(unseparated),
            fallbacks: indices(fallbacks)
        )
    }

    // MARK: - Edges

    /// The unroutable edges of `graph`, the graph this report was produced for.
    public func unroutableEdges(in graph: LayoutGraph) -> [LayoutEdge] {
        Self.edges(unroutable, in: graph)
    }

    /// The unseparated edges of `graph`, the graph this report was produced for.
    public func unseparatedEdges(in graph: LayoutGraph) -> [LayoutEdge] {
        Self.edges(unseparated, in: graph)
    }

    /// The edges of `graph` drawn by a fallback, for the graph this report was produced for.
    public func fallbackEdges(in graph: LayoutGraph) -> [LayoutEdge] {
        Self.edges(fallbacks, in: graph)
    }

    // MARK: - Private helpers

    private static func edges(_ indices: [Int], in graph: LayoutGraph) -> [LayoutEdge] {
        indices.filter(graph.edges.indices.contains).map { graph.edges[$0] }
    }

    private static func normalised(_ indices: [Int]) -> [Int] {
        Array(Set(indices)).sorted()
    }
}

// MARK: - EdgeRouter

extension EdgeRouter {
    /// Routers that do not report anything describe every pass as clean.
    public var report: RoutingReport { RoutingReport() }

    /// Routes `graph` and returns what the pass could not do; the same report stays available as `report`.
    @discardableResult
    public func route(_ graph: LayoutGraph) -> RoutingReport {
        routeEdges(graph)
        return report
    }
}
