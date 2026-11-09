import CoreGraphics
import Foundation
import SwiftGraph
import SwiftGraphUI

/// A named graph plus the SwiftGraph pipeline used to lay it out.
struct GraphExample: Identifiable, Sendable {
    var id: String
    var title: String
    var category: String
    var summary: String
    /// Guidance shown from the sidebar's info button; `nil` hides the button.
    var info: ExampleInfo? = nil
    var makeGraph: @Sendable () throws -> LayoutGraph
    var configure: @Sendable (LayoutBuilder, LayoutBackend) -> Void

    /// Builds the graph and runs the layout pipeline away from the main actor, reporting its progress in order.
    @concurrent func render(backend: LayoutBackend = .cpu,
                            onProgress: @escaping @MainActor @Sendable (LayoutProgress) -> Void = { _ in }) async throws -> GraphSnapshot {
        try await GraphSnapshot.render(
            backend: backend,
            makeGraph: makeGraph,
            configure: configure,
            onProgress: onProgress
        )
    }

    /// Blocks until `render()` finishes. For previews only: the static preview snapshot is captured
    /// before `.task` work completes. Safe because `render()` is `@concurrent` and never needs the caller's actor.
    func renderSynchronously(backend: LayoutBackend = .cpu, timeout: TimeInterval = 3.5) -> Result<GraphSnapshot, any Error> {
        final class Box: @unchecked Sendable { var result: Result<GraphSnapshot, any Error>? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do { box.result = .success(try await render(backend: backend)) } catch { box.result = .failure(error) }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return .failure(CancellationError())
        }
        return box.result ?? .failure(CancellationError())
    }

