import Foundation
import SwiftGraph
#if canImport(CryptoKit)
import CryptoKit
#endif

enum EvaluationError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let message): message } }
}

struct VisualDifference: Codable, Equatable {
    var changedNodes: [String] = []
    var changedEdges: [String] = []
    var configurationChanged = false
    var metricDeltas: [String: Double] = [:]
    var qualityFlags: [String] = []
    var changed: Bool { !changedNodes.isEmpty || !changedEdges.isEmpty || configurationChanged }
}

enum VisualComparison {
    static func equal(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-6 }
    static func equal(_ a: Float, _ b: Float) -> Bool { abs(a - b) <= 1e-5 }
    static func equal(_ a: Point, _ b: Point) -> Bool { equal(a.x, b.x) && equal(a.y, b.y) }
    static func equal(_ a: Rect, _ b: Rect) -> Bool { equal(a.x, b.x) && equal(a.y, b.y) && equal(a.width, b.width) && equal(a.height, b.height) }
    static func equal(_ a: Rect?, _ b: Rect?) -> Bool {
        switch (a, b) { case let (a?, b?): equal(a, b); case (nil, nil): true; default: false }
    }
    static func compare(_ before: VisualSnapshot, _ after: VisualSnapshot) -> VisualDifference {
        var diff = VisualDifference()
        let aNodes = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
        let bNodes = Dictionary(uniqueKeysWithValues: after.nodes.map { ($0.id, $0) })
        for id in Set(aNodes.keys).union(bNodes.keys).sorted() {
            guard let a = aNodes[id], let b = bNodes[id] else { diff.changedNodes.append(id); continue }
            if !equal(a.bounds, b.bounds) || !equal(a.contentBounds, b.contentBounds) || !equal(a.headerBounds, b.headerBounds)
                || a.name != b.name || a.parent != b.parent || a.group != b.group { diff.changedNodes.append(id) }
        }
        let aEdges = Dictionary(uniqueKeysWithValues: before.edges.map { ($0.id, $0) })
        let bEdges = Dictionary(uniqueKeysWithValues: after.edges.map { ($0.id, $0) })
        for id in Set(aEdges.keys).union(bEdges.keys).sorted() {
            guard let a = aEdges[id], let b = bEdges[id] else { diff.changedEdges.append(id); continue }
            if a.source != b.source || a.target != b.target || a.path.count != b.path.count || !zip(a.path, b.path).allSatisfy({ equal($0, $1) })
                || a.label != b.label || !equal(a.labelBounds, b.labelBounds) || !equal(a.width, b.width)
                || (a.bidirectional ?? false) != (b.bidirectional ?? false) { diff.changedEdges.append(id) }
        }
        // Reference fixtures describe raw geometry, not the visual tool's recipe metadata.
        diff.configurationChanged = after.family != "reference" && (before.configuration != after.configuration || before.contracts != after.contracts)
        let a = VisualGeometry.measure(before).values, b = VisualGeometry.measure(after).values
        let lowerIsUsuallyBetter: Set<String> = ["nodeOverlaps", "edgeNodeIntersections", "crossings", "sharedSegments", "missingRoutes", "fallbackRoutes", "labelNodeOverlaps", "labelLabelOverlaps", "bends", "routeLength", "displacement",
                                                   "nearParallelRuns", "endpointsInsideNodes", "endpointsAtCorners", "microSegments"]
        let higherIsUsuallyBetter: Set<String> = ["minEdgeNodeClearance"]
        for key in Set(a.keys).union(b.keys).sorted() {
            // The C# corpus stores paths and bounds, but no fallback classifications.
            if before.configuration["oracle"] == "csharp-paths-and-bounds" && key == "fallbackRoutes" { continue }
            // Clearance is absent when a drawing has no edge/node pair, so it is only comparable when both sides report it.
            if higherIsUsuallyBetter.contains(key) && (a[key] == nil || b[key] == nil) { continue }
            let delta = b[key, default: 0] - a[key, default: 0]
            if abs(delta) > 1e-6 {
                diff.metricDeltas[key] = delta
                if (delta > 0 && lowerIsUsuallyBetter.contains(key)) || (delta < 0 && higherIsUsuallyBetter.contains(key)) { diff.qualityFlags.append(key) }
            }
        }
        return diff
    }
}

