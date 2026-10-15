import Foundation
import SwiftGraph

/// A unified diagram case capable of executing identically structured workloads across
/// `.cpu`, `.metal`, and `.automatic` backends while capturing both resulting geometry
/// (`VisualDrawing`) and per-stage execution telemetry (`[LayoutExecutionMetrics]`).
public struct ComparativeDiagramCase {
    public var id: String
    public var family: String
    public var title: String
    public var configuration: [String: String]
    var contracts: VisualContracts
    public var smoke: Bool
    var runBackend: (LayoutBackend, LayoutExecutor) async throws -> (VisualDrawing, [LayoutExecutionMetrics])

    func visualCase(for backend: LayoutBackend, executor: LayoutExecutor) -> VisualCase {
        var config = configuration
        config["backend"] = backend.rawValue
        return VisualCase(
            id: id,
            family: family,
            title: title,
            configuration: config,
            contracts: contracts,
            smoke: smoke,
            metal: backend == .metal
        ) {
            try await runWithPrecisionFallbackIfNeeded(backend: backend, executor: executor).0
        }
    }

    func runWithPrecisionFallbackIfNeeded(
        backend: LayoutBackend,
        executor: LayoutExecutor
    ) async throws -> (VisualDrawing, [LayoutExecutionMetrics], Bool) {
        do {
            let (drawing, metrics) = try await runBackend(backend, executor)
            return (drawing, metrics, false)
        } catch LayoutExecutionError.precisionLimit where backend == .metal {
            var relaxedOptions = await executor.options
            relaxedOptions.maximumCoordinateError = max(relaxedOptions.maximumCoordinateError, 1.0)
            let relaxedExecutor = LayoutExecutor(options: relaxedOptions)
            var (drawing, metrics) = try await runBackend(.metal, relaxedExecutor)
            drawing.notes.append("Default Metal maximumCoordinateError (0.01) rejected this coordinate span; executed with relaxed tolerance (1.0) for comparative analysis.")
            return (drawing, metrics, true)
        }
    }
}

/// Catalogue of all 107 diagram cases across all 7 families configured for head-to-head
/// CPU vs Metal vs Automatic comparative benchmarking and visual parity analysis.
public enum BackendComparativeCatalogue {
    public static let familyOrder: [String] = [
        "layouts",
        "presets",
        "routing",
        "directed",
        "organic-quality",
        "frames",
        "engineering"
    ]

    public static func all(includePerformance1024: Bool = true) -> [ComparativeDiagramCase] {
        var cases: [ComparativeDiagramCase] = []
        cases += layoutCases()
        cases += presetCases()
        cases += routingAndLabelCases()
        cases += directedCases()
        cases += organicQualityCases(includePerformance1024: includePerformance1024)
        cases += framedGroupCases()
        cases += softwareEngineeringCases()
        return cases
    }

    public static func smoke() -> [ComparativeDiagramCase] {
        all(includePerformance1024: false).filter(\.smoke)
    }

