import Foundation
import SwiftGraph

#if canImport(CryptoKit)
import CryptoKit
#endif

public enum VisualTool {
    public static func run(_ arguments: [String]) async -> Int32 {
        do {
            let options = try VisualOptions(arguments)
            if options.command == "help" {
                print(VisualOptions.help)
                return 0
            }
            if options.command == "benchmark" {
                let allComparative = BackendComparativeCatalogue.all(includePerformance1024: options.suite == "full")
                let selected: [ComparativeDiagramCase]
                if !options.ids.isEmpty {
                    let unknown = Set(options.ids).subtracting(allComparative.map(\.id))
                    guard unknown.isEmpty else {
                        throw EvaluationError.message(
                            "Unknown comparative cases: \(unknown.sorted().joined(separator: ", "))"
                        )
                    }
                    selected = allComparative.filter { options.ids.contains($0.id) }
                } else {
                    switch options.suite {
                    case "full": selected = allComparative
                    case "smoke": selected = BackendComparativeCatalogue.smoke()
                    case "engineering", "frames", "layouts", "presets", "routing", "directed", "organic-quality":
                        selected = allComparative.filter { $0.family == options.suite }
                    default:
                        throw EvaluationError.message("Unknown benchmark suite: \(options.suite)")
                    }
                }
                let trials = Int(options.values["--trials"] ?? "3") ?? 3
                let renderImages = (options.values["--render-images"] ?? "false").lowercased() == "true"
                let outURL = URL(fileURLWithPath: options.values["--output"] ?? ".build/visual/benchmark")
                let report = try await BackendBenchmarkEvaluation.evaluate(
                    cases: selected,
                    trials: trials,
                    outputDirectory: outURL,
                    renderImages: renderImages
                )
                let regressions = report.cases.filter { $0.output.parityClassification == .qualityRegression }.count
                print(
                    "Benchmarked \(report.totalCases) cases (\(trials) warm trials). Report: \(outURL.appendingPathComponent("benchmark-report.md").path)"
                )
                return regressions > 0 ? 1 : 0
            }
            let catalogue = try VisualCatalogue.all()
            switch options.command {
            case "list":
                for item in try VisualEvaluation.selected(catalogue, suite: options.suite, ids: options.ids) {
                    print("\(item.id)\t\(item.family)\t\(item.title)")
                }
                return 0
            case "render":
                let baselines =
                    try options.values["--baseline"]
                    .map { try VisualStorage.collection(URL(fileURLWithPath: $0)).snapshots }
                    ?? VisualStorage.bundledBaselines()
                let result = try await VisualEvaluation.render(
                    VisualEvaluation.selected(catalogue, suite: options.suite, ids: options.ids),
                    output: options.output,
                    baselines: baselines,
                    command: arguments
                )
                print(
                    "\(result.cases.count) cases; \(result.cases.filter(\.failed).count) failed. Gallery: \(options.output.appendingPathComponent("index.html").path)"
                )
                return result.failed ? 1 : 0
            case "compare":
                let result = try VisualEvaluation.compare(
                    before: options.requiredURL("--before"),
                    after: options.requiredURL("--after"),
                    output: options.output,
                    ids: options.ids,
                    command: arguments
                )
                print("Comparison: \(options.output.appendingPathComponent("index.html").path)")
                return result.failed ? 1 : 0
            case "baseline":
                let count = try VisualEvaluation.accept(
                    from: options.requiredURL("--from"),
                    to: URL(fileURLWithPath: options.values["--output"] ?? "Tests/Fixtures/VisualBaselines"),
                    ids: options.ids
                )
                print("Updated \(count) explicitly selected baselines")
                return 0
            default: throw EvaluationError.message("Unknown command")
            }
        } catch {
            FileHandle.standardError.write(Data("graph-layout-visual: \(error)\n".utf8))
            return 2
        }
    }
}
