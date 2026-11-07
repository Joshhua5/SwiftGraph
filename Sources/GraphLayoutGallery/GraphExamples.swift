import CoreGraphics
import Foundation
import SwiftGraph

/// A named graph plus the SwiftGraph pipeline used to lay it out.
struct GraphExample: Identifiable, Sendable {
    var id: String
    var title: String
    var category: String
    var summary: String
    var makeGraph: @Sendable () throws -> LayoutGraph
    var configure: @Sendable (LayoutBuilder) -> Void

    /// Builds the graph and runs the layout pipeline away from the main actor.
    @concurrent func render() async throws -> GraphSnapshot {
        let graph = try makeGraph()
        let builder = LayoutBuilder.create(graph)
        configure(builder)
        let clock = ContinuousClock(), start = clock.now
        try await builder.applyAsync()
        return GraphSnapshot(graph: graph, duration: clock.now - start)
    }

    /// Blocks until `render()` finishes. For previews only: the static preview snapshot is captured
    /// before `.task` work completes. Safe because `render()` is `@concurrent` and never needs the caller's actor.
    func renderSynchronously(timeout: TimeInterval = 3.5) -> Result<GraphSnapshot, any Error> {
        final class Box: @unchecked Sendable { var result: Result<GraphSnapshot, any Error>? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do { box.result = .success(try await render()) } catch { box.result = .failure(error) }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return .failure(CancellationError())
        }
        return box.result ?? .failure(CancellationError())
    }

    /// Renders multiple examples concurrently for contact-sheet previews.
    static func renderAllSynchronously(_ examples: [GraphExample], timeout: TimeInterval = 4.0) -> [String: Result<GraphSnapshot, any Error>] {
        final class Box: @unchecked Sendable { var results: [String: Result<GraphSnapshot, any Error>] = [:] }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            await withTaskGroup(of: (String, Result<GraphSnapshot, any Error>).self) { group in
                for example in examples {
                    group.addTask {
                        do { return (example.id, .success(try await example.render())) }
                        catch { return (example.id, .failure(error)) }
                    }
                }
                var collected: [String: Result<GraphSnapshot, any Error>] = [:]
                for await (id, result) in group { collected[id] = result }
                box.results = collected
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
        }
        return box.results
    }
}

// MARK: - Sample graphs

enum SampleGraphs {
    /// Adds a node with a width derived from its name, roughly matching the renderer's font.
    @discardableResult
    static func node(_ graph: LayoutGraph, _ id: String, in group: LayoutNode? = nil) throws -> LayoutNode {
        let node = LayoutNode(id: id, width: Float(max(74, id.count * 8 + 26)), height: 36)
        if let group { try graph.addNode(node, to: group) } else { graph.addNode(node) }
        return node
    }

    static func connect(_ graph: LayoutGraph, _ pairs: [(String, String)], labels: [String?] = []) {
        let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        for (index, (source, target)) in pairs.enumerated() {
            guard let s = byID[source], let t = byID[target] else { continue }
            let label = labels.indices.contains(index) ? labels[index] : nil
            graph.addEdge(LayoutEdge(source: s, target: t, data: label))
        }
    }

    /// A build pipeline: a layered DAG with a few skip edges and labels.
    static func buildPipeline() throws -> LayoutGraph {
        let g = LayoutGraph()
        for id in ["Checkout", "Resolve", "Lint", "Compile", "Unit Tests", "UI Tests", "Package", "Sign", "Notarize", "Publish"] {
            try node(g, id)
        }
        connect(g, [("Checkout", "Resolve"), ("Checkout", "Lint"), ("Resolve", "Compile"), ("Lint", "Compile"),
                    ("Compile", "Unit Tests"), ("Compile", "UI Tests"), ("Compile", "Package"),
                    ("Unit Tests", "Sign"), ("UI Tests", "Sign"), ("Package", "Sign"), ("Sign", "Notarize"),
                    ("Notarize", "Publish"), ("Checkout", "Publish")],
                labels: [nil, nil, "deps", nil, nil, nil, "archive", nil, nil, nil, nil, "ticket", "tag"])
        return g
    }

