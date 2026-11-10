import Foundation
import SwiftGraph

#if canImport(CryptoKit)
import CryptoKit
#endif

enum VisualEvaluation {
    static func selected(_ cases: [VisualCase], suite: String, ids: [String]) throws -> [VisualCase] {
        guard ["smoke", "full", "engineering", "metal", "performance"].contains(suite) else {
            throw EvaluationError.message("Unknown suite: \(suite)")
        }
        if !ids.isEmpty {
            let unknown = Set(ids).subtracting(cases.map(\.id))
            guard unknown.isEmpty else {
                throw EvaluationError.message("Unknown cases: \(unknown.sorted().joined(separator: ", "))")
            }
            return cases.filter { ids.contains($0.id) }
        }
        if suite == "engineering" { return cases.filter { $0.family == "engineering" } }
        return cases.filter {
            suite == "performance"
                ? $0.family == "performance"
                : (suite == "metal"
                    ? $0.metal : (!$0.metal && $0.family != "performance" && (suite == "full" || $0.smoke)))
        }
    }

    static func render(
        _ cases: [VisualCase],
        output: URL,
        baselines: [String: VisualSnapshot],
        command: [String],
        environment: [String: String]? = nil
    ) async throws -> VisualManifest {
        try VisualStorage.prepareOutput(output)
        var manifest = VisualManifest(
            kind: "render",
            command: command,
            environment: environment ?? VisualStorage.environment(),
            cases: []
        )
        var snapshots: [VisualSnapshot] = []
        for item in cases {
            var row = VisualResult(id: item.id, family: item.family, title: item.title, status: "missing-baseline")
            if item.metal && !LayoutExecutor.isMetalAvailable {
                row.status = "skipped"
                row.error = "Metal is unavailable in this environment"
                manifest.cases.append(row)
                continue
            }
            let start = ContinuousClock.now
            do {
                let drawing = try await item.run()
                row.notes = drawing.notes
                var snapshot = VisualSnapshot(case: item, drawing: drawing)
                try VisualStorage.validate(snapshot)
                let dir = try VisualStorage.caseDirectory(output, item.id)
                var metrics = VisualGeometry.measure(snapshot)
                metrics.failures += drawing.additionalFailures
                snapshot.measuredMetrics = metrics.values
                try VisualStorage.writeJSON(snapshot, dir.appendingPathComponent("geometry.json"))
                try VisualStorage.writeJSON(metrics, dir.appendingPathComponent("metrics.json"))
                row.hasSnapshot = true
                row.metrics = metrics
                var scene = VisualScene(snapshot: snapshot)
                if let baseline = baselines[item.id] {
                    let difference = VisualComparison.compare(baseline, snapshot)
                    row.difference = difference
                    row.status = difference.changed || !difference.qualityFlags.isEmpty ? "changed" : "unchanged"
                    var before = VisualScene(snapshot: baseline)
                    let bounds = scene.bounds.union(before.bounds)
                    scene.bounds = bounds
                    before.bounds = bounds
                    try VisualRenderer.write(before, to: dir.appendingPathComponent("before"))
                    try VisualRenderer.write(
                        VisualScene.overlay(baseline, snapshot),
                        to: dir.appendingPathComponent("overlay")
                    )
                    row.hasBefore = true
                }
                if !metrics.failures.isEmpty { row.status = "contract-failure" }
                try VisualRenderer.write(scene, to: dir.appendingPathComponent("current"))
                try? FileManager.default.copyItem(
                    at: dir.appendingPathComponent("current.png"),
                    to: output.appendingPathComponent("png/\(item.id).png")
                )
                snapshots.append(snapshot)
            } catch {
                row.status = "error"
                row.error = String(describing: error)
            }
            let elapsed = start.duration(to: .now).components
            row.milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            manifest.cases.append(row)
            // Preserve progress even when a later case or export fails.
            try VisualStorage.writeJSON(manifest, output.appendingPathComponent("manifest.json"))
        }
        try finish(&manifest, snapshots: snapshots, output: output)
        return manifest
    }

