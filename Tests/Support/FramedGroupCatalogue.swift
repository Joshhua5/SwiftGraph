import SwiftGraph

extension VisualCatalogue {
    static func framedGroupCases() -> [VisualCase] {
        ["mixed-layouts", "large-headers", "obstacle-detour", "incoming-alignment"].map { kind in
            VisualCase(id: "frames-" + kind, family: "composition", title: "Framed groups · " + kind,
                configuration: ["frames": "content fit with measured headers", "routing": "polyline"],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true, framedGroups: true),
                smoke: kind == "mixed-layouts") {
                let graph = LayoutGraph()
                func group(_ name: String, parent: LayoutNode? = nil, width: Double = 160, minimum: Size = Size()) throws -> LayoutNode {
                    try graph.addGroup(id: name, parent: parent,
                        frame: GroupFrameOptions(headerSize: Size(width: width, height: 26), minimumSize: minimum))
                }
                func node(_ name: String, parent: LayoutNode? = nil) throws -> LayoutNode {
                    let node = LayoutNode(id: name, width: 90, height: 36)
                    try graph.addNode(node, to: parent); return node
                }
                func edge(_ a: LayoutNode, _ b: LayoutNode) { graph.addEdge(LayoutEdge(source: a, target: b)) }
                let layout = RecursiveGroupLayout(HierarchicalLayoutAlgorithm())
                var previousBounds: [String: Rect] = [:], metrics: [String: Double] = [:]
                var notes = ["Frame rectangles include padding, measured titles and internal routes. Child layout styles remain independent."]
                switch kind {
                case "mixed-layouts":
                    let system = try group("Application · hierarchical", width: 240)
                    let pipeline = try group("Pipeline · tree", parent: system)
                    let workers = try group("Workers · circular", parent: pipeline)
                    let services = try group("Services · organic", parent: system)
                    let input = try node("Input", parent: pipeline), dispatch = try node("Dispatch", parent: pipeline)
                    let a = try node("Worker A", parent: workers), b = try node("Worker B", parent: workers), c = try node("Worker C", parent: workers)
                    let api = try node("API", parent: services), cache = try node("Cache", parent: services), store = try node("Store", parent: services)
                    let external = try node("External")
                    edge(input, dispatch); edge(dispatch, a); edge(a, b); edge(b, c); edge(c, a)
                    edge(b, api); edge(api, cache); edge(api, store); edge(store, external)
                    layout.groupLayoutSelector = { group in
                        if group === pipeline { return TreeLayoutAlgorithm() }
                        if group === workers { let circular = CircularLayoutAlgorithm(); circular.radius = 100; return circular }
                        if group === services { let organic = OrganicLayoutAlgorithm(); organic.iterations = 30; return organic }
                        return HierarchicalLayoutAlgorithm()
                    }
                case "large-headers":
                    let title = try group("A long measured title reserves horizontal space", width: 460)
                    let empty = try group("Empty group with minimum dimensions", width: 260, minimum: Size(width: 340, height: 150))
                    title.groupFrame?.padding = LayoutInsets(top: 12, left: 30, bottom: 24, right: 50)
                    let a = try node("A", parent: title), b = try node("B", parent: title)
                    edge(a, b)
                    empty.name = "Empty group · 340 × 150 minimum"
                case "incoming-alignment":
                    let target = try group("Incoming connections align the frame", width: 320, minimum: Size(width: 360, height: 250))
                    target.x = 500; target.y = 200
                    let source = try node("Input"), entry = try node("Entry", parent: target), process = try node("Process", parent: target)
                    process.y = 100
                    edge(source, entry); edge(entry, process)
                    layout.coreLayout = GivenCoordinatesLayoutAlgorithm()
                    layout.optimizeIncomingEdges = false
                    try layout.applyLayout(graph)
                    previousBounds = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.bounds) })
                    let before = zip(graph.edges[0].path, graph.edges[0].path.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
                    metrics["incomingLengthBefore"] = before
                    layout.optimizeIncomingEdges = true
                    notes.append("Previous bounds record placement before incoming-edge refinement; the frame and its internal route move together. Reported lengths compare the routed centre-to-centre path before endpoint clipping.")
                default:
                    let left = try group("Source", width: 90), right = try group("Target", width: 90)
                    let wall = try group("Unrelated frame", width: 150, minimum: Size(width: 190, height: 250))
                    left.x = 0; right.x = 560; wall.x = 250; wall.y = -80
                    let a = try node("Start", parent: left), b = try node("End", parent: right)
                    edge(a, b)
                    layout.coreLayout = GivenCoordinatesLayoutAlgorithm()
                }
                try layout.applyLayout(graph)
                if kind == "incoming-alignment" {
                    metrics["incomingLengthAfter"] = zip(graph.edges[0].path, graph.edges[0].path.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
                }
                EdgeEndpointClipper.clipToNodeBounds(graph)
                return VisualDrawing(graph: graph, previousBounds: previousBounds,
                    fallbackEdges: layout.unroutableEdges.compactMap { graph.edges.firstIndex(of: $0) },
                    reportedMetrics: metrics, notes: notes)
            }
        }
    }
}
