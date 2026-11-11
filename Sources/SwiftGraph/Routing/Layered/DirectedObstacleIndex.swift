import Foundation

/// Node rectangles indexed for `DirectedGeometry.clear`. Rectangles are grouped into bands whose
/// x-extents are disjoint (in a layered drawing, one band per rank column), and each band is
/// sorted by top edge. A test visits only the bands the segment spans and, within each, only the
/// rectangles whose vertical extent can reach it; the exact test is the one `clear` applies.
struct DirectedObstacleIndex {
    private struct Band {
        var left: Float
        var right: Float
        var tallest: Float

        /// Indices into `rects`, ascending by top edge.
        var members: [Int]
        var tops: [Float]
    }

    let rects: [Rect]
    private let bands: [Band]

    init(_ rects: [Rect]) {
        self.rects = rects
        let byLeft = rects.indices.sorted {
            rects[$0].left == rects[$1].left ? $0 < $1 : rects[$0].left < rects[$1].left
        }
        var groups: [[Int]] = []
        var reach = -Float.infinity
        for index in byLeft {
            if groups.isEmpty || rects[index].left > reach {
                groups.append([index])
                reach = rects[index].right
            } else {
                groups[groups.count - 1].append(index)
                reach = max(reach, rects[index].right)
            }
        }
        bands = groups.map { group in
            let members = group.sorted { rects[$0].top == rects[$1].top ? $0 < $1 : rects[$0].top < rects[$1].top }
            return Band(
                left: group.map { rects[$0].left }.min() ?? 0,
                right: group.map { rects[$0].right }.max() ?? 0,
                tallest: group.map { rects[$0].height }.max() ?? 0,
                members: members,
                tops: members.map { rects[$0].top }
            )
        }
    }

    /// Same result as `DirectedGeometry.clear(a, b, bodies:)` over every rectangle but those at
    /// `skipped` and `alsoSkipped`.
    func clear(_ a: Point, _ b: Point, skipping skipped: Int? = nil, _ alsoSkipped: Int? = nil) -> Bool {
        if abs(a.x - b.x) > DirectedGeometry.epsilon && abs(a.y - b.y) > DirectedGeometry.epsilon { return false }
        let minX = min(a.x, b.x)
        let maxX = max(a.x, b.x)
        let minY = min(a.y, b.y)
        let maxY = max(a.y, b.y)
        // Any rectangle `blocks` rejects overlaps the segment's open box, so the bounds below only
        // ever pass over rectangles that cannot block. The slack absorbs `top + height` rounding.
        var band = firstBand(endingAfter: minX)
        while band < bands.count, bands[band].left < maxX {
            let entry = bands[band]
            band += 1
            let slack = 1 + abs(minY) * 1e-5
            var position = Self.lowerBound(entry.tops, minY - entry.tallest - slack)
            while position < entry.members.count, entry.tops[position] < maxY {
                let index = entry.members[position]
                position += 1
                if index == skipped || index == alsoSkipped { continue }
                if DirectedGeometry.blocks(a, b, rects[index]) { return false }
            }
        }
        return true
    }

    /// Bands are disjoint and ordered, so their right edges ascend.
    private func firstBand(endingAfter x: Float) -> Int {
        var low = 0
        var high = bands.count
        while low < high {
            let mid = (low + high) / 2
            if bands[mid].right <= x { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func lowerBound(_ values: [Float], _ value: Float) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
