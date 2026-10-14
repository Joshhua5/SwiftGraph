import Foundation
import Testing
@testable import SwiftGraph
@testable import GraphEvaluationSupport

@Suite struct BackendComparativeBenchmarkTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("swiftgraph-comparative-benchmark-\(UUID().uuidString)")
    }

    @Test func comparativeCatalogueCoversAllSevenFamiliesAnd107Cases() throws {
        let all = BackendComparativeCatalogue.all()
        #expect(all.count == 107)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.allSatisfy { VisualStorage.safeID($0.id) })

        let countsByFamily = Dictionary(grouping: all, by: \.family).mapValues(\.count)
        #expect(countsByFamily["layouts"] == 28)
        #expect(countsByFamily["presets"] == 17)
        #expect(countsByFamily["routing"] == 12)
        #expect(countsByFamily["directed"] == 7)
        #expect(countsByFamily["organic-quality"] == 18)
        #expect(countsByFamily["frames"] == 4)
        #expect(countsByFamily["engineering"] == 21)

        #expect(try BackendComparativeCatalogue.selected(suite: "engineering", ids: []).count == 21)
        #expect(try BackendComparativeCatalogue.selected(suite: "frames", ids: []).count == 4)
        #expect(try BackendComparativeCatalogue.selected(suite: "full", ids: ["layout-tabular", "se-arch-microservices-medium"]).count == 2)
        #expect(throws: EvaluationError.self) {
            try BackendComparativeCatalogue.selected(suite: "full", ids: ["nonexistent-case"])
        }
    }

    @Test func comparativeEvaluationAcrossRepresentativeSuiteProducesValidOutputAndTimingMetrics() async throws {
        guard LayoutExecutor.isMetalAvailable else { return }
        let sampleIDs = [
            "layout-tabular",
            "layout-radial",
            "preset-standardHierarchical",
            "router-polyline",
            "directed-fresh",
            "organic-quality-grid",
            "frames-mixed-layouts",
            "se-arch-microservices-medium",
        ]
        let selected = try BackendComparativeCatalogue.selected(suite: "full", ids: sampleIDs)
        #expect(selected.count == sampleIDs.count)

        let report = try await BackendBenchmarkEvaluation.evaluate(cases: selected, trials: 2)
        #expect(report.totalCases == sampleIDs.count)
        #expect(report.families.map(\.qualityRegressionCount).reduce(0, +) == 0)
        #expect(report.families.count == 7)

        for result in report.cases {
            #expect(result.output.nodeCount > 0)
            #expect(result.output.parityClassification != .qualityRegression, "\(result.id) regressed quality: \(result.output.metalContractFailures.joined(separator: ", "))")
            #expect(result.output.cpuContractFailures.isEmpty, "\(result.id) CPU contract failures: \(result.output.cpuContractFailures.joined(separator: ", "))")
            #expect(result.output.metalContractFailures.isEmpty, "\(result.id) Metal contract failures: \(result.output.metalContractFailures.joined(separator: ", "))")
            #expect(result.output.rawNodeCenterRMS.isFinite)
            #expect(result.output.centroidAlignedNodeRMS.isFinite)
            #expect(result.timing.cpuColdMs > 0)
            #expect(result.timing.metalColdMs > 0)
            #expect(result.timing.cpuWarmMedianMs > 0)
            #expect(result.timing.metalWarmMedianMs > 0)
            #expect(result.timing.speedupVsCPU > 0)
        }
    }

    @Test func deterministicLayoutsExhibitParityAndSurfaceKnownMetalUnderutilizationFindings() async throws {
        guard LayoutExecutor.isMetalAvailable else { return }
        let diagnosticIDs = [
            "layout-clear-area",
            "layout-remove-overlaps",
            "layout-tree",
            "layout-swimlane",
            "router-channel",
            "directed-fresh",
            "frames-obstacle-detour",
            "se-arch-microservices-medium",
        ]
        let selected = try BackendComparativeCatalogue.selected(suite: "full", ids: diagnosticIDs)
        let report = try await BackendBenchmarkEvaluation.evaluate(cases: selected, trials: 2)
        let byID = Dictionary(uniqueKeysWithValues: report.cases.map { ($0.id, $0) })

        let clearArea = try #require(byID["layout-clear-area"])
        #expect(clearArea.timing.precisionLimitExceededDefault)
        #expect(clearArea.bottlenecks.contains { $0.kind == .precisionLimitFallback })
        #expect(clearArea.output.metalContractFailures.isEmpty)

        let removeOverlaps = try #require(byID["layout-remove-overlaps"])
        #expect(removeOverlaps.output.parityClassification == .exact || removeOverlaps.output.parityClassification == .floatEquivalent)
        #expect(removeOverlaps.timing.submittedBatches > 8)
        #expect(removeOverlaps.bottlenecks.contains { $0.kind == .highMicroDispatchOverhead })

        let tree = try #require(byID["layout-tree"])
        #expect(tree.output.parityClassification == .exact || tree.output.parityClassification == .floatEquivalent)
        #expect(!tree.bottlenecks.isEmpty)

        let channel = try #require(byID["router-channel"])
        #expect(channel.output.parityClassification == .exact || channel.output.parityClassification == .floatEquivalent)

        let directed = try #require(byID["directed-fresh"])
        #expect(directed.bottlenecks.contains { $0.kind == .unacceleratedPipelineStage })
        #expect(directed.timing.cpuStagesInMetalMode.contains { $0.contains("hierarchy-placement") || $0.contains("obstacle-routing") })

        let frameDetour = try #require(byID["frames-obstacle-detour"])
        #expect(frameDetour.output.parityClassification != .qualityRegression)
        #expect(frameDetour.output.metalContractFailures.isEmpty)

        let seArch = try #require(byID["se-arch-microservices-medium"])
        #expect(seArch.output.parityClassification != .qualityRegression)
        #expect(seArch.output.metalContractFailures.isEmpty)
    }

    @Test func benchmarkReportsAndVisualToolSubcommandWriteJSONMarkdownAndHTML() async throws {
        guard LayoutExecutor.isMetalAvailable else { return }
        let outDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outDir) }

        let code = await VisualTool.run(
            ["benchmark", "--suite", "frames", "--trials", "2", "--render-images", "false", "--output", outDir.path]
        )
        #expect(code == 0)

        let jsonURL = outDir.appendingPathComponent("benchmark-report.json")
        let mdURL = outDir.appendingPathComponent("benchmark-report.md")
        let htmlURL = outDir.appendingPathComponent("index.html")
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
        #expect(FileManager.default.fileExists(atPath: mdURL.path))
        #expect(FileManager.default.fileExists(atPath: htmlURL.path))

        let decoded = try JSONDecoder().decode(BackendComparativeReport.self, from: Data(contentsOf: jsonURL))
        #expect(decoded.totalCases == 4)
        #expect(decoded.families.map(\.qualityRegressionCount).reduce(0, +) == 0)

        let markdown = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(markdown.contains("# SwiftGraph CPU vs Metal Comparative Benchmark Report"))
        #expect(markdown.contains("frames-mixed-layouts"))

        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        #expect(html.contains("SwiftGraph CPU vs Metal Comparative Benchmark Report"))
        #expect(html.contains("frames-mixed-layouts"))
    }
}