    /// A small social network with clusters and bridges between them.
    static func socialNetwork() throws -> LayoutGraph {
        let g = LayoutGraph()
        let people = ["Ava", "Ben", "Cleo", "Dev", "Eli", "Fay", "Gus", "Hana", "Ivo", "Jun", "Kai", "Lea", "Mo", "Nia", "Oto"]
        for id in people { try node(g, id) }
        connect(g, [("Ava", "Ben"), ("Ava", "Cleo"), ("Ben", "Cleo"), ("Cleo", "Dev"), ("Dev", "Ava"),
                    ("Eli", "Fay"), ("Fay", "Gus"), ("Gus", "Eli"), ("Gus", "Hana"), ("Hana", "Eli"),
                    ("Ivo", "Jun"), ("Jun", "Kai"), ("Kai", "Ivo"), ("Kai", "Lea"), ("Lea", "Ivo"),
                    ("Mo", "Nia"), ("Nia", "Oto"), ("Oto", "Mo"),
                    ("Dev", "Eli"), ("Hana", "Ivo"), ("Lea", "Mo"), ("Oto", "Ava")])
        return g
    }

    /// A balanced organisation tree.
    static func organisation() throws -> LayoutGraph {
        let g = LayoutGraph()
        let reports: [(String, [String])] = [
            ("CEO", ["CTO", "CFO", "COO"]),
            ("CTO", ["Platform", "Apps", "Research"]),
            ("CFO", ["Finance", "Legal"]),
            ("COO", ["Support", "Sales", "Ops"]),
            ("Apps", ["iOS", "macOS"]),
        ]
        try node(g, "CEO")
        for (_, children) in reports { for child in children { try node(g, child) } }
        connect(g, reports.flatMap { manager, children in children.map { (manager, $0) } })
        return g
    }

    /// A mind map radiating from one topic.
    static func mindMap() throws -> LayoutGraph {
        let g = LayoutGraph()
        let branches: [(String, [String])] = [
            ("Layout", ["Hierarchical", "Organic", "Tree", "Radial"]),
            ("Routing", ["Polyline", "Channel", "BSP", "Bundling"]),
            ("Analysis", ["PageRank", "Clusters"]),
            ("Metal", ["Forces", "Placement"]),
        ]
        try node(g, "SwiftGraph")
        for (branch, leaves) in branches {
            try node(g, branch)
            for leaf in leaves { try node(g, leaf) }
        }
        connect(g, branches.map { ("SwiftGraph", $0.0) } + branches.flatMap { b, leaves in leaves.map { (b, $0) } })
        return g
    }

    /// A ring of services with a few chords, plus a self-loop.
    static func serviceRing() throws -> LayoutGraph {
        let g = LayoutGraph()
        let ids = ["Gateway", "Auth", "Users", "Orders", "Billing", "Inventory", "Shipping", "Search", "Mail", "Audit"]
        for id in ids { try node(g, id) }
        var pairs = zip(ids, ids.dropFirst() + [ids[0]]).map { ($0, $1) }
        pairs += [("Gateway", "Orders"), ("Orders", "Shipping"), ("Auth", "Audit"), ("Search", "Inventory"), ("Billing", "Billing")]
        connect(g, pairs)
        return g
    }

    /// A circuit-like graph suited to orthogonal placement and channel routing.
    static func circuit() throws -> LayoutGraph {
        let g = LayoutGraph()
        for id in ["Power", "Regulator", "MCU", "Flash", "Sensor", "Radio", "Antenna", "LED", "Button", "USB"] { try node(g, id) }
        connect(g, [("Power", "Regulator"), ("USB", "Regulator"), ("Regulator", "MCU"), ("MCU", "Flash"), ("Sensor", "MCU"),
                    ("MCU", "Radio"), ("Radio", "Antenna"), ("MCU", "LED"), ("Button", "MCU"), ("USB", "MCU"),
                    ("Regulator", "Sensor"), ("Regulator", "Radio")])
        return g
    }

