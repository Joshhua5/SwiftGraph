import Foundation

/// A channel segment is a vertical run between two ordered rank boundaries.
/// Its identity is independent of coordinates; disjoint runs may reuse a slot.
struct DirectedChannelSegment {
    var id: Int
    var source: Float
    var target: Float
    var low: Float { min(source, target) }
    var high: Float { max(source, target) }
}