    static func compare(before: URL, after: URL, output: URL, ids: [String], command: [String]) throws -> VisualManifest
    {
        var a = try VisualStorage.collection(before)
        var b = try VisualStorage.collection(after)
        // A baseline directory deliberately stores only curated cases; reference expectations stay in their original
        // corpus.
        if a.manifest == nil {
            a.snapshots.merge(
                Dictionary(uniqueKeysWithValues: try VisualCatalogue.referenceSnapshots().map { ($0.id, $0) }),
                uniquingKeysWith: { existing, _ in existing }
            )
        }
        let rows = Dictionary(uniqueKeysWithValues: (b.manifest?.cases ?? []).map { ($0.id, $0) })
        var all = Set(a.snapshots.keys).union(b.snapshots.keys).union(rows.keys)
        if !ids.isEmpty {
            guard Set(ids).isSubset(of: all) else { throw EvaluationError.message("Unknown comparison case") }
            all = all.intersection(ids)
        }
        try VisualStorage.prepareOutput(output)
        var manifest = VisualManifest(
            kind: "compare",
            command: command,
            environment: VisualStorage.environment(),
            cases: []
        )
        var snapshots: [VisualSnapshot] = []
        for id in all.sorted() {
            guard let current = b.snapshots[id] else {
                manifest.cases.append(
                    rows[id]
                        ?? VisualResult(
                            id: id,
                            family: a.snapshots[id]?.family ?? "unknown",
                            title: a.snapshots[id]?.title ?? id,
                            status: "removed"
                        )
                )
                continue
            }
            var row =
                rows[id]
                ?? VisualResult(id: id, family: current.family, title: current.title, status: "missing-baseline")
            row.hasSnapshot = true
            row.hasBefore = false
            row.difference = nil
            if !row.failed { row.status = "missing-baseline" }
            let recordedFailures = row.metrics?.failures ?? []
            row.metrics = VisualGeometry.measure(current)
            let extraFailures = recordedFailures.filter { !(row.metrics?.failures.contains($0) ?? false) }
            row.metrics?.failures += extraFailures
            do {
                let dir = try VisualStorage.caseDirectory(output, id)
                try VisualStorage.writeJSON(current, dir.appendingPathComponent("geometry.json"))
                try VisualStorage.writeJSON(row.metrics!, dir.appendingPathComponent("metrics.json"))
                var scene = VisualScene(snapshot: current)
                if let previous = a.snapshots[id] {
                    let diff = VisualComparison.compare(previous, current)
                    row.difference = diff
                    if !row.failed { row.status = diff.changed || !diff.qualityFlags.isEmpty ? "changed" : "unchanged" }
                    var beforeScene = VisualScene(snapshot: previous)
                    let bounds = scene.bounds.union(beforeScene.bounds)
                    scene.bounds = bounds
                    beforeScene.bounds = bounds
                    try VisualRenderer.write(beforeScene, to: dir.appendingPathComponent("before"))
                    try VisualRenderer.write(
                        VisualScene.overlay(previous, current),
                        to: dir.appendingPathComponent("overlay")
                    )
                    row.hasBefore = true
                }
                if !(row.metrics?.failures.isEmpty ?? true) && row.status != "error" { row.status = "contract-failure" }
                try VisualRenderer.write(scene, to: dir.appendingPathComponent("current"))
                try? FileManager.default.copyItem(
                    at: dir.appendingPathComponent("current.png"),
                    to: output.appendingPathComponent("png/\(id).png")
                )
                snapshots.append(current)
            } catch {
                row.status = "error"
                row.error = String(describing: error)
            }
            manifest.cases.append(row)
            try VisualStorage.writeJSON(manifest, output.appendingPathComponent("manifest.json"))
        }
        try finish(&manifest, snapshots: snapshots, output: output)
        return manifest
    }

    static func accept(from input: URL, to output: URL, ids: [String]) throws -> Int {
        guard !ids.isEmpty else {
            throw EvaluationError.message("Baseline updates require at least one explicit --case")
        }
        let data = try VisualStorage.collection(input)
        guard let manifest = data.manifest, manifest.kind == "render" else {
            throw EvaluationError.message("Baselines must come from a render run")
        }
        let rows = Dictionary(uniqueKeysWithValues: manifest.cases.map { ($0.id, $0) })
        for id in ids {
            guard let s = data.snapshots[id], let row = rows[id], !row.failed, row.status != "skipped",
                s.family != "reference", s.family != "metal"
            else {
                throw EvaluationError.message("Cannot accept \(id): missing, failed, reference, or Metal case")
            }
            guard VisualGeometry.measure(s).failures.isEmpty else {
                throw EvaluationError.message("Cannot accept \(id): geometry violates its contracts")
            }
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for id in Set(ids).sorted() {
            var snapshot = data.snapshots[id]!
            snapshot.measuredMetrics = VisualGeometry.measure(snapshot).values
            try VisualStorage.writeJSON(snapshot, output.appendingPathComponent("\(id).json"))
        }
        return Set(ids).count
    }

    static func finish(_ manifest: inout VisualManifest, snapshots: [VisualSnapshot], output: URL) throws {
        for offset in stride(from: 0, to: snapshots.count, by: 12) {
            let name = "contact-\(offset / 12 + 1)"
            do {
                try VisualRenderer.write(
                    VisualScene.contactSheet(Array(snapshots[offset..<min(snapshots.count, offset + 12)])),
                    to: output.appendingPathComponent(name)
                )
                manifest.contactSheets.append(name + ".png")
            } catch {
                manifest.cases.append(
                    VisualResult(
                        id: "export-\(name)",
                        family: "export",
                        title: name,
                        status: "error",
                        error: String(describing: error)
                    )
                )
            }
        }
        try VisualStorage.writeJSON(manifest, output.appendingPathComponent("manifest.json"))
        try VisualGallery.html(manifest)
            .write(to: output.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try VisualGallery.report(manifest)
            .write(to: output.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }
}
