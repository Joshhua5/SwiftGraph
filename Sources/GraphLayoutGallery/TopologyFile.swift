import Foundation
import SwiftGraph
import SwiftGraphUI

/// A topology JSON file found in the repository's `Topologies` or `docs` folder.
struct TopologyFile: Identifiable, Hashable, Sendable {
    var url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}
