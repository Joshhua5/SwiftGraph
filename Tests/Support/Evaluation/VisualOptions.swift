import Foundation
import SwiftGraph

#if canImport(CryptoKit)
import CryptoKit
#endif

struct VisualOptions {
    var command: String
    var values: [String: String] = [:]
    var ids: [String] = []
    var suite: String { values["--suite"] ?? "full" }
    var output: URL { URL(fileURLWithPath: values["--output"] ?? ".build/visual/current") }

    init(_ args: [String]) throws {
        command = args.first ?? "help"
        if command == "--help" || args.contains("--help") {
            command = "help"
            return
        }
        let allowed: [String: Set<String>] = [
            "list": ["--suite", "--case"],
            "render": ["--suite", "--case", "--output", "--baseline"],
            "compare": ["--before", "--after", "--output", "--case"],
            "baseline": ["--from", "--output", "--case"],
            "benchmark": ["--suite", "--case", "--trials", "--output", "--render-images"],
            "help": [],
        ]
        guard let flags = allowed[command] else {
            throw EvaluationError.message("Unknown command '\(command)'. Use --help.")
        }
        var i = 1
        while i < args.count {
            let flag = args[i]
            guard flags.contains(flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                throw EvaluationError.message("Unknown option or missing value: \(flag)")
            }
            if flag == "--case" {
                ids.append(args[i + 1])
            } else {
                guard values[flag] == nil else { throw EvaluationError.message("Repeated option: \(flag)") }
                values[flag] = args[i + 1]
            }
            i += 2
        }
    }

    func requiredURL(_ flag: String) throws -> URL {
        guard let path = values[flag] else { throw EvaluationError.message("Missing \(flag)") }
        return URL(fileURLWithPath: path)
    }
    static let help = """
        graph-layout-visual list [--suite full|smoke|engineering|metal|performance] [--case ID ...]
        graph-layout-visual render [--suite full|smoke|engineering|metal|performance] [--case ID ...] [--output DIR] [--baseline DIR]
        graph-layout-visual compare --before DIR --after DIR --output DIR [--case ID ...]
        graph-layout-visual baseline --from RUN --case ID [--case ID ...] [--output DIR]
        graph-layout-visual benchmark [--suite full|smoke|engineering|frames|layouts|presets|routing|directed|organic-quality] [--case ID ...] [--trials N] [--output DIR] [--render-images true|false]

        Render defaults: full CPU suite, .build/visual/current, bundled baselines.
        --case overrides suite selection. Output directories must be new or empty.
        Baseline updates default to Tests/Fixtures/VisualBaselines (run from the repo root).
        PNG export requires macOS. Exit codes: 0 success/review flags, 1 contract/export failures, 2 command/input errors.
        """
}
