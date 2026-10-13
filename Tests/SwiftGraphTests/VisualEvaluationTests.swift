import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport
#if os(macOS)
import ImageIO
#endif

@Suite struct VisualEvaluationTests {
    private func snapshot(_ graph: LayoutGraph, contracts: VisualContracts = .init()) -> VisualSnapshot {
        let item = VisualCase(id: "test-case", family: "test", title: "Test <&>", contracts: contracts, run: { VisualDrawing(graph: graph) })
        return VisualSnapshot(case: item, drawing: VisualDrawing(graph: graph))
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("swiftgraph-visual-test-\(UUID().uuidString)") }

    @Test func catalogueCoversPublicFamiliesAndReferenceCorpus() throws {
        let cases = try VisualCatalogue.all()
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(cases.allSatisfy { VisualStorage.safeID($0.id) })
        #expect(cases.filter { $0.family == "preset" }.count == LayoutPatternType.allCases.count)
        #expect(cases.filter { $0.family == "reference" }.count == 98)
        #expect(cases.filter { $0.family == "routing" }.count == 10)
        #expect(cases.filter { $0.id.hasPrefix("layout-") }.count == 28)
        #expect(Set(cases.filter { $0.family == "directed" }.map(\.id)).isSuperset(of: ["directed-fresh", "directed-incremental", "directed-routes-only"]))
        #expect(try VisualEvaluation.selected(cases, suite: "metal", ids: []).allSatisfy(\.metal))
        #expect(throws: EvaluationError.self) { try VisualEvaluation.selected(cases, suite: "full", ids: ["typo"]) }
    }

