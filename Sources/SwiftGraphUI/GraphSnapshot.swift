import CoreGraphics
import Foundation
import SwiftGraph

/// A `Sendable` copy of a laid-out `LayoutGraph`, so layout algorithms can run off the main actor
/// and hand their result to SwiftUI for rendering.
public struct GraphSnapshot: Sendable, Equatable {
    public struct Lane: Sendable, Identifiable, Equatable {
        public var id: Int
        public var title: String
        public var frame: CGRect
        public var headerHeight: CGFloat
        public var style: GraphLaneStyle?

        public init(
            id: Int,
            title: String,
            frame: CGRect,
            headerHeight: CGFloat = 28,
            style: GraphLaneStyle? = nil
        ) {
            self.id = id
            self.title = title
            self.frame = frame
            self.headerHeight = headerHeight
            self.style = style
        }
    }

    public struct Node: Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var frame: CGRect
        public var isGroup: Bool
        public var depth: Int
        public var headerFrame: CGRect?
        public var tags: Set<String>
        public var nodeStyle: GraphNodeStyle?
        public var groupStyle: GraphGroupStyle?

        public init(
            id: String,
            name: String,
            frame: CGRect,
            isGroup: Bool,
            depth: Int = 0,
            headerFrame: CGRect? = nil,
            tags: Set<String> = [],
            nodeStyle: GraphNodeStyle? = nil,
            groupStyle: GraphGroupStyle? = nil
        ) {
            self.id = id
            self.name = name
            self.frame = frame
            self.isGroup = isGroup
            self.depth = depth
            self.headerFrame = headerFrame
            self.tags = tags
            self.nodeStyle = nodeStyle
            self.groupStyle = groupStyle
        }
    }

    public struct Bridge: Sendable, Equatable {
        public var start: CGPoint
        public var end: CGPoint

        public init(start: CGPoint, end: CGPoint) {
            self.start = start
            self.end = end
        }
    }

    public struct Edge: Sendable, Identifiable, Equatable {
        public var id: Int
        public var sourceID: String
        public var targetID: String
        public var points: [CGPoint]
        public var bridges: [Bridge]
        public var label: String?
        public var labelFrame: CGRect?
        public var isSelfLoop: Bool
        public var isBidirectional: Bool
        public var style: GraphEdgeStyle?

        public init(
            id: Int,
            sourceID: String = "",
            targetID: String = "",
            points: [CGPoint],
            bridges: [Bridge] = [],
            label: String? = nil,
            labelFrame: CGRect? = nil,
            isSelfLoop: Bool,
            isBidirectional: Bool = false,
            style: GraphEdgeStyle? = nil
        ) {
            self.id = id
            self.sourceID = sourceID
            self.targetID = targetID
            self.points = points
            self.bridges = bridges
            self.label = label
            self.labelFrame = labelFrame
            self.isSelfLoop = isSelfLoop
            self.isBidirectional = isBidirectional
            self.style = style
        }
    }

    public var lanes: [Lane]
    public var nodes: [Node]
    public var edges: [Edge]
    public var duration: Duration

    /// World-space rectangle enclosing every lane, node, route, and label.
    public var worldBounds: CGRect {
        var rects = lanes.map(\.frame) + nodes.map(\.frame) + edges.compactMap(\.labelFrame)
        rects += edges.flatMap(\.points).map { CGRect(origin: $0, size: .zero) }
        guard let first = rects.first else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    public init(lanes: [Lane] = [], nodes: [Node], edges: [Edge], duration: Duration = .zero) {
        self.lanes = lanes
        self.nodes = nodes
        self.edges = edges
        self.duration = duration
    }

    /// Creates a snapshot from a laid-out `LayoutGraph`.
    ///
    /// - Parameters:
    ///   - graph: The `LayoutGraph` after layout and edge routing have completed.
    ///   - duration: The elapsed layout time (`Duration.zero` by default).
    ///   - lanes: Optional swimlanes; if empty, inspects `graph.root.data as? [Lane]`.
    ///   - maxEdgesForBridges: Maximum number of edges for which crossing bridge halos are precomputed.
    public init(
        graph: LayoutGraph,
        duration: Duration = .zero,
        lanes: [Lane] = [],
        maxEdgesForBridges: Int = 200
    ) {
        func depth(of node: LayoutNode) -> Int {
            var count = 0
            var cursor = node.parent
            while let parent = cursor, parent !== graph.root {
                count += 1
                cursor = parent.parent
            }
            return count
        }
        let storedLanes = (graph.root.data as? [Lane]) ?? []
        self.lanes = lanes.isEmpty ? storedLanes : lanes

        // Draw outer groups first so nested groups and leaves sit on top of them.
        nodes = graph.nodes
            .map { layoutNode in
                let descriptor = layoutNode.data as? any GraphNodeDescriptor
                let directNodeStyle = layoutNode.data as? GraphNodeStyle
                let directGroupStyle = layoutNode.data as? GraphGroupStyle
                return Node(
                    id: layoutNode.id,
                    name: layoutNode.name,
                    frame: CGRect(layoutNode.bounds),
                    isGroup: layoutNode.isGroup,
                    depth: depth(of: layoutNode),
                    headerFrame: layoutNode.groupHeaderBounds.map(CGRect.init),
                    tags: layoutNode.tags,
                    nodeStyle: descriptor?.nodeStyle ?? directNodeStyle,
                    groupStyle: descriptor?.groupStyle ?? directGroupStyle
                )
            }
            .sorted { ($0.isGroup ? 0 : 1, $0.depth) < ($1.isGroup ? 0 : 1, $1.depth) }

        let computeBridges = graph.edges.count <= maxEdgesForBridges
        var drawnSegments: [(CGPoint, CGPoint)] = []
        edges = graph.edges.enumerated()
            .map { index, edge in
                let points = Self.deduplicated(edge.path.map(CGPoint.init))
                let isSelfLoop = edge.source === edge.target
                var bridges: [Bridge] = []
                if computeBridges, !isSelfLoop, points.count >= 2 {
                    let segments = Array(zip(points, points.dropFirst()))
                    for (a, b) in segments {
                        let dx = b.x - a.x
                        let dy = b.y - a.y
                        let len = hypot(dx, dy)
                        guard len > 10 else { continue }
                        let ux = dx / len
                        let uy = dy / len
                        for (c, d) in drawnSegments {
                            guard let t = Self.intersectionParameter(a, b, c, d) else { continue }
                            let hit = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
                            let half = min(3.5, min(t * len, (1 - t) * len) * 0.42)
                            if half > 0.8 {
                                bridges.append(
                                    Bridge(
                                        start: CGPoint(x: hit.x - ux * half, y: hit.y - uy * half),
                                        end: CGPoint(x: hit.x + ux * half, y: hit.y + uy * half)
                                    )
                                )
                            }
                        }
                    }
                    drawnSegments.append(contentsOf: segments)
                }
                let hasLabel = edge.labelBounds.width > 0 && edge.labelBounds.height > 0
                let descriptor = edge.data as? any GraphEdgeDescriptor
                let directStyle = edge.data as? GraphEdgeStyle
                let label = descriptor?.edgeLabel ?? (edge.data as? String)
                return Edge(
                    id: index,
                    sourceID: edge.source.id,
                    targetID: edge.target.id,
                    points: points,
                    bridges: bridges,
                    label: label,
                    labelFrame: hasLabel ? CGRect(edge.labelBounds) : nil,
                    isSelfLoop: isSelfLoop,
                    isBidirectional: descriptor?.isBidirectional ?? false,
                    style: descriptor?.edgeStyle ?? directStyle
                )
            }
        self.duration = duration
    }

    /// Builds a `LayoutGraph`, runs the configured `LayoutBuilder` pipeline off the main actor,
    /// reports `LayoutProgress`, and returns a `GraphSnapshot`.
    @concurrent public static func render(
        backend: LayoutBackend = .cpu,
        makeGraph: @Sendable () throws -> LayoutGraph,
        configure: @Sendable (LayoutBuilder, LayoutBackend) -> Void,
        onProgress: @escaping @MainActor @Sendable (LayoutProgress) -> Void = { _ in }
    ) async throws -> GraphSnapshot {
        let graph = try makeGraph()
        let builder = LayoutBuilder.create(graph)
        configure(builder, backend)
        let clock = ContinuousClock()
        let start = clock.now
        for try await progress in builder.layoutProgress() {
            await onProgress(progress)
        }
        return GraphSnapshot(graph: graph, duration: clock.now - start)
    }

    private static func deduplicated(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(points.count)
        for p in points {
            if let last = out.last, hypot(p.x - last.x, p.y - last.y) < 0.25 { continue }
            out.append(p)
        }
        if out.count == 1, let last = points.last, points.count >= 2 {
            out.append(last)
        }
        return out
    }

    /// sin(25°): crossings shallower than this get no bridge.
    private static let minimumBridgeAngleSine: CGFloat = 0.42

    /// Returns parameter `t` in `(0, 1)` along `(a, b)` if `(a, b)` properly crosses `(c, d)`.
    private static func intersectionParameter(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat? {
        let minABX = min(a.x, b.x)
        let maxABX = max(a.x, b.x)
        let minCDX = min(c.x, d.x)
        let maxCDX = max(c.x, d.x)
        guard maxABX >= minCDX, maxCDX >= minABX else { return nil }
        let minABY = min(a.y, b.y)
        let maxABY = max(a.y, b.y)
        let minCDY = min(c.y, d.y)
        let maxCDY = max(c.y, d.y)
        guard maxABY >= minCDY, maxCDY >= minABY else { return nil }

        let ux = b.x - a.x
        let uy = b.y - a.y
        let vx = d.x - c.x
        let vy = d.y - c.y
        let denom = ux * vy - uy * vx
        // Only bridge clear crossings (about 25° or more). Shallow crossings are shared or bundled
        // tracks, where a bridge halo would chop the track into dashes.
        let lengths = hypot(ux, uy) * hypot(vx, vy)
        guard lengths > 1e-4, abs(denom) / lengths >= minimumBridgeAngleSine else { return nil }
        let wx = c.x - a.x
        let wy = c.y - a.y
        let t = (wx * vy - wy * vx) / denom
        let s = (wx * uy - wy * ux) / denom
        guard t > 0.06, t < 0.94, s > 0.06, s < 0.94 else { return nil }
        return t
    }
}
