import Foundation
import SwiftGraph

struct OrganicLegacyFixture: Decodable {
    var count: Int
    var iterations: Int
    var shape: String
    var bounds: [Rect]
    static func load() throws -> [Self] {
        let url = Bundle.module.url(forResource: "organic-legacy", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }
}