    @Test func metalGalleryCoversEveryPublicFamily() throws {
        let cases = try VisualEvaluation.selected(VisualCatalogue.all(), suite: "metal", ids: [])
        let ids = Set(cases.map(\.id))
        #expect(ids.isSuperset(of: VisualCatalogue.layouts().map { "metal-layout-" + $0.id }))
        #expect(ids.isSuperset(of: RoutingKind.allCases.map { "metal-router-" + $0.rawValue }))
        #expect(ids.isSuperset(of: LayoutPatternType.allCases.map { "metal-preset-" + $0.rawValue }))
        #expect(ids.isSuperset(of: ["metal-directed-fresh", "metal-directed-incremental", "metal-directed-routes-only",
            "metal-analysis-pageRank", "metal-analysis-clusters", "metal-composition-importance", "metal-composition-cluster"]))
        #expect(MetalVisualCatalogue.all().allSatisfy { $0.metal })
    }

    @Test func fullCPUCatalogueIsIsolatedAndObeysContracts() async throws {
        for item in try VisualCatalogue.all() where !item.metal && item.family != "performance" {
            let first = try await item.run(), second = try await item.run()
            #expect(first.graph !== second.graph, "\(item.id): shared graph")
            #expect(zip(first.graph.nodes, second.graph.nodes).allSatisfy { $0 !== $1 }, "\(item.id): shared nodes")
            let a = VisualSnapshot(case: item, drawing: first), b = VisualSnapshot(case: item, drawing: second)
            try VisualStorage.validate(a)
            #expect(!VisualComparison.compare(a, b).changed, "\(item.id): nondeterministic geometry")
            #expect(a == b, "\(item.id): unstable snapshot metadata")
            #expect(VisualGeometry.measure(a).failures.isEmpty, "\(item.id): \(VisualGeometry.measure(a).failures)")
            #expect(first.additionalFailures.isEmpty, "\(item.id): \(first.additionalFailures)")
        }
    }

    @Test func diagnosticsDistinguishContainmentObstaclesCrossingsAndSharedRuns() {
        let g = LayoutGraph()
        let positions = [Point(x: 0, y: 0), Point(x: 100, y: 100), Point(x: 0, y: 100), Point(x: 100, y: 0)]
        for (i, p) in positions.enumerated() {
            let n = LayoutNode(id: "n\(i)", width: 10, height: 10); n.center = p; g.addNode(n)
        }
        for (s, t) in [(0, 1), (2, 3), (1, 0)] {
            let e = LayoutEdge(source: g.nodes[s], target: g.nodes[t]); e.path = [e.source.center, e.target.center]; g.addEdge(e)
        }
        let wall = LayoutNode(id: "wall", width: 20, height: 20); wall.center = Point(x: 50, y: 50); g.addNode(wall)
        let group = LayoutNode(id: "group", width: 200, height: 200); group.bounds.x = -40; group.bounds.y = -40; group.isGroup = true
        for n in g.nodes { n.parent = group; group.children.append(n) }; g.root.children = []; g.addNode(group)
        let metrics = VisualGeometry.measure(snapshot(g, contracts: .init(noObstacleIntersections: true)))
        #expect(metrics.values["nodeOverlaps"] == 0)
        #expect(metrics.values["crossings"] == 2)
        #expect(metrics.values["sharedSegments"] == 1)
        #expect(metrics.values["edgeNodeIntersections"] == 3)
        #expect(metrics.failures.count == 3)
        #expect(metrics.findings.contains { $0.kind == "edge-node-intersection" && $0.elements == ["e0", "wall"] })
        #expect(VisualGeometry.measure(snapshot(g)).failures.isEmpty) // style-only routing is advisory
    }

    @Test func routingQualityMetricsMeasureBendsEndpointsParallelRunsAndClearance() {
        let g = LayoutGraph()
        // Three 20x20 nodes: a (0,0), b (200,0), c (100,60) — c sits well below the a-b routes.
        for (id, x, y) in [("a", 0.0, 0.0), ("b", 200.0, 0.0), ("c", 100.0, 60.0)] {
            let n = LayoutNode(id: id, width: 20, height: 20); n.bounds.x = x; n.bounds.y = y; g.addNode(n)
        }
        func edge(_ s: Int, _ t: Int, _ path: [Point]) { let e = LayoutEdge(source: g.nodes[s], target: g.nodes[t]); e.path = path; g.addEdge(e) }
        // e0: clipped, sampled near-straight (sub-degree kinks).
        edge(0, 1, [Point(x: 20, y: 10), Point(x: 60, y: 10.1), Point(x: 100, y: 10), Point(x: 140, y: 10.1), Point(x: 200, y: 10)])
        // e1: runs 2-3 units from e0, starts at a's centre (unclipped) and has a 1-unit Z-jog.
        edge(0, 1, [Point(x: 10, y: 10), Point(x: 100, y: 12), Point(x: 100, y: 13), Point(x: 195, y: 13)])
        // e2: ends exactly on c's top-right corner.
        edge(1, 2, [Point(x: 200, y: 10), Point(x: 120, y: 60)])
        let m = VisualGeometry.measure(snapshot(g))
        #expect(m.values["bends"] == 2) // e1's two Z-jog turns; e0's 0.14 degree kinks are below tolerance
        #expect(m.values["endpointsInsideNodes"] == 1) // only e1's start at a's centre; the other endpoints lie on or outside their boundaries
        #expect(m.values["endpointsAtCorners"] == 1) // e2 ends at c's top-right corner (120,60)
        #expect(m.values["microSegments"] == 1)
        #expect((m.values["nearParallelRuns"] ?? 0) >= 1 && m.values["sharedSegments"] == 0)
        #expect(m.findings.contains { $0.kind == "near-parallel-run" && $0.elements == ["e0", "e1"] })
        #expect((m.values["minEdgeNodeClearance"] ?? 0) > 40)
        #expect(!m.findings.contains { $0.kind == "edge-node-clearance" })
        #expect(m.failures.isEmpty)
    }

    @Test func missingRoutesPinsAndInvalidGeometryAreExplicit() {
        let g = VisualGraphs.graph(2)
        var s = snapshot(g)
        #expect(VisualGeometry.measure(s).failures.contains { $0.kind == "missing-route" })
        s.contracts.routesRequired = false; s.contracts.expectMissingRoutes = true
        #expect(VisualGeometry.measure(s).failures.isEmpty)
        s.fixedCenters[s.nodes[0].id] = Point(x: 999, y: 999)
        #expect(VisualGeometry.measure(s).failures.contains { $0.kind == "fixed-center-moved" })
        s.nodes[0].bounds.x = .nan
        #expect(VisualGeometry.measure(s).failures.first?.kind == "nonfinite-or-negative-geometry")
        #expect(throws: EvaluationError.self) { try VisualStorage.validate(s) }
    }

    @Test func comparisonUsesToleranceAndFlagsQualityWithoutFailing() {
        let g = VisualGraphs.graph(2); VisualGraphs.finish(g, route: true)
        let a = snapshot(g); var b = a
        b.nodes[0].bounds.x += 0.0000005
        #expect(!VisualComparison.compare(a, b).changed)
        b.nodes[0].bounds = b.nodes[1].bounds
        let diff = VisualComparison.compare(a, b)
        #expect(diff.changedNodes == [b.nodes[0].id])
        #expect(diff.qualityFlags.contains("nodeOverlaps"))
        #expect(VisualGeometry.measure(b).failures.isEmpty)
        b.contracts.noNodeOverlaps = true
        #expect(!VisualGeometry.measure(b).failures.isEmpty)
    }

    @Test func renderBoundsIncludeRoutesArrowheadsLabelsAndNegativeCoordinates() throws {
        let g = VisualGraphs.graph(2); g.nodes[0].name = "<node & name>"
        g.edges[0].path = [Point(x: -500, y: -300), Point(x: 800, y: -300), Point(x: 800, y: 400)]
        g.edges[0].data = "label <&>"; g.edges[0].labelBounds = Rect(x: 900, y: 450, width: 150, height: 24)
        let scene = VisualScene(snapshot: snapshot(g))
        #expect(scene.bounds.left < -500 && scene.bounds.top < -300)
        #expect(scene.bounds.right > 1050 && scene.bounds.bottom > 474)
        #expect(scene.primitives.allSatisfy { scene.bounds.contains(Point(x: $0.bounds.left, y: $0.bounds.top)) && scene.bounds.contains(Point(x: $0.bounds.right, y: $0.bounds.bottom)) })
        let svg = VisualRenderer.svg(scene)
        #expect(svg.contains("&lt;node &amp; name&gt;"))
        #expect(svg.contains("label &lt;&amp;&gt;"))
        #expect(svg.contains("<polygon"))
        #if os(macOS)
        let dir = directory(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        try VisualRenderer.write(scene, to: dir.appendingPathComponent("sample"))
        let source = try #require(CGImageSourceCreateWithURL(dir.appendingPathComponent("sample.png") as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width > 0 && image.height > 0 && max(image.width, image.height) <= 2400)
        for s in [snapshot(LayoutGraph()), snapshot(VisualGraphs.groups(edges: false))] {
            try VisualRenderer.write(VisualScene(snapshot: s), to: dir.appendingPathComponent("edge-case"))
        }
        #endif
    }

    @Test func runComparisonAndExplicitBaselineUpdatePreserveEvidence() async throws {
        #if os(macOS)
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let good = VisualCase(id: "good", family: "test", title: "Good") {
            let g = VisualGraphs.graph(2); VisualGraphs.finish(g, route: true); return VisualDrawing(graph: g)
        }
        let broken = VisualCase(id: "broken", family: "test", title: "Broken") { VisualDrawing(graph: VisualGraphs.graph(2)) }
        let error = VisualCase(id: "error", family: "test", title: "Throws") { throw EvaluationError.message("deliberate case failure") }
        let first = root.appendingPathComponent("first"), baseline = root.appendingPathComponent("baseline"), next = root.appendingPathComponent("next")
        let run = try await VisualEvaluation.render([good, broken, error], output: first, baselines: [:], command: ["test"], environment: [:])
        #expect(run.failed)
        #expect(run.cases.map(\.status) == ["missing-baseline", "contract-failure", "error"])
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("cases/good/current.png").path))
        #expect(try VisualEvaluation.accept(from: first, to: baseline, ids: ["good"]) == 1)
        #expect(throws: EvaluationError.self) { try VisualEvaluation.accept(from: first, to: baseline, ids: ["broken"]) }
        #expect(throws: EvaluationError.self) { try VisualEvaluation.accept(from: first, to: baseline, ids: []) }
        let baselines = try VisualStorage.collection(baseline).snapshots
        let repeated = try await VisualEvaluation.render([good], output: next, baselines: baselines, command: [], environment: [:])
        #expect(!repeated.failed && repeated.cases[0].status == "unchanged")
        let moved = VisualCase(id: "good", family: "test", title: "Good") {
            let g = VisualGraphs.graph(2); g.nodes[1].x += 60; VisualGraphs.finish(g, route: true); return VisualDrawing(graph: g)
        }
        let changed = try await VisualEvaluation.render([moved], output: root.appendingPathComponent("changed"), baselines: baselines, command: [], environment: [:])
        #expect(!changed.failed && changed.cases[0].status == "changed")
        #expect(changed.cases[0].difference?.changedNodes == ["n1"])
        #expect(changed.cases[0].difference?.qualityFlags.contains("routeLength") == true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("changed/cases/good/overlay.svg").path))
        #expect(throws: EvaluationError.self) { try VisualStorage.prepareOutput(first) }
        let compared = try VisualEvaluation.compare(before: first, after: next, output: root.appendingPathComponent("compared"), ids: ["good"], command: [])
        #expect(compared.cases[0].status == "unchanged")
        let failures = try VisualEvaluation.compare(before: next, after: first, output: root.appendingPathComponent("failures"), ids: [], command: [])
        #expect(failures.failed)
        #expect(failures.cases.contains { $0.id == "broken" && $0.status == "contract-failure" })
        #endif
    }

    @Test func commandValidationRejectsAmbiguousInputs() throws {
        #expect(throws: EvaluationError.self) { try VisualOptions(["render", "--suite"]) }
        #expect(throws: EvaluationError.self) { try VisualOptions(["render", "--wat", "x"]) }
        #expect(throws: EvaluationError.self) { try VisualOptions(["render", "--output", "a", "--output", "b"]) }
        #expect(try VisualOptions(["render", "--case", "one", "--case", "two"]).ids == ["one", "two"])
        #expect(!VisualStorage.safeID("../../escape"))
        #expect(!VisualStorage.safeID("a/b"))
    }

    @Test func resourceBaselinesLoadAndReferenceFallbacksAreNotFalseRegressions() async throws {
        let baselines = try VisualStorage.bundledBaselines()
        let curated = try #require(baselines["layout-hierarchical"])
        #expect(curated.measuredMetrics != nil)
        try VisualStorage.validate(curated)
        let item = try #require(VisualCatalogue.all().first { $0.id == "reference-channel-enclosed-fallback" })
        let drawing = try await item.run(), current = VisualSnapshot(case: item, drawing: drawing)
        #expect(!drawing.fallbackEdges.isEmpty)
        let reference = try #require(baselines[item.id])
        let diff = VisualComparison.compare(reference, current)
        // The channel router now draws this walled-in edge between boundary ports instead of centres, so its length differs from the C# line; nothing else may read as a regression.
        #expect(Set(diff.qualityFlags).isSubset(of: ["routeLength"]))
        var earlier = current; earlier.edges = earlier.edges.map { var e = $0; e.fallback = false; return e }
        #expect(VisualComparison.compare(earlier, current).qualityFlags.contains("fallbackRoutes"))
    }
}