    /// A service architecture with nested, titled groups and cross-group dependencies.
    static func groupedArchitecture() throws -> LayoutGraph {
        let g = LayoutGraph()
        func frame(_ title: String) -> GroupFrameOptions {
            GroupFrameOptions(padding: LayoutInsets(top: 16, left: 24, bottom: 20, right: 24),
                              headerSize: Size(width: Float(title.count * 8 + 28), height: 26))
        }
        let client = try g.addGroup(id: "Clients", frame: frame("Clients"))
        let backend = try g.addGroup(id: "Backend", frame: frame("Backend"))
        let services = try g.addGroup(id: "Services", parent: backend, frame: frame("Services"))
        let storage = try g.addGroup(id: "Storage", parent: backend, frame: frame("Storage"))
        for id in ["iOS App", "Web App", "CLI"] { try node(g, id, in: client) }
        try node(g, "API Gateway", in: backend)
        for id in ["Accounts", "Catalog", "Orders"] { try node(g, id, in: services) }
        for id in ["Postgres", "Redis", "Blob Store"] { try node(g, id, in: storage) }
        try node(g, "Analytics")
        connect(g, [("iOS App", "API Gateway"), ("Web App", "API Gateway"), ("CLI", "API Gateway"),
                    ("API Gateway", "Accounts"), ("API Gateway", "Catalog"), ("API Gateway", "Orders"),
                    ("Accounts", "Postgres"), ("Orders", "Postgres"), ("Catalog", "Redis"), ("Catalog", "Blob Store"),
                    ("Orders", "Analytics")])
        return g
    }

    /// Bipartite producer/consumer traffic, a good fit for edge bundling.
    static func bipartite() throws -> LayoutGraph {
        let g = LayoutGraph()
        let producers = (1...6).map { "Producer \($0)" }, consumers = (1...6).map { "Consumer \($0)" }
        for id in producers + consumers { try node(g, id) }
        for (i, node) in g.nodes.enumerated() { node.x = i < 6 ? 0 : 600; node.y = Float(i % 6) * 70 }
        var pairs: [(String, String)] = []
        for (i, p) in producers.enumerated() {
            pairs += [(p, consumers[i]), (p, consumers[(i + 2) % 6]), (p, consumers[(i + 3) % 6])]
        }
        connect(g, pairs)
        for edge in g.edges { edge.path = [edge.source.center, edge.target.center] }
        return g
    }
}

// MARK: - Catalogue

extension GraphExample {
    static let hierarchical = GraphExample(
        id: "hierarchical", title: "Hierarchical", category: "Layouts",
        summary: "Layered DAG with labelled edges, routed by the hierarchical algorithm.",
        makeGraph: SampleGraphs.buildPipeline,
        configure: {
            $0.useHierarchical { $0.nodeSeparation = 50; $0.layerSeparation = 80 }
                .separateEdges()
                .routeSelfLoops()
                .clipEdgeEndpoints()
                .distributePorts()
                .placeLabels()
        })

    static let organic = GraphExample(
        id: "organic", title: "Organic", category: "Layouts",
        summary: "Force-directed placement of a clustered social network with polyline routing.",
        makeGraph: SampleGraphs.socialNetwork,
        configure: {
            $0.useOrganic {
                $0.iterations = 600
                $0.repulsionForce = 120
                $0.attractionForce = 0.05
            }
            .removeOverlaps { $0.minSpacing = 18 }
            .routePolyline()
            .routeSelfLoops()
            .clipEdgeEndpoints()
            .distributePorts()
        })

    static let tree = GraphExample(
        id: "tree", title: "Tree", category: "Layouts",
        summary: "Classic top-down tree layout of an organisation.",
        makeGraph: SampleGraphs.organisation,
        configure: {
            $0.useTree { $0.nodeSeparation = 36; $0.levelSeparation = 72 }
                .clipEdgeEndpoints()
                .distributePorts()
        })

    static let radialTree = GraphExample(
        id: "radial-tree", title: "Radial Tree", category: "Layouts",
        summary: "Mind map placed on concentric rings around its root topic.",
        makeGraph: SampleGraphs.mindMap,
        configure: {
            $0.useRadialTree { $0.layerDistance = 110 }
                .routePolyline()
                .clipEdgeEndpoints()
                .distributePorts()
        })

    static let circular = GraphExample(
        id: "circular", title: "Circular", category: "Layouts",
        summary: "Service ring with chords and a self-loop.",
        makeGraph: SampleGraphs.serviceRing,
        configure: {
            $0.useCircular { $0.radius = 220 }
                .routePolyline()
                .routeSelfLoops()
                .clipEdgeEndpoints()
                .distributePorts()
        })

    static let orthogonalChannel = GraphExample(
        id: "orthogonal-channel", title: "Orthogonal + Channel", category: "Routing",
        summary: "Grid placement with obstacle-avoiding orthogonal channel routes.",
        makeGraph: SampleGraphs.circuit,
        configure: {
            $0.useOrthogonal { $0.gridSize = 110 }
                .routeChannel()
                .separateEdges()
                .clipEdgeEndpoints()
                .distributePorts()
        })

