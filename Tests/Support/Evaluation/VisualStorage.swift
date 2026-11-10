import Foundation
import SwiftGraph

#if canImport(CryptoKit)
import CryptoKit
#endif

enum VisualStorage {
    static func writeJSON<T: Encodable>(_ value: T, _ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(10)
        try data.write(to: url, options: .atomic)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func safeID(_ id: String) -> Bool {
        !id.isEmpty
            && id.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }
    }

    static func validate(_ s: VisualSnapshot) throws {
        guard s.version == 1, safeID(s.id), s.isFinite,
            Set(s.nodes.map(\.id)).count == s.nodes.count, Set(s.edges.map(\.id)).count == s.edges.count
        else {
            throw EvaluationError.message("Invalid or unsupported snapshot: \(s.id)")
        }
        let ids = Set(s.nodes.map(\.id))
        guard s.edges.allSatisfy({ ids.contains($0.source) && ids.contains($0.target) }) else {
            throw EvaluationError.message("Unknown edge endpoint in \(s.id)")
        }
    }

    static func prepareOutput(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path),
            !(try FileManager.default.contentsOfDirectory(atPath: url.path)).isEmpty
        {
            throw EvaluationError.message(
                "Output directory is not empty: \(url.path). Use a new run directory to preserve prior evidence."
            )
        }
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("cases"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("png"),
            withIntermediateDirectories: true
        )
    }

    static func caseDirectory(_ output: URL, _ id: String) throws -> URL {
        guard safeID(id) else { throw EvaluationError.message("Invalid case ID: \(id)") }
        let dir = output.appendingPathComponent("cases").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func collection(_ directory: URL) throws -> (snapshots: [String: VisualSnapshot], manifest: VisualManifest?)
    {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var snapshots: [String: VisualSnapshot] = [:]
        let manifest: VisualManifest?
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try readJSON(VisualManifest.self, manifestURL)
            guard manifest!.version == 1 else { throw EvaluationError.message("Unsupported manifest version") }
            guard Set(manifest!.cases.map(\.id)).count == manifest!.cases.count else {
                throw EvaluationError.message("Duplicate manifest case IDs")
            }
            for row in manifest!.cases where row.hasSnapshot {
                guard safeID(row.id) else { throw EvaluationError.message("Invalid case ID") }
                let snapshot = try readJSON(
                    VisualSnapshot.self,
                    directory.appendingPathComponent("cases/\(row.id)/geometry.json")
                )
                try validate(snapshot)
                guard snapshot.id == row.id else { throw EvaluationError.message("Snapshot ID differs from manifest") }
                snapshots[row.id] = snapshot
            }
        } else {
            manifest = nil
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path })
            {
                let snapshot = try readJSON(VisualSnapshot.self, url)
                try validate(snapshot)
                guard snapshots[snapshot.id] == nil else { throw EvaluationError.message("Duplicate snapshot ID") }
                snapshots[snapshot.id] = snapshot
            }
        }
        return (snapshots, manifest)
    }

    static func bundledBaselines() throws -> [String: VisualSnapshot] {
        var result = Dictionary(uniqueKeysWithValues: try VisualCatalogue.referenceSnapshots().map { ($0.id, $0) })
        if let directory = Bundle.module.url(
            forResource: "VisualBaselines",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) {
            result.merge(try collection(directory).snapshots, uniquingKeysWith: { _, b in b })
        }
        return result
    }

    static func environment() -> [String: String] {
        func command(_ program: String, _ args: [String]) -> String {
            #if os(macOS) || os(Linux)
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: program)
            p.arguments = args
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            } catch { return "unknown" }
            #else
            return "unavailable on this platform"
            #endif
        }
        var fingerprint = "unavailable outside the source checkout"
        #if canImport(CryptoKit)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Evaluation
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
        var files = [root.appendingPathComponent("Package.swift")]
        for path in ["Sources/SwiftGraph", "Tests/Support"] {
            if let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent(path),
                includingPropertiesForKeys: nil
            ) {
                files += enumerator.compactMap { $0 as? URL }.filter { ["swift", "metal"].contains($0.pathExtension) }
            }
        }
        var hash = SHA256()
        var complete = true
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: file) else {
                complete = false
                break
            }
            hash.update(data: Data(file.path.replacingOccurrences(of: root.path + "/", with: "").utf8))
            hash.update(data: Data([0]))
            hash.update(data: data)
        }
        if complete { fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined() }
        #endif
        return [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "renderer": "scene-v1; Helvetica; PNG max 2400px; SVG world coordinates",
            "catalogue": "v1", "swift": command("/usr/bin/env", ["swift", "--version"]),
            "sourceTreeSHA256": fingerprint,
            "revision": command("/usr/bin/git", ["rev-parse", "HEAD"]),
            "workingTree": command("/usr/bin/git", ["status", "--porcelain"]),
        ]
    }
}
