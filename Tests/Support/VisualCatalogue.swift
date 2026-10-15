import Foundation
import SwiftGraph

enum VisualGraphs {
    static func graph(_ count: Int = 12, shape: String = "dag") -> LayoutGraph {
        let g = LayoutGraph()
        for i in 0..<count {
            let n = LayoutNode(id: "n\(i)", width: 80 + Float(i % 4) * 25, height: 32 + Float(i % 3) * 8)
            n.x = Float(i % 4) * 220 - 120; n.y = Float(i / 4) * 150 - 80
            g.addNode(n)
        }
        guard count > 1 else { return g }
        for i in 1..<count {
            if shape == "disconnected" && i % 4 == 0 { continue }
            let parent = shape == "star" ? 0 : (shape == "tree" ? (i - 1) / 2 : i - 1)
            g.addEdge(LayoutEdge(source: g.nodes[parent], target: g.nodes[i]))
            if (shape == "dag" || shape == "dense") && i > 3 { g.addEdge(LayoutEdge(source: g.nodes[i - 3], target: g.nodes[i])) }
            if shape == "dense" && i > 5 { g.addEdge(LayoutEdge(source: g.nodes[i - 5], target: g.nodes[i])) }
        }
        if shape == "cyclic" {
            for (a, b) in [(count - 1, 0), (0, 1), (1, 0), (0, 0)] { g.addEdge(LayoutEdge(source: g.nodes[a], target: g.nodes[b])) }
        }
        return g
    }
    static func groups(edges: Bool = true) -> LayoutGraph {
        let g = graph(8, shape: "tree")
        if !edges { g.edges = [] }
        let outer = LayoutNode(id: "group-a", width: 600, height: 400); outer.isGroup = true
        let inner = LayoutNode(id: "group-b", width: 300, height: 200); inner.isGroup = true
        for n in g.nodes.prefix(4) { g.root.children.removeAll { $0 === n }; n.parent = inner; inner.children.append(n) }
        inner.parent = outer; outer.children.append(inner)
        g.addNode(outer); g.addNode(inner)
        return g
    }
    static func obstacle() -> LayoutGraph {
        let g = LayoutGraph()
        for (id, rect) in [("source", Rect(x: -180, y: 60, width: 110, height: 50)),
                           ("target", Rect(x: 420, y: 60, width: 110, height: 50)),
                           ("wall", Rect(x: 120, y: 0, width: 80, height: 180))] {
            let n = LayoutNode(id: id, width: rect.width, height: rect.height); n.bounds = rect; g.addNode(n)
        }
        for _ in 0..<2 {
            let e = LayoutEdge(source: g.nodes[0], target: g.nodes[1]); e.sourcePort = .right; e.targetPortCandidates = [.left, .top]
            e.path = [e.source.center, e.target.center]; g.addEdge(e)
        }
        let reverse = LayoutEdge(source: g.nodes[1], target: g.nodes[0]); reverse.path = [reverse.source.center, reverse.target.center]; g.addEdge(reverse)
        g.addEdge(LayoutEdge(source: g.nodes[0], target: g.nodes[0]))
        SelfLoopRouter().routeEdges(g)
        return g
    }
    static func routing(_ name: String) throws -> LayoutGraph {
        if name == "curve-fitting" {
            let g = graph(8); try HierarchicalLayoutAlgorithm().applyLayout(g); return g
        }
        if name == "octilinear" {
            let g = graph(8, shape: "tree"); try CircularLayoutAlgorithm().applyLayout(g); return g
        }
        if name == "bundling" || name == "bus" {
            let g = graph(12); g.edges = []
            for (i, n) in g.nodes.enumerated() { n.x = i < 6 ? 0 : 720; n.y = Float(i % 6) * 110 }
            for i in 0..<6 {
                let pairs = name == "bus" ? [(0, i + 6), (i, 11)] : [(i, i + 6), (i, (i + 1) % 6 + 6)]
                for (s, t) in pairs {
                    let e = LayoutEdge(source: g.nodes[s], target: g.nodes[t]); e.path = [e.source.center, e.target.center]; g.addEdge(e)
                }
            }
            return g
        }
        return obstacle()
    }
    static func finish(_ g: LayoutGraph, route: Bool = false) {
        if route { PolylineEdgeRouter().routeEdges(g) }
        SelfLoopRouter().routeEdges(g); EdgeEndpointClipper.clipToNodeBounds(g)
    }
}

