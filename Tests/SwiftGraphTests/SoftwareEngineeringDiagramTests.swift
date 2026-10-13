import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport
#if os(macOS)
import ImageIO
#endif

@Suite struct SoftwareEngineeringDiagramTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("swiftgraph-se-tests-\(UUID().uuidString)")
    }

    @Test func engineeringCatalogueCoversAllDomainsAndScaleTiers() throws {
        let all = try VisualCatalogue.all()
        let engineering = try VisualEvaluation.selected(all, suite: "engineering", ids: [])
        #expect(engineering.count == 21)
        #expect(engineering.allSatisfy { $0.family == "engineering" && $0.id.hasPrefix("se-") })

        let small = engineering.filter { $0.configuration["scale"] == "small" }
        let medium = engineering.filter { $0.configuration["scale"] == "medium" }
        let large = engineering.filter { $0.configuration["scale"] == "large" }
        #expect(small.count == 6)
        #expect(medium.count == 8)
        #expect(large.count == 7)

        let domains = Set(engineering.compactMap { $0.configuration["domain"] })
        #expect(domains == ["architecture", "dependencies", "callgraph", "statemachine", "pipeline", "schema", "incremental", "constrained", "ecosystem"])

        let smokeIDs = Set(try VisualEvaluation.selected(all, suite: "smoke", ids: []).map(\.id))
        #expect(smokeIDs.isSuperset(of: ["se-arch-microservices-small", "se-deps-module-small", "se-state-protocol-small"]))
    }

    @Test func allEngineeringScenariosObeyScaleContractsAndDeterminism() async throws {
        let cases = try VisualEvaluation.selected(VisualCatalogue.all(), suite: "engineering", ids: [])
        for item in cases {
            let first = try await item.run()
            let second = try await item.run()
            #expect(first.graph !== second.graph, "\(item.id): must construct fresh graph")

            let snapA = VisualSnapshot(case: item, drawing: first)
            let snapB = VisualSnapshot(case: item, drawing: second)
            try VisualStorage.validate(snapA)
            #expect(!VisualComparison.compare(snapA, snapB).changed, "\(item.id): nondeterministic layout geometry")

            let metrics = VisualGeometry.measure(snapA)
            #expect(metrics.failures.isEmpty, "\(item.id) contract failures: \(metrics.failures)")
            #expect(first.additionalFailures.isEmpty, "\(item.id) additional failures: \(first.additionalFailures)")

            let nodeCount = snapA.nodes.count
            switch item.configuration["scale"] {
            case "small":
                #expect((10...25).contains(nodeCount), "\(item.id): expected small scale (10...25), got \(nodeCount)")
            case "medium":
                #expect((40...80).contains(nodeCount), "\(item.id): expected medium scale (40...80), got \(nodeCount)")
            case "large":
                #expect((150...240).contains(nodeCount), "\(item.id): expected large scale (150...240), got \(nodeCount)")
            default:
                Issue.record("Unexpected scale tier for \(item.id)")
            }
        }
    }

    @Test func structuralInvariantsHoldForGodHubLabelsAndIncrementalExpansion() async throws {
        let byID = Dictionary(uniqueKeysWithValues: VisualCatalogue.softwareEngineeringCases().map { ($0.id, $0) })

        // 1. God-object hub in OOP class hierarchy must dynamically expand to fit 18 incoming ports without shared segments
        let classCase = try #require(byID["se-deps-class-hierarchy-medium"])
        let classDrawing = try await classCase.run()
        let godNode = try #require(classDrawing.graph.nodes.first { $0.id == "ServiceLocator" })
        #expect(godNode.height > 100)
        let classMetrics = VisualGeometry.measure(VisualSnapshot(case: classCase, drawing: classDrawing))
        #expect(classMetrics.values["sharedSegments"] == 0)
        #expect(classMetrics.failures.isEmpty)

        // 2. PageRank-weighted trace call graph scales hot-path nodes above baseline size
        let traceCase = try #require(byID["se-callgraph-trace-medium"])
        let traceDrawing = try await traceCase.run()
        let widths = traceDrawing.graph.nodes.map(\.width)
        #expect((widths.max() ?? 0) > (widths.min() ?? 0) * 1.3)

        // 3. Labeled state machines and ER schema preserve measured label sizes with zero overlaps
        for id in ["se-state-protocol-small", "se-state-workflow-medium", "se-schema-er-small"] {
            let item = try #require(byID[id])
            let drawing = try await item.run()
            let snapshot = VisualSnapshot(case: item, drawing: drawing)
            let metrics = VisualGeometry.measure(snapshot)
            #expect(metrics.values["labelNodeOverlaps"] == 0, "\(id): label overlapped node")
            #expect(metrics.values["labelLabelOverlaps"] == 0, "\(id): label overlapped another label")
            #expect(snapshot.edges.contains { $0.label != nil && $0.labelBounds.width > 0 && $0.labelBounds.height > 0 })
        }

        // 4. Incremental expansion keeps all 32 existing nodes pinned while routing 13 new nodes cleanly
        let incCase = try #require(byID["se-incremental-expand-medium"])
        let incDrawing = try await incCase.run()
        #expect(incDrawing.fixedCenters.count == 32)
        for (id, expectedCenter) in incDrawing.fixedCenters {
            let actual = try #require(incDrawing.graph.nodes.first { $0.id == id }?.center)
            #expect((actual - expectedCenter).length <= 1e-6, "Pinned node \(id) moved during incremental expansion")
        }
        let incMetrics = VisualGeometry.measure(VisualSnapshot(case: incCase, drawing: incDrawing))
        #expect(incMetrics.failures.isEmpty)
    }

    @Test func engineeringSuiteExportsValidPNGReferencesAndGallery() async throws {
        #if os(macOS)
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let selected = try VisualEvaluation.selected(VisualCatalogue.all(), suite: "engineering", ids: [
            "se-arch-microservices-small", "se-deps-module-small", "se-state-protocol-small", "se-incremental-expand-medium"
        ])
        let manifest = try await VisualEvaluation.render(selected, output: dir, baselines: [:], command: ["test", "--suite", "engineering"], environment: [:])
        #expect(!manifest.failed)
        #expect(manifest.cases.count == 4)
        #expect(!manifest.contactSheets.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("report.md").path))

        for item in selected {
            let flatPNG = dir.appendingPathComponent("png/\(item.id).png")
            let casePNG = dir.appendingPathComponent("cases/\(item.id)/current.png")
            for url in [flatPNG, casePNG] {
                #expect(FileManager.default.fileExists(atPath: url.path), "Missing PNG at \(url.path)")
                let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
                let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect(image.width > 100 && image.height > 100)
                #expect(max(image.width, image.height) <= 2400)
            }
        }
        #endif
    }
}