struct VisualResult: Codable {
    var id: String
    var family: String
    var title: String
    var status: String
    var milliseconds: Double = 0
    var metrics: VisualMetrics?
    var difference: VisualDifference?
    var error: String?
    var hasSnapshot = false
    var hasBefore = false
    var notes: [String]?
    var failed: Bool { status == "contract-failure" || status == "error" }
}

struct VisualManifest: Codable {
    var version = 1
    var kind: String
    var command: [String]
    var environment: [String: String]
    var cases: [VisualResult]
    var contactSheets: [String] = []
    var failed: Bool { cases.contains(where: \.failed) }
}

enum VisualStorage {
    static func writeJSON<T: Encodable>(_ value: T, _ url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value); data.append(10); try data.write(to: url, options: .atomic)
    }
    static func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
    static func safeID(_ id: String) -> Bool { !id.isEmpty && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } }
    static func validate(_ s: VisualSnapshot) throws {
        guard s.version == 1, safeID(s.id), s.isFinite,
              Set(s.nodes.map(\.id)).count == s.nodes.count, Set(s.edges.map(\.id)).count == s.edges.count else {
            throw EvaluationError.message("Invalid or unsupported snapshot: \(s.id)")
        }
        let ids = Set(s.nodes.map(\.id))
        guard s.edges.allSatisfy({ ids.contains($0.source) && ids.contains($0.target) }) else { throw EvaluationError.message("Unknown edge endpoint in \(s.id)") }
    }
    static func prepareOutput(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path), !(try FileManager.default.contentsOfDirectory(atPath: url.path)).isEmpty {
            throw EvaluationError.message("Output directory is not empty: \(url.path). Use a new run directory to preserve prior evidence.")
        }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("cases"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("png"), withIntermediateDirectories: true)
    }
    static func caseDirectory(_ output: URL, _ id: String) throws -> URL {
        guard safeID(id) else { throw EvaluationError.message("Invalid case ID: \(id)") }
        let dir = output.appendingPathComponent("cases").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); return dir
    }
    static func collection(_ directory: URL) throws -> (snapshots: [String: VisualSnapshot], manifest: VisualManifest?) {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var snapshots: [String: VisualSnapshot] = [:]
        let manifest: VisualManifest?
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try readJSON(VisualManifest.self, manifestURL)
            guard manifest!.version == 1 else { throw EvaluationError.message("Unsupported manifest version") }
            guard Set(manifest!.cases.map(\.id)).count == manifest!.cases.count else { throw EvaluationError.message("Duplicate manifest case IDs") }
            for row in manifest!.cases where row.hasSnapshot {
                guard safeID(row.id) else { throw EvaluationError.message("Invalid case ID") }
                let snapshot = try readJSON(VisualSnapshot.self, directory.appendingPathComponent("cases/\(row.id)/geometry.json"))
                try validate(snapshot)
                guard snapshot.id == row.id else { throw EvaluationError.message("Snapshot ID differs from manifest") }
                snapshots[row.id] = snapshot
            }
        } else {
            manifest = nil
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
                let snapshot = try readJSON(VisualSnapshot.self, url); try validate(snapshot)
                guard snapshots[snapshot.id] == nil else { throw EvaluationError.message("Duplicate snapshot ID") }
                snapshots[snapshot.id] = snapshot
            }
        }
        return (snapshots, manifest)
    }
    static func bundledBaselines() throws -> [String: VisualSnapshot] {
        var result = Dictionary(uniqueKeysWithValues: try VisualCatalogue.referenceSnapshots().map { ($0.id, $0) })
        if let directory = Bundle.module.url(forResource: "VisualBaselines", withExtension: nil, subdirectory: "Fixtures") {
            result.merge(try collection(directory).snapshots, uniquingKeysWith: { _, b in b })
        }
        return result
    }
    static func environment() -> [String: String] {
        func command(_ program: String, _ args: [String]) -> String {
            #if os(macOS) || os(Linux)
            let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: program); p.arguments = args; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            do { try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown" }
            catch { return "unknown" }
            #else
            return "unavailable on this platform"
            #endif
        }
        var fingerprint = "unavailable outside the source checkout"
        #if canImport(CryptoKit)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files = [root.appendingPathComponent("Package.swift")]
        for path in ["Sources/SwiftGraph", "Tests/Support"] {
            if let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(path), includingPropertiesForKeys: nil) {
                files += enumerator.compactMap { $0 as? URL }.filter { ["swift", "metal"].contains($0.pathExtension) }
            }
        }
        var hash = SHA256(), complete = true
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: file) else { complete = false; break }
            hash.update(data: Data(file.path.replacingOccurrences(of: root.path + "/", with: "").utf8)); hash.update(data: Data([0])); hash.update(data: data)
        }
        if complete { fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined() }
        #endif
        return ["os": ProcessInfo.processInfo.operatingSystemVersionString, "renderer": "scene-v1; Helvetica; PNG max 2400px; SVG world coordinates",
                "catalogue": "v1", "swift": command("/usr/bin/env", ["swift", "--version"]),
                "sourceTreeSHA256": fingerprint,
                "revision": command("/usr/bin/git", ["rev-parse", "HEAD"]), "workingTree": command("/usr/bin/git", ["status", "--porcelain"])]
    }
}