    public static func selected(suite: String = "full", ids: [String] = []) throws -> [ComparativeDiagramCase] {
        let allComparative = all()
        if !ids.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: allComparative.map { ($0.id, $0) })
            let unknown = ids.filter { byID[$0] == nil }
            guard unknown.isEmpty else {
                throw EvaluationError.message("Unknown comparative cases: \(unknown.joined(separator: ", "))")
            }
            return ids.compactMap { byID[$0] }
        }
        switch suite {
        case "full":
            return allComparative
        case "smoke":
            return smoke()
        case "engineering", "frames", "layouts", "presets", "routing", "directed", "organic-quality":
            return allComparative.filter { $0.family == suite }
        default:
            throw EvaluationError.message("Unknown benchmark suite: \(suite)")
        }
    }

    // MARK: - 1. Core Layouts (28 cases)

    public static func layoutCases() -> [ComparativeDiagramCase] {
        VisualCatalogue.layouts().map { spec in
            let caseID = "layout-\(spec.id)"
            var contracts = VisualContracts()
            if ["remove-overlaps", "tabular", "circular", "orthogonal", "radial", "radial-tree", "radial-star", "subgraph"].contains(spec.id) {
                contracts.noNodeOverlaps = true
            }
            if ["radial", "radial-tree", "radial-star", "subgraph"].contains(spec.id) {
                contracts.noObstacleIntersections = true
            }
            let isSmoke = ["hierarchical", "recursive-groups", "tree-map", "organic"].contains(spec.id)
            return ComparativeDiagramCase(
                id: caseID,
                family: "layouts",
                title: "\(spec.id) · mixed sizes",
                configuration: [
                    "layout": spec.id,
                    "subfamily": spec.family,
                    "input": spec.shape,
                    "nodes": "12 (8 leaves for groups)",
                    "pipeline": spec.id == "subgraph"
                        ? "obstacle-aware input routes → subgraph → self-loops → clip"
                        : "layout → \(spec.routeAfter ? "polyline → " : "")self-loops → clip"
                ],
                contracts: contracts,
                smoke: isSmoke
            ) { backend, executor in
                let g = spec.shape == "groups"
                    ? VisualGraphs.groups(edges: spec.id != "tree-map")
                    : VisualGraphs.graph(shape: spec.shape)
                if spec.id == "remove-overlaps" {
                    for n in g.nodes { n.x *= 0.2; n.y *= 0.2 }
                }
                if spec.id == "barycenter" {
                    g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
                }
                if spec.id == "alignment" {
                    PolylineEdgeRouter().routeEdges(g)
                }
                var drawing = VisualDrawing(graph: g)
                if spec.id == "barycenter" {
                    drawing.fixedCenters[g.nodes[0].id] = g.nodes[0].center
                }
                if spec.id == "subgraph" {
                    PolylineEdgeRouter().routeEdges(g)
                    for n in g.nodes.dropFirst(6) {
                        drawing.fixedCenters[n.id] = n.center
                    }
                }
                let operation = try makeLayoutOperation(spec.id, backend: backend, executor: executor)
                try await operation.applyLayoutAsync(g)
                VisualGraphs.finish(g, route: spec.routeAfter)
                return (drawing, operation.lastExecutionMetrics)
            }
        }
    }

    private static func makeLayoutOperation(
        _ id: String,
        backend: LayoutBackend,
        executor: LayoutExecutor
    ) throws -> any LayoutExecutionReporting {
        let basic: [String: BasicLayoutStyle] = [
            "circular": .circular,
            "tabular": .tabular,
            "orthogonal": .orthogonal,
            "partition-grid": .partitionGrid,
            "kandinsky": .kandinsky,
            "vertical-stack": .verticalStack,
            "alignment": .alignment,
            "fill-area": .fillArea,
            "clear-area": .clearArea,
            "compact-disk": .compactDisk,
            "remove-overlaps": .removeOverlaps
        ]
        if let style = basic[id] {
            let op = BasicLayoutOperation(style: style, backend: backend, executor: executor)
            if style == .partitionGrid {
                for i in 0..<12 {
                    op.configuration.cellAssignment["n\(i)"] = GridCell(row: i / 4, column: i % 4)
                }
            }
            if style == .alignment {
                op.configuration.horizontalAlignment = .snapToGrid
                op.configuration.verticalAlignment = .snapToGrid
            }
            if style == .fillArea {
                op.configuration.area = Rect(x: -100, y: -100, width: 900, height: 650)
            }
            if style == .clearArea {
                op.configuration.area = Rect(x: 0, y: 0, width: 400, height: 300)
            }
            return op
        }
        let trees: [String: TreeLayoutStyle] = [
            "tree": .tree,
            "balloon": .balloon,
            "org-chart": .orgChart,
            "tree-map": .treeMap
        ]
        if let style = trees[id] {
            return TreeLayoutOperation(style: style, backend: backend, executor: executor)
        }
        switch id {
        case "hierarchical":
            return HierarchicalLayoutOperation(backend: backend, executor: executor)
        case "series-parallel":
            return SeriesParallelLayoutOperation(backend: backend, executor: executor)
        case "organic":
            return OrganicLayoutOperation(backend: backend, executor: executor)
        case "barycenter":
            return BarycenterLayoutOperation(backend: backend, executor: executor)
        case "radial", "radial-star", "radial-tree":
            let style: RadialLayoutStyle = id == "radial" ? .radial : id == "radial-star" ? .star : .tree
            return RadialLayoutOperation(style: style, backend: backend, executor: executor)
        case "given-coordinates":
            return RoutingLayoutOperation(.givenCoordinates, backend: backend, executor: executor)
        case "swimlane":
            let op = SwimlaneLayoutOperation(backend: backend, executor: executor)
            for i in 0..<12 { op.laneAssignment["n\(i)"] = i % 3 }
            return op
        case "components":
            return ComponentLayoutOperation(
                HierarchicalLayoutOperation(backend: backend, executor: executor),
                backend: backend,
                executor: executor
            )
        case "multi-page":
            let op = MultiPageLayoutOperation(backend: backend, executor: executor)
            op.pageWidth = 450
            op.pageHeight = 400
            return op
        case "recursive-groups":
            return RecursiveGroupLayoutOperation(
                HierarchicalLayoutOperation(backend: backend, executor: executor),
                backend: backend,
                executor: executor
            )
        case "subgraph":
            let op = SubgraphLayoutOperation(
                BasicLayoutOperation(style: .circular, backend: backend, executor: executor),
                backend: backend,
                executor: executor
            )
            op.selectedNodeIds = Set((0..<6).map { "n\($0)" })
            return op
        default:
            throw EvaluationError.message("Unknown layout operation id: \(id)")
        }
    }

    // MARK: - 2. Presets (17 cases)

    public static func presetCases() -> [ComparativeDiagramCase] {
        LayoutPatternType.allCases.map { pattern in
            let noOverlaps: [LayoutPatternType] = [
                .mindMap, .standardOrganic, .largeGraphPreset, .denseGraphPreset,
                .socialNetwork, .networkTopology, .progressiveRefinement
            ]
            let noIntersections: [LayoutPatternType] = [
                .standardTree, .organizationChart, .hybridLayout, .mindMap,
                .standardOrganic, .largeGraphPreset, .progressiveRefinement
            ]
            return ComparativeDiagramCase(
                id: "preset-\(pattern.rawValue)",
                family: "presets",
                title: "Preset · \(pattern.rawValue)",
                configuration: [
                    "pattern": pattern.rawValue,
                    "input": "12 cyclic, mixed sizes",
                    "pipeline": "preset (backend-aware pipeline)"
                ],
                contracts: VisualContracts(
                    noNodeOverlaps: noOverlaps.contains(pattern),
                    noObstacleIntersections: noIntersections.contains(pattern)
                ),
                smoke: pattern == .standardHierarchical || pattern == .enterpriseArchitecture
            ) { backend, executor in
                let g = VisualGraphs.graph(shape: "cyclic")
                let builder = LayoutBuilder.create(g).applyPattern(pattern, backend: backend, executor: executor)
                try await builder.applyAsync()
                return (VisualDrawing(graph: g), builder.lastExecutionMetrics)
            }
        }
    }

    // MARK: - 3. Routing & Labels (12 cases: 10 routers + 2 label algorithms)

    public static func routingAndLabelCases() -> [ComparativeDiagramCase] {
        let routerCases: [ComparativeDiagramCase] = VisualCatalogue.routerNames.map { name in
            let input = [
                "curve-fitting": "hierarchical bends",
                "octilinear": "diagonal tree edges",
                "bundling": "parallel traffic",
                "bus": "fan-in and fan-out"
            ][name] ?? "obstacle, ports and reciprocal edges"
            return ComparativeDiagramCase(
                id: "router-\(name)",
                family: "routing",
                title: "\(name) · \(input)",
                configuration: [
                    "router": name,
                    "input": input,
                    "pipeline": "router → self-loops → clip"
                ],
                contracts: VisualContracts(
                    noNodeOverlaps: true,
                    noObstacleIntersections: name == "channel",
                    orthogonal: name == "channel"
                ),
                smoke: name == "channel" || name == "polyline"
            ) { backend, executor in
                let g = try VisualGraphs.routing(name)
                if name == "bundling" {
                    let op = EdgeBundlingOperation(backend: backend, executor: executor)
                    try await op.applyLayoutAsync(g)
                    VisualGraphs.finish(g)
                    return (
                        VisualDrawing(
                            graph: g,
                            notes: ["Only channel interprets ports. Styling routers do not guarantee obstacle clearance."]
                        ),
                        op.lastExecutionMetrics
                    )
                } else {
                    let kind = try routingKind(for: name)
                    let op = RoutingLayoutOperation(kind, backend: backend, executor: executor)
                    try await op.applyLayoutAsync(g)
                    let failures = op.unroutableEdgeIndices
                    VisualGraphs.finish(g)
                    return (
                        VisualDrawing(
                            graph: g,
                            fallbackEdges: failures,
                            notes: ["Only channel interprets ports. Styling routers do not guarantee obstacle clearance."]
                        ),
                        op.lastExecutionMetrics
                    )
                }
            }
        }

        let labelCases: [ComparativeDiagramCase] = ["placement", "layout"].map { kind in
            ComparativeDiagramCase(
                id: "labels-\(kind)",
                family: "routing",
                title: "Edge label \(kind)",
                configuration: ["pipeline": "hierarchical → clip → labels-\(kind)"],
                contracts: VisualContracts(noLabelOverlaps: true),
                smoke: kind == "placement"
            ) { backend, executor in
                let g = VisualGraphs.graph(6)
                try HierarchicalLayoutAlgorithm().applyLayout(g)
                VisualGraphs.finish(g)
                for (i, e) in g.edges.enumerated() {
                    e.data = "edge \(i) <&>"
                    e.labelBounds = Rect(width: 104, height: 22)
                }
                let routingKind: RoutingKind = kind == "placement" ? .labelPlacement : .labelLayout
                let op = RoutingLayoutOperation(routingKind, backend: backend, executor: executor)
                try await op.applyLayoutAsync(g)
                return (VisualDrawing(graph: g), op.lastExecutionMetrics)
            }
        }

        return routerCases + labelCases
    }

    private static func routingKind(for name: String) throws -> RoutingKind {
        switch name {
        case "polyline": return .polyline
        case "channel": return .channel
        case "bsp": return .bsp
        case "grouped": return .orthogonalGrouped
        case "bus": return .bus
        case "octilinear": return .octilinear
        case "parallel": return .parallelEdges
        case "curve-fitting": return .curveFitting
        case "self-loop": return .selfLoops
        default: throw EvaluationError.message("Unsupported routing kind for name: \(name)")
        }
    }

    // MARK: - 4. Directed Modes (7 cases)

    public static func directedCases() -> [ComparativeDiagramCase] {
        ["fresh", "incremental", "routes-only", "fixed-conflict", "high-degree", "disconnected", "long-edges"].map { mode in
            ComparativeDiagramCase(
                id: "directed-\(mode)",
                family: "directed",
                title: "Directed · \(mode)",
                configuration: [
                    "mode": mode,
                    "options": "catalogue-v1 defaults",
                    "pipeline": "DirectedLayoutAsyncOperation; exact returned geometry"
                ],
                contracts: VisualContracts(
                    routesRequired: mode != "fixed-conflict",
                    noNodeOverlaps: mode != "fixed-conflict",
                    noObstacleIntersections: mode != "fixed-conflict",
                    orthogonal: true,
                    expectMissingRoutes: mode == "fixed-conflict"
                ),
                smoke: ["fresh", "incremental"].contains(mode)
            ) { backend, executor in
                let count = mode == "high-degree" ? 20 : 8
                let shape = mode == "high-degree" ? "star" : mode == "disconnected" ? "disconnected" : "cyclic"
                let g = VisualGraphs.graph(count, shape: shape)
                var c = DirectedLayoutConfiguration()
                var drawing = VisualDrawing(graph: g)
                if mode == "long-edges" {
                    g.addEdge(LayoutEdge(source: g.nodes[0], target: g.nodes[6]))
                }
                if mode == "high-degree" {
                    c.edgeWidths = g.edges.map { _ in Float(3) }
                    drawing.edgeWidths = c.edgeWidths
                }
                if ["incremental", "routes-only", "fixed-conflict"].contains(mode) {
                    try DirectedLayoutOperation().apply(g)
                    c.previousBounds = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.bounds) })
                    c.previousPaths = Dictionary(uniqueKeysWithValues: g.edges.enumerated().map { ($0.offset, $0.element.path) })
                    drawing.previousBounds = c.previousBounds
                    drawing.fixedCenters = c.previousBounds.mapValues(\.center)
                    c.mode = mode == "incremental" ? .incremental : .routesOnly
                    if mode == "incremental" {
                        let n = LayoutNode(id: "inserted", width: 200, height: 40)
                        g.addNode(n)
                        g.addEdge(LayoutEdge(source: g.nodes[0], target: n))
                        c.insertionOrigins[n.id] = g.nodes[2].center
                    }
                    if mode == "fixed-conflict" {
                        c.previousBounds[g.nodes[1].id] = c.previousBounds[g.nodes[0].id]
                        c.fixedNodeIDs = [g.nodes[0].id, g.nodes[1].id]
                        drawing.fixedCenters = c.previousBounds.mapValues(\.center)
                    }
                }
                let op = DirectedLayoutAsyncOperation(backend: backend, executor: executor, configuration: c)
                try await op.applyLayoutAsync(g)
                if let d = op.lastDiagnostics {
                    drawing.reportedMetrics = [
                        "crossings": Double(d.crossings),
                        "sharedRuns": Double(d.sharedRuns),
                        "bends": Double(d.bends),
                        "routeLength": Double(d.routeLength),
                        "displacement": Double(d.displacement),
                        "unroutableEdges": Double(d.unroutableEdges.count),
                        "fixedConflicts": Double(d.fixedNodeConflicts.count)
                    ]
                    if mode == "fixed-conflict" && d.fixedNodeConflicts.isEmpty {
                        drawing.additionalFailures.append(.init(kind: "expected-fixed-conflict", elements: []))
                    }
                }
                if mode == "fixed-conflict" {
                    drawing.notes = ["Intentional impossible fixed constraints: missing routes and overlapping nodes are expected, and must be diagnosed."]
                }
                return (drawing, op.lastExecutionMetrics)
            }
        }
    }

    // MARK: - 5. Organic Quality & Scope Cases (18 cases)

    public static func organicQualityCases(includePerformance1024: Bool = true) -> [ComparativeDiagramCase] {
        let specs: [(String, Int, String)] = [
            ("64", 64, "dense"),
            ("256", 256, "dense"),
            ("chain", 32, "chain"),
            ("star", 32, "star"),
            ("tree", 32, "tree"),
            ("grid", 36, "grid"),
            ("clusters", 32, "clusters"),
            ("disconnected", 32, "disconnected"),
            ("coincident", 32, "dense"),
            ("pins", 32, "dense"),
            ("subset", 32, "dense"),
            ("threshold-63", 63, "tree"),
            ("threshold-64", 64, "tree"),
            ("threshold-65", 65, "tree"),
            ("groups", 8, "groups"),
            ("performance-1024", 1024, "dense")
        ]
        let filtered = includePerformance1024 ? specs : specs.filter { $0.0 != "performance-1024" }
        let qualityCases: [ComparativeDiagramCase] = filtered.map { name, count, shape in
            ComparativeDiagramCase(
                id: "organic-quality-\(name)",
                family: "organic-quality",
                title: "Organic quality · \(name)",
                configuration: [
                    "input": shape,
                    "nodes": String(count),
                    "iterations": "600 per candidate",
                    "pipeline": "quality organic → obstacle-aware polyline → clip"
                ],
                contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true),
                smoke: name == "64" || name == "threshold-64"
            ) { backend, executor in
                let g = shape == "groups" ? VisualGraphs.groups() : VisualGraphs.graph(count, shape: shape)
                if shape == "grid" {
                    g.edges = []
                    for i in 0..<count {
                        if i % 6 < 5 { g.addEdge(LayoutEdge(source: g.nodes[i], target: g.nodes[i + 1])) }
                        if i + 6 < count { g.addEdge(LayoutEdge(source: g.nodes[i], target: g.nodes[i + 6])) }
                    }
                }
                if shape == "clusters" {
                    g.edges = []
                    for i in 0..<count {
                        for j in (i + 1)..<count where i / 8 == j / 8 {
                            g.addEdge(LayoutEdge(source: g.nodes[i], target: g.nodes[j]))
                        }
                    }
                    for i in [7, 15, 23] { g.addEdge(LayoutEdge(source: g.nodes[i], target: g.nodes[i + 1])) }
                }
                var config = OrganicLayoutConfiguration()
                if name == "coincident" {
                    for n in g.nodes { n.x = 0; n.y = 0 }
                }
                if name == "pins" {
                    for n in g.nodes.prefix(2) { n.metadata[GraphMetadataKeys.fixed] = true }
                }
                if name == "subset" {
                    config.scope = .subset
                    for n in g.nodes.suffix(count / 2) { n.metadata[GraphMetadataKeys.layoutSubset] = true }
                }
                var drawing = VisualDrawing(graph: g)
                for n in g.nodes where n.metadata[GraphMetadataKeys.fixed] as? Bool == true || (config.scope == .subset && n.metadata[GraphMetadataKeys.layoutSubset] as? Bool != true) {
                    drawing.fixedCenters[n.id] = n.center
                }

                let metrics: [LayoutExecutionMetrics]
                let diagnostics: OrganicLayoutDiagnostics?
                if shape == "groups" {
                    let core = OrganicLayoutOperation(backend: backend, executor: executor, configuration: config)
                    let groupOp = RecursiveGroupLayoutOperation(core, backend: backend, executor: executor)
                    try await groupOp.applyLayoutAsync(g)
                    metrics = groupOp.lastExecutionMetrics
                    diagnostics = core.lastDiagnostics
                } else {
                    let op = OrganicLayoutOperation(backend: backend, executor: executor, configuration: config)
                    try await op.applyLayoutAsync(g)
                    metrics = op.lastExecutionMetrics
                    diagnostics = op.lastDiagnostics
                }
                if let d = diagnostics {
                    drawing.reportedMetrics = [
                        "placement.clearanceViolations": Double(d.final.clearanceViolations),
                        "placement.edgeNodeIntersections": Double(d.final.edgeNodeIntersections),
                        "placement.crossings": Double(d.final.crossings),
                        "placement.edgeLength": Double(d.final.edgeLength),
                        "placement.area": Double(d.final.drawingArea),
                        "candidates": Double(d.candidateCount),
                        "selectedCandidate": Double(d.selectedCandidate),
                        "solverIterations": Double(d.solverIterations)
                    ]
                }
                let router = PolylineEdgeRouter()
                router.routeEdges(g)
                drawing.fallbackEdges = g.edges.indices.filter { i in router.unroutableEdges.contains { $0 === g.edges[i] } }
                VisualGraphs.finish(g)
                return (drawing, metrics)
            }
        }

        let scopeCases: [ComparativeDiagramCase] = ["pinned", "subset"].map { mode in
            ComparativeDiagramCase(
                id: "organic-\(mode)",
                family: "organic-quality",
                title: "Organic · \(mode)",
                configuration: ["scope": mode, "iterations": "100"],
                contracts: VisualContracts(),
                smoke: false
            ) { backend, executor in
                let g = VisualGraphs.graph()
                var config = OrganicLayoutConfiguration()
                var drawing = VisualDrawing(graph: g)
                g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
                if mode == "subset" {
                    config.scope = .subset
                    for n in g.nodes.suffix(6) { n.metadata[GraphMetadataKeys.layoutSubset] = true }
                }
                for (i, n) in g.nodes.enumerated() where i == 0 || (mode == "subset" && i < 6) {
                    drawing.fixedCenters[n.id] = n.center
                }
                let op = OrganicLayoutOperation(backend: backend, executor: executor, configuration: config)
                try await op.applyLayoutAsync(g)
                VisualGraphs.finish(g, route: true)
                return (drawing, op.lastExecutionMetrics)
            }
        }

        return qualityCases + scopeCases
    }

    // MARK: - 6. Framed Groups (4 cases)

    public static func framedGroupCases() -> [ComparativeDiagramCase] {
        VisualCatalogue.framedGroupCases().map { item in
            ComparativeDiagramCase(
                id: item.id,
                family: "frames",
                title: item.title,
                configuration: item.configuration,
                contracts: item.contracts,
                smoke: item.smoke
            ) { backend, executor in
                try await VisualCatalogue.runFramedGroup(item.id, backend: backend, executor: executor)
            }
        }
    }

    // MARK: - 7. Software Engineering Diagrams (21 cases)

    public static func softwareEngineeringCases() -> [ComparativeDiagramCase] {
        VisualCatalogue.softwareEngineeringCases().map { item in
            ComparativeDiagramCase(
                id: item.id,
                family: "engineering",
                title: item.title,
                configuration: item.configuration,
                contracts: item.contracts,
                smoke: item.smoke
            ) { backend, executor in
                try await VisualCatalogue.runSoftwareEngineering(item, backend: backend, executor: executor)
            }
        }
    }
}
