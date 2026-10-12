import Foundation
import SwiftGraph

/// Visual coverage of the backend inventory, separate from organic quality stress cases.
/// Every case must submit real GPU work; CPU preparation/finishing is recorded explicitly.
enum MetalVisualCatalogue {
    static func verified(_ drawing: VisualDrawing, records: [LayoutExecutionMetrics], executor: LayoutExecutor) async throws -> VisualDrawing {
        let statistics = await executor.statistics()
        guard records.contains(where: { $0.backend == .metal && !$0.metalStages.isEmpty }),
              statistics.submittedBatches > 0, statistics.submittedBatches == statistics.completedBatches,
              records.allSatisfy({ $0.requestedBackend == .metal }) else {
            throw EvaluationError.message("Metal gallery case did not complete substantive Metal work")
        }
        var result = drawing
        result.reportedMetrics["metal.submittedBatches"] = Double(statistics.submittedBatches)
        result.reportedMetrics["metal.completedBatches"] = Double(statistics.completedBatches)
        result.reportedMetrics["metal.executedStages"] = Double(records.filter { $0.backend == .metal }.count)
        result.notes.append("Metal stages: " + Set(records.flatMap(\.metalStages)).sorted().joined(separator: "; "))
        result.notes.append("CPU stages: " + Set(records.flatMap(\.cpuStages)).sorted().joined(separator: "; "))
        return result
    }

    static func layouts() -> [VisualCase] {
        VisualCatalogue.layouts().map { spec in
            VisualCase(id: "metal-layout-\(spec.id)", family: "metal-\(spec.family)", title: "Metal \(spec.id) · mixed sizes",
                configuration: ["backend": "metal", "layout": spec.id, "input": spec.shape,
                    "pipeline": "Metal operation → CPU presentation routing where needed, self-loops and clipping"],
                contracts: VisualContracts(noNodeOverlaps: ["remove-overlaps", "tabular", "circular", "orthogonal", "radial", "radial-tree", "radial-star", "subgraph"].contains(spec.id),
                    noObstacleIntersections: ["radial", "radial-tree", "radial-star", "subgraph"].contains(spec.id)), metal: true) {
                let executor = LayoutExecutor()
                let g = spec.shape == "groups" ? VisualGraphs.groups(edges: spec.id != "tree-map") : VisualGraphs.graph(shape: spec.shape)
                if spec.id == "clear-area" { for n in g.nodes { n.x *= 0.5; n.y *= 0.5; n.width *= 0.5; n.height *= 0.5 } }
                if spec.id == "remove-overlaps" { for n in g.nodes { n.x *= 0.2; n.y *= 0.2 } }
                if spec.id == "barycenter" { g.nodes[0].metadata[GraphMetadataKeys.fixed] = true }
                var drawing = VisualDrawing(graph: g)
                if spec.id == "clear-area" { drawing.notes.append("The CPU catalogue input and clear rectangle are scaled by one half to fit the default Metal precision allowance.") }
                if spec.id == "barycenter" { drawing.fixedCenters[g.nodes[0].id] = g.nodes[0].center }
                if spec.id == "alignment" || spec.id == "subgraph" { PolylineEdgeRouter().routeEdges(g) }
                if spec.id == "subgraph" { for n in g.nodes.dropFirst(6) { drawing.fixedCenters[n.id] = n.center } }
                let operation = try layout(spec.id, executor: executor)
                try await operation.applyLayoutAsync(g)
                VisualGraphs.finish(g, route: spec.routeAfter)
                drawing.notes.append("Presentation finishing on CPU: \(spec.routeAfter ? "polyline routing, " : "")self-loops and endpoint clipping.")
                return try await verified(drawing, records: operation.lastExecutionMetrics, executor: executor)
            }
        }
    }