enum VisualCatalogue {
    struct LayoutSpec {
        var id: String
        var family: String
        var factory: () -> any LayoutAlgorithm
        var shape = "dag"
        var routeAfter = false
    }
    static func layouts() -> [LayoutSpec] {
        [
            .init(id: "hierarchical", family: "hierarchical", factory: { HierarchicalLayoutAlgorithm() }),
            .init(id: "series-parallel", family: "hierarchical", factory: { SeriesParallelLayoutAlgorithm() }),
            .init(id: "organic", family: "organic", factory: { OrganicLayoutAlgorithm() }, routeAfter: true),
            .init(id: "barycenter", family: "refinement", factory: { BarycenterLayoutAlgorithm() }, routeAfter: true),
            .init(id: "remove-overlaps", family: "refinement", factory: { RemoveOverlapsLayoutAlgorithm() }, routeAfter: true),
            .init(id: "tree", family: "tree", factory: { TreeLayoutAlgorithm() }, shape: "tree"),
            .init(id: "radial-tree", family: "tree", factory: { RadialTreeLayoutAlgorithm() }, shape: "tree"),
            .init(id: "balloon", family: "tree", factory: { BalloonLayoutAlgorithm() }, shape: "tree"),
            .init(id: "radial", family: "tree", factory: { RadialLayoutAlgorithm() }, shape: "tree"),
            .init(id: "radial-star", family: "tree", factory: { RadialStarLayoutAlgorithm() }, shape: "star"),
            .init(id: "org-chart", family: "tree", factory: { OrgChartLayoutAlgorithm() }, shape: "tree"),
            .init(id: "orthogonal", family: "grid", factory: { OrthogonalLayoutAlgorithm() }),
            .init(id: "partition-grid", family: "grid", factory: {
                let a = PartitionGridLayoutAlgorithm(); for i in 0..<12 { a.cellAssignment["n\(i)"] = (i / 4, i % 4) }; return a
            }),
            .init(id: "tabular", family: "grid", factory: { TabularLayoutAlgorithm() }),
            .init(id: "kandinsky", family: "grid", factory: { KandinskyLayoutAlgorithm() }),
            .init(id: "circular", family: "packing", factory: { CircularLayoutAlgorithm() }),
            .init(id: "compact-disk", family: "packing", factory: { CompactDiskLayoutAlgorithm() }),
            .init(id: "vertical-stack", family: "packing", factory: { VerticalStackLayoutAlgorithm() }, routeAfter: true),
            .init(id: "swimlane", family: "specialized", factory: {
                let a = SwimlaneLayoutAlgorithm(); for i in 0..<12 { a.laneAssignment["n\(i)"] = i % 3 }; return a
            }, routeAfter: true),
            .init(id: "tree-map", family: "specialized", factory: { TreeMapLayoutAlgorithm() }, shape: "groups"),
            .init(id: "alignment", family: "specialized", factory: {
                let a = AlignmentLayoutAlgorithm(); a.horizontalAlignment = .snapToGrid; a.verticalAlignment = .snapToGrid; return a
            }),
            .init(id: "fill-area", family: "specialized", factory: { FillAreaLayoutAlgorithm(Rect(x: -100, y: -100, width: 900, height: 650)) }, routeAfter: true),
            .init(id: "clear-area", family: "specialized", factory: { ClearAreaLayoutAlgorithm(Rect(x: 0, y: 0, width: 400, height: 300)) }, routeAfter: true),
            .init(id: "given-coordinates", family: "specialized", factory: { GivenCoordinatesLayoutAlgorithm() }),
            .init(id: "components", family: "composition", factory: { ComponentLayout(HierarchicalLayoutAlgorithm()) }, shape: "disconnected"),
            .init(id: "multi-page", family: "composition", factory: {
                let a = MultiPageLayoutAlgorithm(); a.pageWidth = 450; a.pageHeight = 400; return a
            }, shape: "disconnected"),
            .init(id: "recursive-groups", family: "composition", factory: { RecursiveGroupLayout(HierarchicalLayoutAlgorithm()) }, shape: "groups"),
            .init(id: "subgraph", family: "composition", factory: {
                let a = SubgraphLayoutAlgorithm(CircularLayoutAlgorithm()); a.selectedNodeIds = Set((0..<6).map { "n\($0)" }); return a
            })
        ]
    }
    static let routerNames = ["polyline", "channel", "bsp", "grouped", "bus", "octilinear", "parallel", "bundling", "curve-fitting", "self-loop"]
    static func router(_ name: String) -> any EdgeRouter {
        switch name {
        case "channel": ChannelEdgeRouter()
        case "bsp": BspEdgeRouter()
        case "grouped": OrthogonalGroupedEdgeRouter()
        case "bus": BusEdgeRouter()
        case "octilinear": OctilinearEdgeRouter()
        case "parallel": ParallelEdgeRouter()
        case "bundling": EdgeBundlingRouter()
        case "curve-fitting": CurveFittingEdgeRouter()
        case "self-loop": SelfLoopRouter()
        default: PolylineEdgeRouter()
        }
    }
    static func fallbacks(_ router: any EdgeRouter, _ graph: LayoutGraph) -> [Int] {
        let failed: [LayoutEdge]
        switch router {
        case let r as ChannelEdgeRouter: failed = r.unroutableEdges
        case let r as BspEdgeRouter: failed = r.unroutableEdges
        case let r as OrthogonalGroupedEdgeRouter: failed = r.unroutableEdges
        default: failed = []
        }
        return graph.edges.indices.filter { index in failed.contains { $0 === graph.edges[index] } }
    }
    static func all() throws -> [VisualCase] {
        var cases: [VisualCase] = layouts().map { spec in
            VisualCase(id: "layout-\(spec.id)", family: spec.family, title: "\(spec.id) · mixed sizes",
                       configuration: ["layout": spec.id, "input": spec.shape, "nodes": "12 (8 leaves for groups)", "options": "catalogue-v1 defaults",
                                       "pipeline": spec.id == "subgraph" ? "obstacle-aware input routes → subgraph → self-loops → clip" : "layout → \(spec.routeAfter ? "polyline → " : "")self-loops → clip"],
                       smoke: ["hierarchical", "recursive-groups", "tree-map", "organic"].contains(spec.id)) {
                let g = spec.shape == "groups" ? VisualGraphs.groups(edges: spec.id != "tree-map") : VisualGraphs.graph(shape: spec.shape)
                if spec.id == "remove-overlaps" { for n in g.nodes { n.x *= 0.2; n.y *= 0.2 } }
                if spec.id == "barycenter" { g.nodes[0].metadata[GraphMetadataKeys.fixed] = true }
                // Alignment may intentionally be a no-op; initialize its input paths explicitly.
                if spec.id == "alignment" { PolylineEdgeRouter().routeEdges(g) }
                var drawing = VisualDrawing(graph: g)
                if spec.id == "barycenter" { drawing.fixedCenters[g.nodes[0].id] = g.nodes[0].center }
                if spec.id == "subgraph" {
                    // A local layout preserves existing unrelated routes; seed the input, never overwrite its output.
                    PolylineEdgeRouter().routeEdges(g)
                    for n in g.nodes.dropFirst(6) { drawing.fixedCenters[n.id] = n.center }
                }
                try spec.factory().applyLayout(g)
                VisualGraphs.finish(g, route: spec.routeAfter)
                return drawing
            }
        }
        for i in cases.indices where ["layout-remove-overlaps", "layout-tabular", "layout-circular", "layout-orthogonal", "layout-radial", "layout-radial-tree", "layout-radial-star", "layout-subgraph"].contains(cases[i].id) {
            cases[i].contracts.noNodeOverlaps = true
        }
        for i in cases.indices where ["layout-radial", "layout-radial-tree", "layout-radial-star", "layout-subgraph"].contains(cases[i].id) {
            cases[i].contracts.noObstacleIntersections = true
        }
        for pattern in LayoutPatternType.allCases {
            cases.append(VisualCase(id: "preset-\(pattern.rawValue)", family: "preset", title: pattern.rawValue,
                                    configuration: ["pattern": pattern.rawValue, "input": "12 cyclic, mixed sizes", "pipeline": "preset (library output; no extra clip)"],
                                    contracts: VisualContracts(noNodeOverlaps: [.mindMap, .standardOrganic, .largeGraphPreset, .denseGraphPreset, .socialNetwork, .networkTopology, .progressiveRefinement].contains(pattern), noObstacleIntersections: [.standardTree, .organizationChart, .hybridLayout, .mindMap, .standardOrganic, .largeGraphPreset, .progressiveRefinement].contains(pattern))) {
                let g = VisualGraphs.graph(shape: "cyclic")
                try await LayoutBuilder.create(g).applyPattern(pattern).applyAsync()
                return VisualDrawing(graph: g)
            })
        }
        for name in routerNames {
            let input = ["curve-fitting": "hierarchical bends", "octilinear": "diagonal tree edges", "bundling": "parallel traffic", "bus": "fan-in and fan-out"][name] ?? "obstacle, ports and reciprocal edges"
            cases.append(VisualCase(id: "router-\(name)", family: "routing", title: "\(name) · \(input)",
                                    configuration: ["router": name, "input": input, "pipeline": "router → self-loops → clip"],
                                    contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: name == "channel", orthogonal: name == "channel"), smoke: name == "channel") {
                let g = try VisualGraphs.routing(name), r = router(name)
                r.routeEdges(g); let failures = fallbacks(r, g); VisualGraphs.finish(g)
                return VisualDrawing(graph: g, fallbackEdges: failures,
                    notes: ["Only channel interprets ports. Styling routers do not guarantee obstacle clearance."])
            })
        }
        for fixture in try loadRoutingFixtures() {
            cases.append(VisualCase(id: "reference-\(fixture.name)", family: "reference", title: fixture.name,
                                    configuration: fixture.config.mapValues { String($0) }.merging(["router": fixture.router, "pipeline": "router only; raw reference geometry"], uniquingKeysWith: { a, _ in a }),
                                    contracts: VisualContracts(routesRequired: false)) {
                let g = fixture.graph(), r = fixture.makeRouter(); r.routeEdges(g)
                var drawing = VisualDrawing(graph: g, fallbackEdges: fallbacks(r, g), notes: [fixture.divergesFromReference
                    ? "Router intentionally diverging from the C# reference; the reference is the comparison baseline."
                    : "Raw C# reference contract; existing paths and self-loops are preserved."])
                // Divergence is reviewed against the reference baseline rather than failed.
                guard !fixture.divergesFromReference else { return drawing }
                for (index, n) in g.nodes.enumerated() {
                    let b = fixture.expected.bounds[index]
                    if zip([n.x, n.y, n.width, n.height], b).contains(where: { abs($0 - $1) >= 1e-7 }) {
                        drawing.additionalFailures.append(.init(kind: "reference-bounds-mismatch", elements: [n.id]))
                    }
                }
                for (index, e) in g.edges.enumerated() {
                    let expected = fixture.expected.paths[index]
                    if e.path.count != expected.count || zip(e.path, expected).contains(where: { abs($0.x - $1[0]) >= 1e-7 || abs($0.y - $1[1]) >= 1e-7 }) {
                        drawing.additionalFailures.append(.init(kind: "reference-path-mismatch", elements: ["e\(index)"]))
                    }
                }
                return drawing
            })
        }
        cases += directedCases()
        cases += organicQualityCases()
        cases += organicQualityCases(metal: true)
        for count in [0, 1, 64, 256] {
            cases.append(VisualCase(id: "organic-\(count)", family: "organic", title: "Organic · \(count) nodes",
                                    configuration: ["nodes": String(count), "iterations": "40", "input": "dense", "pipeline": "quality organic (budget constrained) → legacy polyline → clip"], contracts: VisualContracts(noNodeOverlaps: true), smoke: count <= 1) {
                let g = VisualGraphs.graph(count, shape: "dense"), a = OrganicLayoutAlgorithm(); a.iterations = 40
                try a.applyLayout(g); VisualGraphs.finish(g, route: true); return VisualDrawing(graph: g)
            })
        }
        for mode in ["pinned", "subset"] {
            cases.append(VisualCase(id: "organic-\(mode)", family: "organic", title: "Organic · \(mode)", configuration: ["scope": mode, "iterations": "100"]) {
                let g = VisualGraphs.graph(), a = OrganicLayoutAlgorithm()
                var drawing = VisualDrawing(graph: g)
                g.nodes[0].metadata[GraphMetadataKeys.fixed] = true
                if mode == "subset" { a.scope = .subset; for n in g.nodes.suffix(6) { n.metadata[GraphMetadataKeys.layoutSubset] = true } }
                for (i, n) in g.nodes.enumerated() where i == 0 || (mode == "subset" && i < 6) { drawing.fixedCenters[n.id] = n.center }
                try a.applyLayout(g); VisualGraphs.finish(g, route: true); return drawing
            })
        }
        for kind in ["placement", "layout"] {
            cases.append(VisualCase(id: "labels-\(kind)", family: "labels", title: "Edge label \(kind)", configuration: ["pipeline": "hierarchical → clip → labels-\(kind)"], contracts: VisualContracts(noLabelOverlaps: true), smoke: kind == "placement") {
                let g = VisualGraphs.graph(6); try HierarchicalLayoutAlgorithm().applyLayout(g); VisualGraphs.finish(g)
                for (i, e) in g.edges.enumerated() { e.data = "edge \(i) <&>"; e.labelBounds = Rect(width: 104, height: 22) }
                if kind == "placement" { LabelPlacementAlgorithm().applyLabelPlacement(g) } else { LabelLayoutAlgorithm().applyLabelLayout(g) }
                return VisualDrawing(graph: g)
            })
        }
        for name in ["organic", "bundling"] {
            cases.append(VisualCase(id: "metal-\(name)", family: "metal", title: "Metal \(name) · 64 nodes", configuration: ["backend": "metal", "nodes": "64", "iterations": "30"], metal: true) {
                let g = VisualGraphs.graph(64, shape: "dense")
                if name == "organic" {
                    var config = OrganicLayoutConfiguration(); config.iterations = 30
                    let op = OrganicLayoutOperation(backend: .metal, configuration: config); try await op.applyLayoutAsync(g)
                    VisualGraphs.finish(g, route: true)
                } else {
                    try CircularLayoutAlgorithm().applyLayout(g)
                    let op = EdgeBundlingOperation(backend: .metal); try await op.applyLayoutAsync(g); VisualGraphs.finish(g)
                }
                return VisualDrawing(graph: g, notes: ["Metal Float output is reviewed visually; it is not required to equal CPU geometry."])
            })
        }
        cases += framedGroupCases()
        cases += softwareEngineeringCases()
        cases += MetalVisualCatalogue.all()
        return cases.sorted { $0.id < $1.id }
    }

    static func organicQualityCases(metal: Bool = false) -> [VisualCase] {
        let specs: [(String, Int, String)] = [("64", 64, "dense"), ("256", 256, "dense"),
            ("chain", 32, "chain"), ("star", 32, "star"), ("tree", 32, "tree"),
            ("grid", 36, "grid"), ("clusters", 32, "clusters"), ("disconnected", 32, "disconnected"),
            ("coincident", 32, "dense"), ("pins", 32, "dense"), ("subset", 32, "dense"),
            ("threshold-63", 63, "tree"), ("threshold-64", 64, "tree"), ("threshold-65", 65, "tree"),
            ("groups", 8, "groups"), ("performance-1024", 1024, "dense")]
        let selected = metal ? specs.filter { ["64", "256", "coincident", "pins", "subset", "threshold-63", "threshold-64", "threshold-65"].contains($0.0) } : specs
        return selected.map { name, count, shape in
            VisualCase(id: "\(metal ? "metal-" : "")organic-quality-\(name)", family: metal ? "metal" : name.hasPrefix("performance") ? "performance" : "organic", title: "\(metal ? "Metal " : "")Organic quality · \(name)",
                       configuration: ["input": shape, "nodes": String(count), "iterations": "600 per candidate", "pipeline": "quality organic → obstacle-aware polyline → clip"],
                       contracts: VisualContracts(noNodeOverlaps: true, noObstacleIntersections: true), metal: metal) {
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
                    for i in 0..<count { for j in (i + 1)..<count where i / 8 == j / 8 {
                        g.addEdge(LayoutEdge(source: g.nodes[i], target: g.nodes[j]))
                    } }
                    for i in [7, 15, 23] { g.addEdge(LayoutEdge(source: g.nodes[i], target: g.nodes[i + 1])) }
                }
                let a = OrganicLayoutAlgorithm()
                if name == "coincident" { for n in g.nodes { n.x = 0; n.y = 0 } }
                if name == "pins" { for n in g.nodes.prefix(2) { n.metadata[GraphMetadataKeys.fixed] = true } }
                if name == "subset" { a.scope = .subset; for n in g.nodes.suffix(count / 2) { n.metadata[GraphMetadataKeys.layoutSubset] = true } }
                var drawing = VisualDrawing(graph: g)
                for n in g.nodes where n.metadata[GraphMetadataKeys.fixed] as? Bool == true || (a.scope == .subset && n.metadata[GraphMetadataKeys.layoutSubset] as? Bool != true) {
                    drawing.fixedCenters[n.id] = n.center
                }
                let diagnostics: OrganicLayoutDiagnostics?
                if metal {
                    var config = OrganicLayoutConfiguration(); config.scope = a.scope
                    let op = OrganicLayoutOperation(backend: .metal, configuration: config)
                    try await op.applyLayoutAsync(g)
                    guard op.lastMetrics?.backend == .metal else { throw EvaluationError.message("Expected Metal execution") }
                    diagnostics = op.lastDiagnostics
                } else {
                    if shape == "groups" { try RecursiveGroupLayout(a).applyLayout(g) } else { try a.applyLayout(g) }
                    diagnostics = a.lastDiagnostics
                }
                if let d = diagnostics {
                    drawing.reportedMetrics = ["placement.clearanceViolations": Double(d.final.clearanceViolations),
                        "placement.edgeNodeIntersections": Double(d.final.edgeNodeIntersections), "placement.crossings": Double(d.final.crossings),
                        "placement.edgeLength": Double(d.final.edgeLength), "placement.area": Double(d.final.drawingArea),
                        "candidates": Double(d.candidateCount), "selectedCandidate": Double(d.selectedCandidate), "solverIterations": Double(d.solverIterations)]
                }
                let router = PolylineEdgeRouter(); router.routeEdges(g)
                drawing.fallbackEdges = g.edges.indices.filter { i in router.unroutableEdges.contains { $0 === g.edges[i] } }
                VisualGraphs.finish(g)
                return drawing
            }
        }
    }

    static func directedCases() -> [VisualCase] {
        ["fresh", "incremental", "routes-only", "fixed-conflict", "high-degree", "disconnected", "long-edges"].map { mode in
            VisualCase(id: "directed-\(mode)", family: "directed", title: "Directed · \(mode)",
                       configuration: ["mode": mode, "options": "catalogue-v1 defaults", "pipeline": "DirectedLayoutOperation; exact returned geometry"],
                       contracts: VisualContracts(routesRequired: mode != "fixed-conflict", noNodeOverlaps: mode != "fixed-conflict", noObstacleIntersections: mode != "fixed-conflict", orthogonal: true, expectMissingRoutes: mode == "fixed-conflict"),
                       smoke: ["fresh", "incremental"].contains(mode)) {
                let g = VisualGraphs.graph(mode == "high-degree" ? 20 : 8, shape: mode == "high-degree" ? "star" : mode == "disconnected" ? "disconnected" : "cyclic")
                var c = DirectedLayoutConfiguration(), drawing = VisualDrawing(graph: g)
                if mode == "long-edges" { g.addEdge(LayoutEdge(source: g.nodes[0], target: g.nodes[6])) }
                if mode == "high-degree" { c.edgeWidths = g.edges.map { _ in Float(3) }; drawing.edgeWidths = c.edgeWidths }
                if ["incremental", "routes-only", "fixed-conflict"].contains(mode) {
                    try DirectedLayoutOperation().apply(g)
                    c.previousBounds = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.bounds) })
                    c.previousPaths = Dictionary(uniqueKeysWithValues: g.edges.enumerated().map { ($0.offset, $0.element.path) })
                    drawing.previousBounds = c.previousBounds
                    drawing.fixedCenters = c.previousBounds.mapValues(\.center)
                    c.mode = mode == "incremental" ? .incremental : .routesOnly
                    if mode == "incremental" {
                        let n = LayoutNode(id: "inserted", width: 200, height: 40); g.addNode(n)
                        g.addEdge(LayoutEdge(source: g.nodes[0], target: n)); c.insertionOrigins[n.id] = g.nodes[2].center
                    }
                    if mode == "fixed-conflict" {
                        c.previousBounds[g.nodes[1].id] = c.previousBounds[g.nodes[0].id]
                        c.fixedNodeIDs = [g.nodes[0].id, g.nodes[1].id]
                        drawing.fixedCenters = c.previousBounds.mapValues(\.center)
                    }
                }
                let d = try DirectedLayoutOperation(configuration: c).apply(g)
                drawing.reportedMetrics = ["crossings": Double(d.crossings), "sharedRuns": Double(d.sharedRuns), "bends": Double(d.bends), "routeLength": Double(d.routeLength), "displacement": Double(d.displacement), "unroutableEdges": Double(d.unroutableEdges.count), "fixedConflicts": Double(d.fixedNodeConflicts.count)]
                if mode == "fixed-conflict" && d.fixedNodeConflicts.isEmpty { drawing.additionalFailures.append(.init(kind: "expected-fixed-conflict", elements: [])) }
                if mode == "fixed-conflict" { drawing.notes = ["Intentional impossible fixed constraints: missing routes and overlapping nodes are expected, and must be diagnosed."] }
                return drawing
            }
        }
    }

    static func referenceSnapshots() throws -> [VisualSnapshot] {
        try loadRoutingFixtures().map { fixture in
            let g = fixture.graph()
            for (n, r) in zip(g.nodes, fixture.expected.bounds) { n.bounds = Rect(x: r[0], y: r[1], width: r[2], height: r[3]) }
            for (e, path) in zip(g.edges, fixture.expected.paths) { e.path = path.map { Point(x: $0[0], y: $0[1]) } }
            let item = VisualCase(id: "reference-\(fixture.name)", family: "reference", title: fixture.name, configuration: ["oracle": "csharp-paths-and-bounds"], contracts: VisualContracts(routesRequired: false), run: { VisualDrawing(graph: g) })
            return VisualSnapshot(case: item, drawing: VisualDrawing(graph: g))
        }
    }
}