    /// Renders multiple examples concurrently for contact-sheet previews.
    static func renderAllSynchronously(
        _ examples: [GraphExample],
        backend: LayoutBackend = .cpu,
        timeout: TimeInterval = 4.0
    ) -> [String: Result<GraphSnapshot, any Error>] {
        final class Box: @unchecked Sendable { var results: [String: Result<GraphSnapshot, any Error>] = [:] }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            await withTaskGroup(of: (String, Result<GraphSnapshot, any Error>).self) { group in
                for example in examples {
                    group.addTask {
                        do { return (example.id, .success(try await example.render(backend: backend))) }
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

/// Explains what a layout, preset, routing or composition is for and when to reach for it.
struct ExampleInfo: Sendable {
    var designedFor: String
    var whenToUse: String
    var avoidWhen: String
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
        info: ExampleInfo(
            designedFor: "Directed graphs with a clear flow. Nodes are assigned to layers so most edges point the same way, and the algorithm reorders each layer to reduce crossings.",
            whenToUse: "Pipelines, workflows, dependency graphs, state machines and call hierarchies, where reading the direction of flow matters more than anything else.",
            avoidWhen: "The graph is undirected, densely cyclic or has no natural direction. Back edges get reversed and long edges stretch across many layers."),
        makeGraph: SampleGraphs.buildPipeline,
        configure: { builder, backend in
            builder.useHierarchical(backend: backend) { $0.nodeSeparation = 50; $0.layerSeparation = 80 }
                .separateEdges(backend: backend)
                .routeSelfLoops(backend: backend)
                .clipEdgeEndpoints(backend: backend)
                .distributePorts(backend: backend)
                .placeLabels(backend: backend)
        })

    static let organic = GraphExample(
        id: "organic", title: "Organic", category: "Layouts",
        summary: "Force-directed placement of a clustered social network with polyline routing.",
        info: ExampleInfo(
            designedFor: "Undirected or loosely structured graphs. Edges pull connected nodes together like springs and every node repels the others, so the graph's natural structure shows on its own.",
            whenToUse: "Social networks, knowledge graphs and peer-to-peer topologies, or any graph where you want clusters, hubs and bridges to stand out without imposing a hierarchy.",
            avoidWhen: "Direction or ordering carries meaning, or you need the same input to produce a tightly reproducible, grid-aligned result. Very dense graphs can turn into a hairball."),
        makeGraph: SampleGraphs.socialNetwork,
        configure: { builder, backend in
            builder.useOrganic(backend: backend) {
                $0.iterations = 600
                $0.repulsionForce = 120
                $0.attractionForce = 0.05
            }
            .removeOverlaps(backend: backend) { $0.minSpacing = 18 }
            .routePolyline(backend: backend)
            .routeSelfLoops(backend: backend)
            .clipEdgeEndpoints(backend: backend)
            .distributePorts(backend: backend)
        })

    static let tree = GraphExample(
        id: "tree", title: "Tree", category: "Layouts",
        summary: "Classic top-down tree layout of an organisation.",
        info: ExampleInfo(
            designedFor: "Rooted trees. Each node's children are placed in the level below it, and subtrees are packed tightly so siblings line up without overlapping.",
            whenToUse: "Org charts, file and folder hierarchies, taxonomies, decision trees and parse trees, where parent/child relationships are the whole story.",
            avoidWhen: "Nodes have more than one parent or the graph has cycles. Extra edges are drawn, but they ignore the tree structure and cut across it."),
        makeGraph: SampleGraphs.organisation,
        configure: { builder, backend in
            builder.useTree(backend: backend) { $0.nodeSeparation = 36; $0.levelSeparation = 72 }
                .clipEdgeEndpoints(backend: backend)
                .distributePorts(backend: backend)
        })

    static let radialTree = GraphExample(
        id: "radial-tree", title: "Radial Tree", category: "Layouts",
        summary: "Mind map placed on concentric rings around its root topic.",
        info: ExampleInfo(
            designedFor: "Trees drawn outward from a central root. Each depth gets its own ring, and each subtree gets a wedge of angle sized to its number of leaves.",
            whenToUse: "Mind maps, topic explorations and \"neighbourhood around one node\" views, or wide, shallow trees that would be too wide drawn top-down.",
            avoidWhen: "The tree is deep and narrow (the outer rings grow large and sparse), or the reader needs to compare levels side by side."),
        makeGraph: SampleGraphs.mindMap,
        configure: { builder, backend in
            builder.useRadialTree(backend: backend) { $0.spacing = 110 }
                .routePolyline(backend: backend)
                .clipEdgeEndpoints(backend: backend)
                .distributePorts(backend: backend)
        })

    static let circular = GraphExample(
        id: "circular", title: "Circular", category: "Layouts",
        summary: "Service ring with chords and a self-loop.",
        info: ExampleInfo(
            designedFor: "Placing every node on a single circle so they all get equal visual weight. Connections show up as chords across the ring.",
            whenToUse: "Ring and token topologies, round-robin or cyclic processes, small peer groups, and comparing connection density between nodes at a glance.",
            avoidWhen: "The graph is large or dense. Chords pile up in the middle, and the layout ignores hierarchy and clusters."),
        makeGraph: SampleGraphs.serviceRing,
        configure: { builder, backend in
            builder.useCircular(backend: backend) { $0.radius = 220 }
                .routePolyline(backend: backend)
                .routeSelfLoops(backend: backend)
                .clipEdgeEndpoints(backend: backend)
                .distributePorts(backend: backend)
        })

    static let orthogonalChannel = GraphExample(
        id: "orthogonal-channel", title: "Orthogonal + Channel", category: "Routing",
        summary: "Grid placement with obstacle-avoiding orthogonal channel routes.",
        info: ExampleInfo(
            designedFor: "Schematic-style drawings. Nodes snap to a grid, and edges are routed through the channels between them using only horizontal and vertical segments, with parallel edges spread across each channel.",
            whenToUse: "Circuit and block diagrams, network and infrastructure maps, and engineering or UML-style diagrams where right angles and clean, readable tracks are expected.",
            avoidWhen: "You want an organic or curved look, or the graph is very dense. Orthogonal routes add bends and can get long when channels are crowded."),
        makeGraph: SampleGraphs.circuit,
        configure: { builder, backend in
            builder.useOrthogonal(backend: backend) { $0.gridSize = 110 }
                .routeChannel(backend: backend)
                .separateEdges(backend: backend)
                .clipEdgeEndpoints(backend: backend)
                .distributePorts(backend: backend)
        })

    static let bsp = GraphExample(
        id: "bsp", title: "BSP Routing", category: "Routing",
        summary: "Hierarchical placement re-routed through binary space partition channels.",
        info: ExampleInfo(
            designedFor: "Routing edges around obstacles in a layout that's already been placed. The free space is recursively split into cells, and edges follow the gaps between nodes instead of passing through them.",
            whenToUse: "Re-routing after any placement when edges must never cross nodes, especially when nodes vary in size or the placement is irregular, as in hand-tuned layouts or groups.",
            avoidWhen: "The placement already routes its own edges well, as hierarchical layouts do, or the graph is so open that straight lines would never hit a node anyway."),
        makeGraph: SampleGraphs.circuit,
        configure: { builder, backend in
            builder.useHierarchical(backend: backend) { $0.nodeSeparation = 60; $0.layerSeparation = 90; $0.routesEdges = false }
                .routeBsp(backend: backend)
                .separateEdges(backend: backend)
                .clipEdgeEndpoints(backend: backend)
                .distributePorts(backend: backend)
        })

    static let bundling = GraphExample(
        id: "bundling", title: "Edge Bundling", category: "Routing",
        summary: "Bipartite traffic with edges bundled into shared tracks.",
        info: ExampleInfo(
            designedFor: "Reducing visual clutter. Edges that travel in similar directions attract each other and merge into shared bundles, much like cables in a loom.",
            whenToUse: "Many-to-many traffic, such as producer/consumer flows, migration or trade maps, and dense dependency graphs, where the overall flow between regions matters more than any one edge.",
            avoidWhen: "The reader needs to trace an individual edge from end to end, or the graph is sparse enough that straight edges are already clear."),
        makeGraph: SampleGraphs.bipartite,
        configure: { builder, backend in
            builder.routeWithBundling(backend: backend) { $0.k = 0.1 }
                .clipEdgeEndpoints(backend: backend)
                .distributePorts(backend: backend)
        })

    static let groupedArchitecture = GraphExample(
        id: "grouped", title: "Framed Groups", category: "Composition",
        summary: "Nested, titled groups laid out recursively with obstacle-avoiding cross-group routes.",
        info: ExampleInfo(
            designedFor: "Graphs with containment. Each group is laid out on its own, from the innermost outward, possibly with a different algorithm per group. It's then framed with padding and a title, and treated as one node at the next level up.",
            whenToUse: "Architecture diagrams, such as clients, services and storage, or modules inside packages, or any domain where boundaries such as teams, tiers or subsystems are part of the meaning.",
            avoidWhen: "The graph has no meaningful grouping, or most edges cross group boundaries. The frames then add space and detours without helping the reader."),
        makeGraph: SampleGraphs.groupedArchitecture,
        configure: { builder, backend in
            let rootLayout = HierarchicalLayoutOperation(backend: backend)
            rootLayout.configuration.nodeSeparation = 48
            rootLayout.configuration.layerSeparation = 72
            let nestedLayout = HierarchicalLayoutOperation(backend: backend)
            nestedLayout.configuration.nodeSeparation = 44
            nestedLayout.configuration.layerSeparation = 68
            let clientLayout = BasicLayoutOperation(style: .verticalStack, backend: backend)
            builder.wrapWithRecursiveGroups(rootLayout, backend: backend) { groups in
                groups.groupLayoutSelector = { group -> any AsyncLayoutAlgorithm in
                    if group.id == "Clients" { return clientLayout }
                    return nestedLayout
                }
            }
            .separateEdges(backend: backend)
            .routeSelfLoops(backend: backend)
            .clipEdgeEndpoints(backend: backend)
            .distributePorts(backend: backend)
        })

    static let swimlane = GraphExample(
        id: "swimlane", title: "Swimlanes", category: "Composition",
        summary: "Build pipeline stages assigned to vertical lanes with channel routing.",
        info: ExampleInfo(
            designedFor: "Splitting a process into lanes. Each node is assigned to a lane, such as an owner, stage or system, and edges are routed through the channels between lanes.",
            whenToUse: "Business processes and BPMN-style flows, CI/CD stages, cross-team handoffs, and any diagram where \"who or what handles this step\" matters as much as the order of steps.",
            avoidWhen: "There's no natural lane assignment, or most edges hop back and forth between distant lanes and create long horizontal runs."),
        makeGraph: SampleGraphs.buildPipeline,
        configure: { builder, backend in
            let swimlane = SwimlaneLayoutOperation(backend: backend)
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
            builder.useAsyncAlgorithm(swimlane)
                .routeChannel(backend: backend)
                .separateEdges(backend: backend)
                .clipEdgeEndpoints(backend: backend)
                .distributePorts(backend: backend)
                .placeLabels(backend: backend)
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
            info: presetInfo(pattern),
            makeGraph: SampleGraphs.groupedArchitecture,
            configure: { builder, backend in
                builder.applyPattern(pattern, backend: backend)
            })
    }

    // Each preset pairs a placement with a routing style. Every preset also lays out groups recursively.
    private static func presetInfo(_ pattern: LayoutPatternType) -> ExampleInfo {
        switch pattern {
        case .standardHierarchical:
            ExampleInfo(
                designedFor: "A general-purpose layered layout: hierarchical placement with generous spacing and layered edge routing.",
                whenToUse: "A sensible first choice for any directed graph, such as workflows, dependencies or state machines, when you don't need anything special.",
                avoidWhen: "The graph is undirected or has no natural flow. Try Standard Organic instead.")
        case .standardOrganic:
            ExampleInfo(
                designedFor: "A general-purpose force-directed layout with polyline routing and balanced spring and repulsion settings.",
                whenToUse: "A sensible first choice for undirected or loosely connected graphs, when you want the structure to emerge naturally.",
                avoidWhen: "Edge direction matters, or you need repeatable, aligned positions.")
        case .standardTree:
            ExampleInfo(
                designedFor: "A compact top-down tree with polyline routing.",
                whenToUse: "Strict hierarchies with one parent per node, such as folders, taxonomies or menus.",
                avoidWhen: "Nodes have more than one parent. Standard Hierarchical handles DAGs better.")
        case .standardCircular:
            ExampleInfo(
                designedFor: "Nodes on a ring, with each group arranged as its own smaller ring sized to fit its members.",
                whenToUse: "Small cyclic systems, ring topologies, or giving every node equal weight.",
                avoidWhen: "The graph is large or dense, so chords crowd the centre.")
        case .progressiveRefinement:
            ExampleInfo(
                designedFor: "A multi-pass layout. An organic pass finds the overall shape, barycentre passes refine the order, overlaps are removed, leaves are pulled in next to their neighbours, and components are packed together.",
                whenToUse: "Organic layouts that need to look tidier and more compact than a single force pass gives, for example messy real-world graphs.",
                avoidWhen: "Speed matters most. It runs several passes, so it costs more than Standard Organic.")
        case .hybridLayout:
            ExampleInfo(
                designedFor: "A hierarchical backbone where only the leaf nodes (degree ≤ 1) are then relaxed by a short organic pass.",
                whenToUse: "Mostly directed graphs with lots of dangling leaves, such as config items, endpoints or attachments, that would otherwise waste a whole layer.",
                avoidWhen: "The graph is purely layered (use Standard Hierarchical) or purely undirected (use Standard Organic).")
        case .enterpriseArchitecture:
            ExampleInfo(
                designedFor: "Hierarchical placement run separately on each connected component, packed at a 3:2 ratio, ranked with PageRank and routed with BSP so edges avoid nodes.",
                whenToUse: "Large system and service architecture diagrams with several independent subsystems and clear dependency direction.",
                avoidWhen: "The graph is small and fully connected. Packing components and running PageRank add work without visible benefit.")
        case .networkTopology:
            ExampleInfo(
                designedFor: "Hub-centred placement where the most connected nodes act as anchors, then organic refinement with bundled edges.",
                whenToUse: "Infrastructure and network maps, such as routers, switches and hosts, or any hub-and-spoke graph where a few nodes carry most of the traffic.",
                avoidWhen: "Connectivity is evenly spread, with no clear hubs, or you need to trace individual links. Bundling merges them.")
        case .callGraph:
            ExampleInfo(
                designedFor: "Hierarchical placement with wide layer spacing and smooth, curve-fitted edges.",
                whenToUse: "Function call graphs, module imports and other code dependency graphs, where long edges spanning several layers are common.",
                avoidWhen: "You need orthogonal, schematic-style edges. Try Data Flow or Enterprise Architecture.")
        case .socialNetwork:
            ExampleInfo(
                designedFor: "Label-propagation clustering followed by force-directed placement, with bundled edges between communities.",
                whenToUse: "Social, collaboration and citation networks, where spotting communities and the bridges between them is the goal.",
                avoidWhen: "The graph is directed with a real hierarchy, or individual edges must stay distinguishable.")
        case .organizationChart:
            ExampleInfo(
                designedFor: "A dedicated org-chart tree layout with fixed spacing between siblings and between levels.",
                whenToUse: "Reporting lines and team structures, and anything that should read like a classic org chart.",
                avoidWhen: "People report to several managers. That's a DAG, not a tree.")
        case .dataFlow:
            ExampleInfo(
                designedFor: "Widely spaced hierarchical placement with orthogonal channel routing, so edges run in clean, separated tracks.",
                whenToUse: "ETL and data pipelines, stream processing and signal-flow diagrams, where the paths between stages need to be easy to follow.",
                avoidWhen: "Space is tight. The wide spacing makes the drawing large.")
        case .mindMap:
            ExampleInfo(
                designedFor: "A radial tree that radiates out from a central topic, with polyline routing.",
                whenToUse: "Brainstorms, topic maps and exploring outward from one focus node.",
                avoidWhen: "There's no single central node, or the tree is very deep.")
        case .smallGraphPreset:
            ExampleInfo(
                designedFor: "Spacious hierarchical placement with smoothed, curve-fitted edges. It favours looks over compactness.",
                whenToUse: "Graphs with fewer than about 30 nodes, such as presentation-quality diagrams and docs illustrations.",
                avoidWhen: "The graph is large. The spacing and curve fitting don't scale well.")
        case .mediumGraphPreset:
            ExampleInfo(
                designedFor: "Hierarchical placement with moderate spacing and layered routing: a balance of readability and size.",
                whenToUse: "Directed graphs with roughly 30 to 200 nodes, which is the default for most app-sized diagrams.",
                avoidWhen: "The graph is undirected or very large. Try the Large or Dense presets.")
        case .largeGraphPreset:
            ExampleInfo(
                designedFor: "Force-directed placement with default settings and cheap polyline routing, chosen to scale.",
                whenToUse: "Graphs with hundreds of nodes or more, where a layered layout would become extremely wide or slow.",
                avoidWhen: "Direction or exact alignment matters and the graph is small enough for a hierarchical layout.")
        case .denseGraphPreset:
            ExampleInfo(
                designedFor: "Force-directed placement with tightly bundled edges to tame high edge counts.",
                whenToUse: "Graphs with many more edges than nodes, where unbundled edges would turn into a hairball.",
                avoidWhen: "The graph is sparse, or each edge must be traceable on its own.")
        }
    }

    static let all: [GraphExample] = [
        hierarchical, organic, tree, radialTree, circular,
        orthogonalChannel, bsp, bundling,
        groupedArchitecture, swimlane,
    ] + presets
}