    private static func layout(_ id: String, executor: LayoutExecutor) throws -> any LayoutExecutionReporting {
        let basic: [String: BasicLayoutStyle] = ["circular": .circular, "tabular": .tabular, "orthogonal": .orthogonal,
            "partition-grid": .partitionGrid, "kandinsky": .kandinsky, "vertical-stack": .verticalStack,
            "alignment": .alignment, "fill-area": .fillArea, "clear-area": .clearArea,
            "compact-disk": .compactDisk, "remove-overlaps": .removeOverlaps]
        if let style = basic[id] {
            let op = BasicLayoutOperation(style: style, backend: .metal, executor: executor)
            if style == .partitionGrid { for i in 0..<12 { op.configuration.cellAssignment["n\(i)"] = GridCell(row: i / 4, column: i % 4) } }
            if style == .alignment { op.configuration.horizontalAlignment = .snapToGrid; op.configuration.verticalAlignment = .snapToGrid }
            if style == .fillArea { op.configuration.area = Rect(x: -100, y: -100, width: 900, height: 650) }
            if style == .clearArea { op.configuration.area = Rect(x: 0, y: 0, width: 200, height: 150) }
            return op
        }
        let trees: [String: TreeLayoutStyle] = ["tree": .tree, "balloon": .balloon, "org-chart": .orgChart, "tree-map": .treeMap]
        if let style = trees[id] { return TreeLayoutOperation(style: style, backend: .metal, executor: executor) }
        switch id {
        case "hierarchical": return HierarchicalLayoutOperation(backend: .metal, executor: executor)
        case "series-parallel": return SeriesParallelLayoutOperation(backend: .metal, executor: executor)
        case "organic": return OrganicLayoutOperation(backend: .metal, executor: executor)
        case "barycenter": return BarycenterLayoutOperation(backend: .metal, executor: executor)
        case "radial", "radial-star", "radial-tree":
            return RadialLayoutOperation(style: id == "radial" ? .radial : id == "radial-star" ? .star : .tree, backend: .metal, executor: executor)
        case "given-coordinates": return RoutingLayoutOperation(.givenCoordinates, backend: .metal, executor: executor)
        case "swimlane":
            let op = SwimlaneLayoutOperation(backend: .metal, executor: executor)
            for i in 0..<12 { op.laneAssignment["n\(i)"] = i % 3 }; return op
        case "components": return ComponentLayoutOperation(HierarchicalLayoutOperation(backend: .metal, executor: executor), backend: .metal, executor: executor)
        case "multi-page":
            let op = MultiPageLayoutOperation(backend: .metal, executor: executor)
            op.pageWidth = 450; op.pageHeight = 400; return op
        case "recursive-groups": return RecursiveGroupLayoutOperation(HierarchicalLayoutOperation(backend: .metal, executor: executor), backend: .metal, executor: executor)
        case "subgraph":
            let op = SubgraphLayoutOperation(BasicLayoutOperation(style: .circular, backend: .metal, executor: executor), backend: .metal, executor: executor)
            op.selectedNodeIds = Set((0..<6).map { "n\($0)" }); return op
        default: throw EvaluationError.message("Missing Metal visual layout: \(id)")
        }
    }

    static func routing() -> [VisualCase] {
        RoutingKind.allCases.map { kind in
            VisualCase(id: "metal-router-\(kind.rawValue)", family: "metal-routing", title: "Metal \(kind.rawValue) · ports and obstacles",
                configuration: ["backend": "metal", "router": kind.rawValue,
                    "pipeline": "prepared input paths → selected Metal routing operation; output paths are not replaced"],
                contracts: VisualContracts(noNodeOverlaps: true), metal: true) {
                let executor = LayoutExecutor(), g = routingGraph(labels: kind == .labelPlacement || kind == .labelLayout)
                let operation = RoutingLayoutOperation(kind, backend: .metal, executor: executor)
                try await operation.applyLayoutAsync(g)
                return try await verified(VisualDrawing(graph: g, fallbackEdges: operation.unroutableEdgeIndices,
                    notes: ["Styling and finishing operations preserve input paths where their CPU contracts require it. Obstacle intersections are advisory unless the router guarantees clearance."]),
                    records: operation.lastExecutionMetrics, executor: executor)
            }
        }
    }

    private static func routingGraph(labels: Bool) -> LayoutGraph {
        let g = LayoutGraph()
        for (i, p) in [Point(x: 0, y: 0), Point(x: 300, y: 0), Point(x: 0, y: 180), Point(x: 300, y: 180), Point(x: 145, y: 20)].enumerated() {
            let node = LayoutNode(id: "n\(i)", width: i == 4 ? 35 : 30, height: 24)
            node.center = p; g.addNode(node)
        }
        for (i, pair) in [(0, 1), (1, 0), (0, 1), (0, 2), (0, 3), (2, 3), (1, 3), (0, 0), (0, 0)].enumerated() {
            let e = LayoutEdge(source: g.nodes[pair.0], target: g.nodes[pair.1])
            e.path = [e.source.center, Point(x: 80, y: -60), Point(x: 200, y: -60), e.target.center]
            if labels { e.data = "Label \(i)"; e.labelBounds = Rect(x: 0, y: 0, width: 45, height: 20) }
            if i == 3 { e.sourcePort = .bottom; e.targetPort = .top }
            if i == 4 { e.sourcePortCandidates = [.right, .bottom]; e.targetPortCandidates = [.left, .top] }
            g.addEdge(e)
        }
        return g
    }