enum VisualEvaluation {
    static func selected(_ cases: [VisualCase], suite: String, ids: [String]) throws -> [VisualCase] {
        guard ["smoke", "full", "engineering", "metal", "performance"].contains(suite) else { throw EvaluationError.message("Unknown suite: \(suite)") }
        if !ids.isEmpty {
            let unknown = Set(ids).subtracting(cases.map(\.id))
            guard unknown.isEmpty else { throw EvaluationError.message("Unknown cases: \(unknown.sorted().joined(separator: ", "))") }
            return cases.filter { ids.contains($0.id) }
        }
        if suite == "engineering" { return cases.filter { $0.family == "engineering" } }
        return cases.filter { suite == "performance" ? $0.family == "performance" : (suite == "metal" ? $0.metal : (!$0.metal && $0.family != "performance" && (suite == "full" || $0.smoke))) }
    }
    static func render(_ cases: [VisualCase], output: URL, baselines: [String: VisualSnapshot], command: [String], environment: [String: String]? = nil) async throws -> VisualManifest {
        try VisualStorage.prepareOutput(output)
        var manifest = VisualManifest(kind: "render", command: command, environment: environment ?? VisualStorage.environment(), cases: [])
        var snapshots: [VisualSnapshot] = []
        for item in cases {
            var row = VisualResult(id: item.id, family: item.family, title: item.title, status: "missing-baseline")
            if item.metal && !LayoutExecutor.isMetalAvailable {
                row.status = "skipped"; row.error = "Metal is unavailable in this environment"; manifest.cases.append(row); continue
            }
            let start = ContinuousClock.now
            do {
                let drawing = try await item.run()
                row.notes = drawing.notes
                var snapshot = VisualSnapshot(case: item, drawing: drawing)
                try VisualStorage.validate(snapshot)
                let dir = try VisualStorage.caseDirectory(output, item.id)
                var metrics = VisualGeometry.measure(snapshot); metrics.failures += drawing.additionalFailures
                snapshot.measuredMetrics = metrics.values
                try VisualStorage.writeJSON(snapshot, dir.appendingPathComponent("geometry.json"))
                try VisualStorage.writeJSON(metrics, dir.appendingPathComponent("metrics.json"))
                row.hasSnapshot = true; row.metrics = metrics
                var scene = VisualScene(snapshot: snapshot)
                if let baseline = baselines[item.id] {
                    let difference = VisualComparison.compare(baseline, snapshot); row.difference = difference
                    row.status = difference.changed || !difference.qualityFlags.isEmpty ? "changed" : "unchanged"
                    var before = VisualScene(snapshot: baseline); let bounds = scene.bounds.union(before.bounds); scene.bounds = bounds; before.bounds = bounds
                    try VisualRenderer.write(before, to: dir.appendingPathComponent("before"))
                    try VisualRenderer.write(VisualScene.overlay(baseline, snapshot), to: dir.appendingPathComponent("overlay")); row.hasBefore = true
                }
                if !metrics.failures.isEmpty { row.status = "contract-failure" }
                try VisualRenderer.write(scene, to: dir.appendingPathComponent("current"))
                try? FileManager.default.copyItem(at: dir.appendingPathComponent("current.png"), to: output.appendingPathComponent("png/\(item.id).png"))
                snapshots.append(snapshot)
            } catch {
                row.status = "error"; row.error = String(describing: error)
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
    static func compare(before: URL, after: URL, output: URL, ids: [String], command: [String]) throws -> VisualManifest {
        var a = try VisualStorage.collection(before), b = try VisualStorage.collection(after)
        // A baseline directory deliberately stores only curated cases; reference expectations stay in their original corpus.
        if a.manifest == nil { a.snapshots.merge(Dictionary(uniqueKeysWithValues: try VisualCatalogue.referenceSnapshots().map { ($0.id, $0) }), uniquingKeysWith: { existing, _ in existing }) }
        let rows = Dictionary(uniqueKeysWithValues: (b.manifest?.cases ?? []).map { ($0.id, $0) })
        var all = Set(a.snapshots.keys).union(b.snapshots.keys).union(rows.keys)
        if !ids.isEmpty {
            guard Set(ids).isSubset(of: all) else { throw EvaluationError.message("Unknown comparison case") }
            all = all.intersection(ids)
        }
        try VisualStorage.prepareOutput(output)
        var manifest = VisualManifest(kind: "compare", command: command, environment: VisualStorage.environment(), cases: [])
        var snapshots: [VisualSnapshot] = []
        for id in all.sorted() {
            guard let current = b.snapshots[id] else {
                manifest.cases.append(rows[id] ?? VisualResult(id: id, family: a.snapshots[id]?.family ?? "unknown", title: a.snapshots[id]?.title ?? id, status: "removed")); continue
            }
            var row = rows[id] ?? VisualResult(id: id, family: current.family, title: current.title, status: "missing-baseline")
            row.hasSnapshot = true; row.hasBefore = false; row.difference = nil
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
                let diff = VisualComparison.compare(previous, current); row.difference = diff
                if !row.failed { row.status = diff.changed || !diff.qualityFlags.isEmpty ? "changed" : "unchanged" }
                var beforeScene = VisualScene(snapshot: previous); let bounds = scene.bounds.union(beforeScene.bounds); scene.bounds = bounds; beforeScene.bounds = bounds
                try VisualRenderer.write(beforeScene, to: dir.appendingPathComponent("before"))
                try VisualRenderer.write(VisualScene.overlay(previous, current), to: dir.appendingPathComponent("overlay")); row.hasBefore = true
            }
            if !(row.metrics?.failures.isEmpty ?? true) && row.status != "error" { row.status = "contract-failure" }
            try VisualRenderer.write(scene, to: dir.appendingPathComponent("current"))
            try? FileManager.default.copyItem(at: dir.appendingPathComponent("current.png"), to: output.appendingPathComponent("png/\(id).png"))
            snapshots.append(current)
            } catch { row.status = "error"; row.error = String(describing: error) }
            manifest.cases.append(row)
            try VisualStorage.writeJSON(manifest, output.appendingPathComponent("manifest.json"))
        }
        try finish(&manifest, snapshots: snapshots, output: output); return manifest
    }
    static func accept(from input: URL, to output: URL, ids: [String]) throws -> Int {
        guard !ids.isEmpty else { throw EvaluationError.message("Baseline updates require at least one explicit --case") }
        let data = try VisualStorage.collection(input)
        guard let manifest = data.manifest, manifest.kind == "render" else { throw EvaluationError.message("Baselines must come from a render run") }
        let rows = Dictionary(uniqueKeysWithValues: manifest.cases.map { ($0.id, $0) })
        for id in ids {
            guard let s = data.snapshots[id], let row = rows[id], !row.failed, row.status != "skipped", s.family != "reference", s.family != "metal" else {
                throw EvaluationError.message("Cannot accept \(id): missing, failed, reference, or Metal case")
            }
            guard VisualGeometry.measure(s).failures.isEmpty else { throw EvaluationError.message("Cannot accept \(id): geometry violates its contracts") }
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for id in Set(ids).sorted() {
            var snapshot = data.snapshots[id]!; snapshot.measuredMetrics = VisualGeometry.measure(snapshot).values
            try VisualStorage.writeJSON(snapshot, output.appendingPathComponent("\(id).json"))
        }
        return Set(ids).count
    }
    static func finish(_ manifest: inout VisualManifest, snapshots: [VisualSnapshot], output: URL) throws {
        for offset in stride(from: 0, to: snapshots.count, by: 12) {
            let name = "contact-\(offset / 12 + 1)"
            do {
                try VisualRenderer.write(VisualScene.contactSheet(Array(snapshots[offset..<min(snapshots.count, offset + 12)])), to: output.appendingPathComponent(name))
                manifest.contactSheets.append(name + ".png")
            } catch {
                manifest.cases.append(VisualResult(id: "export-\(name)", family: "export", title: name, status: "error", error: String(describing: error)))
            }
        }
        try VisualStorage.writeJSON(manifest, output.appendingPathComponent("manifest.json"))
        try VisualGallery.html(manifest).write(to: output.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try VisualGallery.report(manifest).write(to: output.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }
}

enum VisualGallery {
    static func currentFindings(_ row: VisualResult) -> String {
        let counts = Dictionary(grouping: row.metrics?.findings ?? [], by: \.kind).mapValues(\.count)
        return counts.keys.sorted().map { "\($0): \(counts[$0]!)" }.joined(separator: ", ")
    }

    static func report(_ run: VisualManifest) -> String {
        var lines = ["# SwiftGraph visual evaluation", "", "\(run.cases.count) cases · \(run.cases.filter(\.failed).count) failed · \(run.cases.filter { $0.status == "changed" }.count) changed · \(run.cases.filter { $0.status == "skipped" }.count) skipped", "", "Open [the gallery](index.html) for images, overlays and detailed metrics.", "", "| Case | Status | Current findings | Review increases |", "| --- | --- | --- | --- |"]
        for row in run.cases { lines.append("| \(row.id) | \(row.status) | \(currentFindings(row)) | \((row.difference?.qualityFlags ?? []).joined(separator: ", ")) \(row.error?.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/") ?? "") |") }
        lines += ["", "## Agent review", "", "Inspect flagged cases and contact sheets. For each finding record: case ID, severity, image/element evidence, proposed change, and before/after outcome. Increased metrics are review prompts, not a universal quality score. Never accept a baseline solely to silence a finding.", ""]
        return lines.joined(separator: "\n")
    }
    static func html(_ run: VisualManifest) -> String {
        let esc = VisualRenderer.escape
        var body = """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>SwiftGraph visual evaluation</title><style>
        *{box-sizing:border-box}body{margin:0;background:#f1f5f9;color:#0f172a;font:14px system-ui,sans-serif}header{padding:24px 32px;background:#0f172a;color:white}main{padding:24px;max-width:1600px;margin:auto}h1{margin:0 0 8px}a{color:#2563eb}header a{color:#93c5fd}.filters{position:sticky;top:0;background:#e2e8f0;padding:14px;z-index:2;display:flex;gap:12px;flex-wrap:wrap}input,select{padding:8px;border:1px solid #94a3b8;border-radius:4px}.case{background:white;border:1px solid #cbd5e1;border-radius:8px;margin:18px 0;padding:20px}.case[data-status=contract-failure],.case[data-status=error]{border:2px solid #dc2626}.status{font:12px monospace;background:#e2e8f0;padding:4px 8px;border-radius:4px}.images{display:flex;gap:16px}.images figure{flex:1;min-width:0;margin:12px 0}.images img{width:100%;height:360px;object-fit:contain;border:1px solid #e2e8f0}figcaption{color:#475569;margin:6px 0}table{border-collapse:collapse}td,th{text-align:left;padding:5px 12px;border-bottom:1px solid #e2e8f0}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px}.sheets{display:flex;gap:12px;flex-wrap:wrap}.sheets img{width:240px;border:1px solid #cbd5e1}.warning{color:#9a3412}summary{cursor:pointer;margin:10px 0}small{color:#64748b}[hidden]{display:none!important}@media(max-width:700px){.images{display:block}main{padding:10px}}</style>
        <header><h1>SwiftGraph visual evaluation</h1><div>\(run.cases.count) cases · \(run.cases.filter(\.failed).count) failed · Geometry contracts fail; visual changes invite review.</div><p><a href="manifest.json">Manifest</a> · <a href="report.md">Review report</a></p></header><main>
        <div class="filters"><input id="search" placeholder="Find a case" aria-label="Find a case"><select id="family" aria-label="Family"><option value="">All families</option>
        """
        for family in Set(run.cases.map(\.family)).sorted() { body += "<option>\(esc(family))</option>" }
        body += "</select><select id=\"status\" aria-label=\"Status\"><option value=\"\">All statuses</option>"
        for status in Set(run.cases.map(\.status)).sorted() { body += "<option>\(esc(status))</option>" }
        body += "</select><span id=\"count\"></span></div><details><summary>Contact sheets</summary><div class=\"sheets\">"
        for sheet in run.contactSheets { body += "<a href=\"\(esc(sheet))\"><img loading=\"lazy\" src=\"\(esc(sheet))\" alt=\"Contact sheet\"></a>" }
        body += "</div></details>"
        for row in run.cases {
            let dir = "cases/\(row.id)"
            body += "<article class=\"case\" data-family=\"\(esc(row.family))\" data-status=\"\(esc(row.status))\"><span class=\"status\">\(esc(row.status))</span><h2>\(esc(row.id))</h2><p>\(esc(row.title))</p>"
            if let notes = row.notes, !notes.isEmpty {
                body += "<details><summary>Execution and presentation notes</summary><ul>"
                for note in notes { body += "<li>\(esc(note))</li>" }
                body += "</ul></details>"
            }
            let findings = currentFindings(row)
            if !findings.isEmpty { body += "<p class=\"warning\">Current findings: \(esc(findings))</p>" }
            if let error = row.error { body += "<pre class=\"warning\">\(esc(error))</pre>" }
            if let diff = row.difference {
                body += "<p>Changed nodes: \(esc(diff.changedNodes.joined(separator: ", "))) · Changed edges: \(esc(diff.changedEdges.joined(separator: ", ")))\(diff.configurationChanged ? " · Recipe changed" : "")</p>"
                if !diff.qualityFlags.isEmpty { body += "<p class=\"warning\">Review increases: \(esc(diff.qualityFlags.joined(separator: ", ")))</p>" }
            }
            if row.hasSnapshot {
                body += "<div class=\"images\">"
                for name in row.hasBefore ? ["before", "current"] : ["current"] {
                    body += "<figure><a href=\"\(dir)/\(name).svg\"><img loading=\"lazy\" src=\"\(dir)/\(name).png\" alt=\"\(esc(row.id)) \(name)\"></a><figcaption>\(name) · <a href=\"\(dir)/\(name).svg\">Zoom SVG</a> · <a href=\"\(dir)/\(name).png\">PNG</a></figcaption></figure>"
                }
                body += "</div><p><a href=\"\(dir)/geometry.json\">Geometry</a> · <a href=\"\(dir)/metrics.json\">Metrics</a>"
                if row.hasBefore { body += " · <a href=\"\(dir)/overlay.svg\">Overlay (magenta before, cyan current)</a>" }; body += "</p>"
            }
            if let metrics = row.metrics {
                if !metrics.failures.isEmpty { body += "<pre class=\"warning\">" + esc(metrics.failures.map { "\($0.kind): \($0.elements.joined(separator: ", "))" }.joined(separator: "\n")) + "</pre>" }
                body += "<details><summary>Metrics and diagnostics</summary><table><tr><th>Metric</th><th>Current</th><th>Delta</th></tr>"
                for key in metrics.values.keys.sorted() {
                    body += "<tr><td>\(esc(key))</td><td>\(VisualRenderer.number(metrics.values[key]!))</td><td>\(VisualRenderer.number(row.difference?.metricDeltas[key] ?? 0))</td></tr>"
                }
                body += "</table><pre>" + esc(metrics.findings.map { "\($0.kind): \($0.elements.joined(separator: ", "))" }.joined(separator: "\n")) + "</pre></details>"
            }
            body += "</article>"
        }
        body += """
        <script>const controls=['search','family','status'].map(id=>document.getElementById(id));function filter(){let n=0;document.querySelectorAll('.case').forEach(card=>{const show=card.textContent.toLowerCase().includes(controls[0].value.toLowerCase())&&(!controls[1].value||card.dataset.family===controls[1].value)&&(!controls[2].value||card.dataset.status===controls[2].value);card.hidden=!show;if(show)n++;});document.getElementById('count').textContent=n+' visible';}controls.forEach(c=>c.addEventListener('input',filter));filter();</script></main></html>
        """
        return body
    }
}

public enum VisualTool {
    public static func run(_ arguments: [String]) async -> Int32 {
        do {
            let options = try VisualOptions(arguments)
            if options.command == "help" { print(VisualOptions.help); return 0 }
            if options.command == "benchmark" {
                let allComparative = BackendComparativeCatalogue.all(includePerformance1024: options.suite == "full")
                let selected: [ComparativeDiagramCase]
                if !options.ids.isEmpty {
                    let unknown = Set(options.ids).subtracting(allComparative.map(\.id))
                    guard unknown.isEmpty else {
                        throw EvaluationError.message("Unknown comparative cases: \(unknown.sorted().joined(separator: ", "))")
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
                print("Benchmarked \(report.totalCases) cases (\(trials) warm trials). Report: \(outURL.appendingPathComponent("benchmark-report.md").path)")
                return regressions > 0 ? 1 : 0
            }
            let catalogue = try VisualCatalogue.all()
            switch options.command {
            case "list":
                for item in try VisualEvaluation.selected(catalogue, suite: options.suite, ids: options.ids) { print("\(item.id)\t\(item.family)\t\(item.title)") }
                return 0
            case "render":
                let baselines = try options.values["--baseline"].map { try VisualStorage.collection(URL(fileURLWithPath: $0)).snapshots } ?? VisualStorage.bundledBaselines()
                let result = try await VisualEvaluation.render(VisualEvaluation.selected(catalogue, suite: options.suite, ids: options.ids), output: options.output, baselines: baselines, command: arguments)
                print("\(result.cases.count) cases; \(result.cases.filter(\.failed).count) failed. Gallery: \(options.output.appendingPathComponent("index.html").path)")
                return result.failed ? 1 : 0
            case "compare":
                let result = try VisualEvaluation.compare(before: options.requiredURL("--before"), after: options.requiredURL("--after"), output: options.output, ids: options.ids, command: arguments)
                print("Comparison: \(options.output.appendingPathComponent("index.html").path)"); return result.failed ? 1 : 0
            case "baseline":
                let count = try VisualEvaluation.accept(from: options.requiredURL("--from"), to: URL(fileURLWithPath: options.values["--output"] ?? "Tests/Fixtures/VisualBaselines"), ids: options.ids)
                print("Updated \(count) explicitly selected baselines"); return 0
            default: throw EvaluationError.message("Unknown command")
            }
        } catch { FileHandle.standardError.write(Data("graph-layout-visual: \(error)\n".utf8)); return 2 }
    }
}

struct VisualOptions {
    var command: String
    var values: [String: String] = [:]
    var ids: [String] = []
    var suite: String { values["--suite"] ?? "full" }
    var output: URL { URL(fileURLWithPath: values["--output"] ?? ".build/visual/current") }
    init(_ args: [String]) throws {
        command = args.first ?? "help"
        if command == "--help" || args.contains("--help") { command = "help"; return }
        let allowed: [String: Set<String>] = [
            "list": ["--suite", "--case"],
            "render": ["--suite", "--case", "--output", "--baseline"],
            "compare": ["--before", "--after", "--output", "--case"],
            "baseline": ["--from", "--output", "--case"],
            "benchmark": ["--suite", "--case", "--trials", "--output", "--render-images"],
            "help": []
        ]
        guard let flags = allowed[command] else { throw EvaluationError.message("Unknown command '\(command)'. Use --help.") }
        var i = 1
        while i < args.count {
            let flag = args[i]
            guard flags.contains(flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw EvaluationError.message("Unknown option or missing value: \(flag)") }
            if flag == "--case" { ids.append(args[i + 1]) }
            else {
                guard values[flag] == nil else { throw EvaluationError.message("Repeated option: \(flag)") }
                values[flag] = args[i + 1]
            }; i += 2
        }
    }
    func requiredURL(_ flag: String) throws -> URL {
        guard let path = values[flag] else { throw EvaluationError.message("Missing \(flag)") }; return URL(fileURLWithPath: path)
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