    static let bsp = GraphExample(
        id: "bsp", title: "BSP Routing", category: "Routing",
        summary: "Hierarchical placement re-routed through binary space partition channels.",
        makeGraph: SampleGraphs.circuit,
        configure: {
            $0.useHierarchical { $0.nodeSeparation = 60; $0.layerSeparation = 90; $0.routesEdges = false }
                .routeBsp()
                .separateEdges()
                .clipEdgeEndpoints()
                .distributePorts()
        })

    static let bundling = GraphExample(
        id: "bundling", title: "Edge Bundling", category: "Routing",
        summary: "Bipartite traffic with edges bundled into shared tracks.",
        makeGraph: SampleGraphs.bipartite,
        configure: {
            $0.routeWithBundling { $0.k = 0.1 }
                .clipEdgeEndpoints()
                .distributePorts()
        })

    static let groupedArchitecture = GraphExample(
        id: "grouped", title: "Framed Groups", category: "Composition",
        summary: "Nested, titled groups laid out recursively with obstacle-avoiding cross-group routes.",
        makeGraph: SampleGraphs.groupedArchitecture,
        configure: {
            let rootLayout = HierarchicalLayoutAlgorithm()
            rootLayout.nodeSeparation = 48
            rootLayout.layerSeparation = 72
            $0.wrapWithRecursiveGroups(rootLayout) { groups in
                groups.groupLayoutSelector = { group -> any LayoutAlgorithm in
                    if group.id == "Clients" { return VerticalStackLayoutAlgorithm() }
                    let nested = HierarchicalLayoutAlgorithm()
                    nested.nodeSeparation = 44
                    nested.layerSeparation = 68
                    return nested
                }
            }
            .separateEdges()
            .routeSelfLoops()
            .clipEdgeEndpoints()
            .distributePorts()
        })

    static let swimlane = GraphExample(
        id: "swimlane", title: "Swimlanes", category: "Composition",
        summary: "Build pipeline stages assigned to vertical lanes with channel routing.",
        makeGraph: SampleGraphs.buildPipeline,
        configure: {
            let swimlane = SwimlaneLayoutAlgorithm()
            swimlane.laneAssignment = [
                "Checkout": 0, "Resolve": 0, "Lint": 0,
                "Compile": 1, "Unit Tests": 1, "UI Tests": 1,
                "Package": 2, "Sign": 2, "Notarize": 2, "Publish": 2,
            ]
            swimlane.laneWidth = 190
            swimlane.laneSpacing = 36
            swimlane.laneInternalPadding = 24
            swimlane.nodeVerticalSpacing = 36
            let titles: [Int: String] = [
                0: "Source & Lint",
                1: "Build & Test",
                2: "Package & Release",
            ]
            $0.useAlgorithm(swimlane)
                .routeChannel()
                .separateEdges()
                .clipEdgeEndpoints()
                .distributePorts()
                .placeLabels()
                .transform { graph in
                    let minY = CGFloat(graph.nodes.map(\.y).min() ?? 0)
                    let maxY = CGFloat(graph.nodes.map { $0.bounds.bottom }.max() ?? 100)
                    let headerHeight: CGFloat = 28
                    let top = minY - headerHeight - 16
                    let bottom = maxY + 18
                    graph.root.data = swimlane.computedLanes.map { lane in
                        GraphSnapshot.Lane(
                            id: lane.laneId,
                            title: titles[lane.laneId] ?? "Lane \(lane.laneId + 1)",
                            frame: CGRect(x: CGFloat(lane.x), y: top, width: CGFloat(lane.width), height: bottom - top),
                            headerHeight: headerHeight
                        )
                    }
                }
        })

    /// Every built-in `LayoutPatternType`, applied to the grouped architecture graph.
    static let presets: [GraphExample] = LayoutPatternType.allCases.map { pattern in
        GraphExample(
            id: "preset-\(pattern.rawValue)", title: pattern.rawValue, category: "Presets",
            summary: "The `.\(pattern.rawValue)` preset applied to a grouped service architecture.",
            makeGraph: SampleGraphs.groupedArchitecture,
            configure: { $0.applyPattern(pattern) })
    }

    static let all: [GraphExample] = [
        hierarchical, organic, tree, radialTree, circular,
        orthogonalChannel, bsp, bundling,
        groupedArchitecture, swimlane,
    ] + presets
}
