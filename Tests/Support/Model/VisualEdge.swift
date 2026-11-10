import Foundation
import SwiftGraph

struct VisualEdge: Codable, Equatable, Sendable {
    var id: String
    var source: String
    var target: String
    var path: [Point]
    var label: String?
    var labelBounds: Rect
    var width: Float = 1.5
    var fallback = false

    // Optional so existing v1 snapshots without this field still decode.
    var bidirectional: Bool? = nil
}
