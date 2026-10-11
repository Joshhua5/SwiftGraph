/// Metadata belongs to algorithms; `LayoutNode.data` always belongs to the caller.
public enum GraphMetadataKeys {
    public static let pageRank = "PageRank"
    public static let cluster = "Cluster"
    public static let fixed = "Fixed"
    public static let layoutSubset = "LayoutSubset"
}

/// Mutable reference identity is intentional. Confine a graph and its pipeline to one task.
public final class LayoutNode: Hashable {
    public let id: String
    public var name: String
    public var bounds: Rect
    public var data: Any?
    public var isGroup = false
    public var children: [LayoutNode] = []
    public weak var parent: LayoutNode?
    public var tags: Set<String> = []
    public var metadata: [String: Any] = [:]
    public init(id: String, width: Double, height: Double, data: Any? = nil) {
        self.id = id; name = id; bounds = Rect(width: width, height: height); self.data = data
    }
    public var x: Double { get { bounds.x } set { bounds.x = newValue } }
    public var y: Double { get { bounds.y } set { bounds.y = newValue } }
    public var width: Double { get { bounds.width } set { bounds.width = newValue } }
    public var height: Double { get { bounds.height } set { bounds.height = newValue } }
    public var center: Point {
        get { bounds.center }
        set { bounds.x = newValue.x - width / 2; bounds.y = newValue.y - height / 2 }
    }
    public static func == (a: LayoutNode, b: LayoutNode) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public enum PortConstraint: String, CaseIterable, Codable, Sendable { case none, top, bottom, left, right }

public final class LayoutEdge: Hashable {
    public let source: LayoutNode
    public let target: LayoutNode
    public var data: Any?
    public var path: [Point] = []
    public var labelBounds = Rect()
    public var sourcePort: PortConstraint = .none
    public var targetPort: PortConstraint = .none
    public var sourcePortCandidates: [PortConstraint] = []
    public var targetPortCandidates: [PortConstraint] = []
    public init(source: LayoutNode, target: LayoutNode, data: Any? = nil) {
        self.source = source; self.target = target; self.data = data
    }
    public static func == (a: LayoutEdge, b: LayoutEdge) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public final class LayoutGraph {
    public var nodes: [LayoutNode] = []
    public var edges: [LayoutEdge] = []
    public let root: LayoutNode
    public init() { root = LayoutNode(id: "ROOT", width: 0, height: 0); root.isGroup = true }
    public func addNode(_ node: LayoutNode) {
        nodes.append(node)
        if node.parent == nil { root.children.append(node); node.parent = root }
    }
    public func addEdge(_ edge: LayoutEdge) { edges.append(edge) }
    /// Temporary graph membership must never reparent nodes in the caller's hierarchy.
    public func addNodeDetached(_ node: LayoutNode) { nodes.append(node); root.children.append(node) }
    public var bounds: Rect { enclosingBounds(nodes) }
}

public protocol LayoutAlgorithm {
    func applyLayout(_ graph: LayoutGraph) throws
}
public extension LayoutAlgorithm {
    func applyLayoutAsync(_ graph: LayoutGraph) async throws { try Task.checkCancellation(); try applyLayout(graph) }
}
public protocol EdgeRouter { func routeEdges(_ graph: LayoutGraph) }
public typealias ILayoutAlgorithm = LayoutAlgorithm
public typealias IEdgeRouter = EdgeRouter

func enclosingBounds(_ nodes: [LayoutNode]) -> Rect {
    guard let first = nodes.first else { return Rect() }
    return nodes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
}
func straightEdges(_ graph: LayoutGraph) {
    for e in graph.edges where e.source !== e.target { e.path = [e.source.center, e.target.center] }
}
func translate(_ graph: LayoutGraph, by offset: Point) {
    for n in graph.nodes { n.center = n.center + offset }
    for e in graph.edges {
        e.path = e.path.map { $0 + offset }
        e.labelBounds = e.labelBounds.translated(by: offset)
    }
}
func subgraph(_ graph: LayoutGraph, nodes: [LayoutNode]) -> LayoutGraph {
    let result = LayoutGraph(), members = Set(nodes)
    for node in nodes { result.addNodeDetached(node) }
    result.edges = graph.edges.filter { members.contains($0.source) && members.contains($0.target) }
    return result
}
struct Adjacency {
    var nodes: [LayoutNode]
    var index: [LayoutNode: Int]
    var outgoing: [[Int]]
    var incoming: [[Int]]
    var neighbors: [[Int]]
    init(_ graph: LayoutGraph, excludingGroups: Bool = false) {
        nodes = graph.nodes.filter { !excludingGroups || !$0.isGroup }
        index = Dictionary(nodes.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        outgoing = Array(repeating: [], count: nodes.count); incoming = outgoing; neighbors = outgoing
        for e in graph.edges {
            guard let s = index[e.source], let t = index[e.target], s != t else { continue }
            outgoing[s].append(t); incoming[t].append(s); neighbors[s].append(t); neighbors[t].append(s)
        }
    }
    func components() -> [[Int]] {
        var seen = Set<Int>(), result: [[Int]] = []
        for seed in nodes.indices where !seen.contains(seed) {
            var queue = [seed], cursor = 0; seen.insert(seed)
            while cursor < queue.count {
                for next in neighbors[queue[cursor]] where seen.insert(next).inserted { queue.append(next) }
                cursor += 1
            }
            result.append(queue)
        }
        return result
    }
    func layers(maxWidth: Int = .max) -> [[Int]] {
        guard !nodes.isEmpty else { return [] }
        var degree = incoming.map(\.count), ranks = Array(repeating: -1, count: nodes.count)
        var layers: [[Int]] = [], queue = nodes.indices.filter { degree[$0] == 0 }, cursor = 0
        func assign(_ v: Int) {
            var rank = incoming[v].map { ranks[$0] + 1 }.max() ?? 0
            while rank < layers.count && layers[rank].count >= max(1, maxWidth) { rank += 1 }
            while layers.count <= rank { layers.append([]) }
            ranks[v] = rank; layers[rank].append(v)
            for next in outgoing[v] where ranks[next] < 0 { degree[next] -= 1; if degree[next] == 0 { queue.append(next) } }
        }
        for seed in nodes.indices {
            while cursor < queue.count { let v = queue[cursor]; cursor += 1; if ranks[v] < 0 { assign(v) } }
            if ranks[seed] < 0 { assign(seed) }
        }
        while cursor < queue.count { let v = queue[cursor]; cursor += 1; if ranks[v] < 0 { assign(v) } }
        return layers.filter { !$0.isEmpty }
    }
}
