import Foundation
import SwiftGraph
import SwiftGraphUI

enum TopologyLibrary {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GraphLayoutGallery
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repository root
    }

    /// Primary topology directory (`<repo>/Topologies`, or `SWIFTGRAPH_TOPOLOGIES` if set).
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SWIFTGRAPH_TOPOLOGIES"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return repoRoot.appendingPathComponent("Topologies", isDirectory: true)
    }

    private static var searchDirectories: [URL] {
        var dirs: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SWIFTGRAPH_TOPOLOGIES"], !override.isEmpty {
            dirs.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        dirs += [
            repoRoot.appendingPathComponent("Topologies", isDirectory: true),
            repoRoot.appendingPathComponent("docs", isDirectory: true),
            repoRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true),
        ]
        return dirs
    }

    static func scan() -> [TopologyFile] {
        var seenNames = Set<String>()
        var files: [TopologyFile] = []
        for dir in searchDirectories {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension.lowercased() == "json" {
                let file = TopologyFile(url: url)
                guard !seenNames.contains(file.name),
                    (try? ProductionTopology.load(from: url)) != nil
                else { continue }
                seenNames.insert(file.name)
                files.append(file)
            }
        }
        return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func resolve(named name: String) -> TopologyFile {
        if let found = scan().first(where: { $0.name == name }) {
            return found
        }
        return TopologyFile(url: directory.appendingPathComponent("\(name).json"))
    }
}

// MARK: - Configurable layout and routing
