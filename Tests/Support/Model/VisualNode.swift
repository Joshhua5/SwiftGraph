import Foundation
import SwiftGraph

struct VisualNode: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var bounds: Rect
    var parent: String?
    var group: Bool
    var contentBounds: Rect? = nil
    var headerBounds: Rect? = nil

    /// The title part of `headerBounds` that routes must avoid. Optional so older snapshots still decode;
    /// those fall back to the whole header band.
    var titleBounds: Rect? = nil

    /// The rectangle routes are forbidden to cross for this frame's header.
    var routeBlockingHeader: Rect? { titleBounds ?? headerBounds }
}