    static func directed() -> [VisualCase] {
        [("fresh", DirectedLayoutMode.fresh), ("incremental", .incremental), ("routes-only", .routesOnly)].map { name, mode in
            VisualCase(id: "metal-directed-\(name)", family: "metal-directed", title: "Metal directed · \(name)",
                configuration: ["backend": "metal", "mode": name, "pipeline": "prepared coordinates → directed operation"], metal: true) {
                let executor = LayoutExecutor(), g = VisualGraphs.graph(12, shape: "tree")
                var config = DirectedLayoutConfiguration(); config.mode = mode
                var drawing = VisualDrawing(graph: g)
                if mode != .fresh {
                    try HierarchicalLayoutAlgorithm().applyLayout(g)
                    config.previousBounds = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.bounds) })
                    drawing.previousBounds = config.previousBounds
                    config.previousPaths = Dictionary(uniqueKeysWithValues: g.edges.enumerated().map { ($0.offset, $0.element.path) })
                    if mode == .incremental {
                        config.fixedNodeIDs = [g.nodes[0].id]; drawing.fixedCenters[g.nodes[0].id] = g.nodes[0].center
                        config.previousBounds.removeValue(forKey: g.nodes.last!.id)
                    } else { for n in g.nodes { drawing.fixedCenters[n.id] = n.center } }
                    drawing.notes.append("Initial hierarchy prepared on CPU; Metal handles the selected directed update.")
                }
                let op = DirectedLayoutAsyncOperation(backend: .metal, executor: executor, configuration: config)
                try await op.applyLayoutAsync(g)
                drawing.fallbackEdges = op.lastDiagnostics?.unroutableEdges ?? []
                return try await verified(drawing, records: op.lastExecutionMetrics, executor: executor)
            }
        }
    }

    static func presets() -> [VisualCase] {
        LayoutPatternType.allCases.map { pattern in
            VisualCase(id: "metal-preset-\(pattern.rawValue)", family: "metal-preset", title: "Metal preset · \(pattern.rawValue)",
                configuration: ["backend": "metal", "pattern": pattern.rawValue, "pipeline": "backend-aware preset → Metal endpoint clipping"], metal: true) {
                let executor = LayoutExecutor(), g = VisualGraphs.graph(12, shape: "cyclic")
                let builder = LayoutBuilder.create(g).applyPattern(pattern, backend: .metal, executor: executor)
                    .clipEdgeEndpoints(backend: .metal, executor: executor)
                try await builder.applyAsync()
                return try await verified(VisualDrawing(graph: g), records: builder.lastExecutionMetrics, executor: executor)
            }
        }
    }

    static func analysis() -> [VisualCase] {
        [AnalysisKind.pageRank, .clusters].map { kind in
            let rank = kind == .pageRank, name = rank ? "pageRank" : "clusters"
            return VisualCase(id: "metal-analysis-\(name)", family: "metal-analysis", title: "Metal analysis · \(name)",
                configuration: ["backend": "metal", "analysis": name, "pipeline": "CPU display hierarchy → Metal analysis → values in node labels"], metal: true) {
                let executor = LayoutExecutor(), g = VisualGraphs.graph(12, shape: "disconnected")
                try HierarchicalLayoutAlgorithm().applyLayout(g)
                let op = AnalysisLayoutOperation(kind, backend: .metal, executor: executor)
                try await op.applyLayoutAsync(g)
                for n in g.nodes {
                    if rank { n.name = "\(n.id): \(String(format: "%.3f", n.metadata[GraphMetadataKeys.pageRank] as? Double ?? 0))" }
                    else { n.name = "\(n.id): cluster \(n.metadata[GraphMetadataKeys.cluster] as? Int ?? -1)" }
                }
                VisualGraphs.finish(g)
                return try await verified(VisualDrawing(graph: g, notes: ["Analysis changes metadata; hierarchy and clipping are CPU presentation steps."]), records: op.lastExecutionMetrics, executor: executor)
            }
        }
    }

    static func analysisComposition() -> [VisualCase] {
        [false, true].map { cluster in
            let name = cluster ? "cluster" : "importance"
            return VisualCase(id: "metal-composition-\(name)", family: "metal-composition", title: "Metal \(name) composition",
                configuration: ["backend": "metal", "pipeline": "Metal analysis → Metal hierarchy per group → CPU packing, final routing and clipping"], metal: true) {
                let executor = LayoutExecutor(), g = VisualGraphs.graph(12, shape: "disconnected")
                let core = HierarchicalLayoutOperation(backend: .metal, executor: executor)
                let op: any LayoutExecutionReporting = cluster ? ClusterLayoutOperation(core, backend: .metal, executor: executor) : ImportanceLayoutOperation(core, backend: .metal, executor: executor)
                try await op.applyLayoutAsync(g); VisualGraphs.finish(g, route: true)
                return try await verified(VisualDrawing(graph: g, notes: ["Polyline routing connects inter-cluster edges; self-loop routing and endpoint clipping finish the presentation on CPU."]), records: op.lastExecutionMetrics, executor: executor)
            }
        }
    }

    static func all() -> [VisualCase] { layouts() + routing() + directed() + presets() + analysis() + analysisComposition() }
}
