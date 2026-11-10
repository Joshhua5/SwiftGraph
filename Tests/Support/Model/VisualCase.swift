import Foundation
import SwiftGraph

struct VisualCase {
    var id: String
    var family: String
    var title: String
    var configuration: [String: String] = [:]
    var contracts = VisualContracts()
    var smoke = false
    var metal = false
    var run: () async throws -> VisualDrawing
}
