import Foundation

/// A run along a corridor, from `source` to `target` on the corridor's axis, that needs a track of its own. Its
/// identity is independent of coordinates; disjoint runs may reuse a track.
///
/// At each end the route turns across the corridor through an arm that heads towards the low or the high tracks, or
/// has no arm where the route ends. The defaults are the layered case: a run entered from the low side and left
/// towards the high side.
struct TrackSegment {
    enum Side {
        case low
        case high
    }

    var id: Int
    var source: Float
    var target: Float
    var sourceSide: Side? = .low
    var targetSide: Side? = .high
    var low: Float { min(source, target) }
    var high: Float { max(source, target) }
}
