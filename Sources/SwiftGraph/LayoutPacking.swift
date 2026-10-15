import Foundation

/// Invisible routing vertices must not reserve a full node-sized corridor.
func hierarchyGap(_ a: Int, _ b: Int, originals: Int, separation: Float) -> Float {
    if a < originals && b < originals { return separation }
    if a < originals || b < originals { return separation / 2 }
    return min(2, max(0, separation))
}

/// Radius for equally spaced centers, using each rectangle's own circumscribed circle.
func fittedCircleRadius(_ bounds: [Rect], minimum: Float) -> Float {
    guard bounds.count > 1 else { return 0 }
    var radius = max(0, minimum)
    let halves = bounds.map { hypot($0.width, $0.height) / 2 }
    for i in bounds.indices {
        for j in bounds.indices.dropFirst(i + 1) {
            let chord = Float(2 * abs(sin(Double(j - i) * .pi / Double(bounds.count))))
            radius = max(radius, (halves[i] + halves[j] + 20) / chord)
        }
    }
    return radius
}

/// Disjoint angular sectors fit heterogeneous siblings without giving every small
/// node the largest frame's pitch. Each sector encloses its node's padded circle.
func fittedCirclePlacement(_ bounds: [Rect], minimum: Float) -> (radius: Float, angles: [Float]) {
    guard bounds.count > 1 else { return (0, bounds.isEmpty ? [] : [0]) }
    if bounds.count == 2 { return (fittedCircleRadius(bounds, minimum: minimum), [0, .pi]) }
    let sizes = bounds.map { Double(hypot($0.width, $0.height) / 2 + 10) }
    let lower = max(Double(max(0, minimum)), sizes.max() ?? 0)
    func used(_ radius: Double) -> Double { sizes.reduce(0) { $0 + 2 * asin(min(1, $1 / max(radius, 1e-12))) } }
    var low = lower, high = max(1, lower)
    while used(high) > 2 * .pi { high *= 2 }
    for _ in 0..<48 {
        let mid = (low + high) / 2
        if used(mid) > 2 * .pi { low = mid } else { high = mid }
    }
    // Round outward so Float conversion cannot reduce the fitted clearance.
    let radius = Float(high).nextUp
    let halves = sizes.map { asin(min(1, $0 / Double(radius))) }
    let gap = max(0, (2 * Double.pi - 2 * halves.reduce(0, +)) / Double(bounds.count))
    var angles = [Float(0)], angle = 0.0
    for i in 1..<bounds.count { angle += halves[i - 1] + halves[i] + gap; angles.append(Float(angle)) }
    return (radius, angles)
}

/// Stable shelf packing shared by components and spanning-forest roots.
/// Returns translations from the original bounds, including negative local origins.
func packedTranslations(_ bounds: [Rect], spacing: Float, aspectRatio: Float = 1) -> [Point] {
    guard !bounds.isEmpty else { return [] }
    let gap = max(0, spacing), ratio = max(0.01, aspectRatio)
    let area = bounds.reduce(Double(0)) { $0 + Double($1.width + gap) * Double($1.height + gap) }
    let target = max(bounds.map(\.width).max() ?? 0, Float(sqrt(area * Double(ratio))))
    var result = Array(repeating: Point.zero, count: bounds.count)
    var x: Float = 0, y: Float = 0, rowHeight: Float = 0
    for i in bounds.indices.sorted(by: { bounds[$0].height == bounds[$1].height ? $0 < $1 : bounds[$0].height > bounds[$1].height }) {
        let b = bounds[i]
        if x > 0 && x + b.width > target { x = 0; y += rowHeight + gap; rowHeight = 0 }
        result[i] = Point(x: x - b.x, y: y - b.y)
        x += b.width + gap; rowHeight = max(rowHeight, b.height)
    }
    return result
}

func packForest(_ nodes: [LayoutNode], components: [[Int]], spacing: Float) {
    let bounds = components.map { enclosingBounds($0.map { nodes[$0] }) }
    let shifts = packedTranslations(bounds, spacing: spacing)
    for (component, shift) in zip(components, shifts) {
        for i in component { nodes[i].bounds = nodes[i].bounds.translated(by: shift) }
    }
}

extension Forest {
    var components: [[Int]] {
        roots.map { root in
            var result: [Int] = [], stack = [root]
            while let i = stack.popLast() { result.append(i); stack.append(contentsOf: children[i].reversed()) }
            return result
        }
    }
}

/// Top-to-top minimum spacing, increased only at depths whose nodes need it.
func orgChartLevelOffsets(_ nodes: [LayoutNode], depths: [Int], minimum: Float) -> [Float] {
    guard let last = depths.max(), last >= 0 else { return [] }
    var heights = Array(repeating: Float(0), count: last + 1)
    for i in nodes.indices where depths[i] >= 0 {
        heights[depths[i]] = max(heights[depths[i]], nodes[i].height)
    }
    var offsets = Array(repeating: Float(0), count: heights.count)
    for d in offsets.indices.dropFirst() { offsets[d] = offsets[d - 1] + max(minimum, heights[d - 1] + 20) }
    return offsets
}

/// Move a ring outward only where its actual rectangles meet earlier depths.
/// Each rectangle pair forbids one interval of radii along the moving node's ray.
func fittedRadialDepth(_ nodes: [LayoutNode], angles: [Double], previous: [Rect], minimum: Float) -> Float {
    var intervals: [(Float, Float)] = []
    for (node, angle) in zip(nodes, angles) {
        let direction = Point(x: Float(cos(angle)), y: Float(sin(angle)))
        for rect in previous {
            var lower = -Float.infinity, upper = Float.infinity
            for (velocity, center, half) in [(direction.x, rect.center.x, (node.width + rect.width) / 2 + 20),
                                            (direction.y, rect.center.y, (node.height + rect.height) / 2 + 20)] {
                if abs(velocity) < 1e-7 {
                    if abs(center) >= half { upper = -Float.infinity; break }
                } else {
                    let a = (center - half) / velocity, b = (center + half) / velocity
                    lower = max(lower, min(a, b)); upper = min(upper, max(a, b))
                }
            }
            if upper >= lower && upper >= minimum { intervals.append((lower, upper)) }
        }
    }
    var radius = minimum
    for (lower, upper) in intervals.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) {
        if radius >= lower && radius <= upper { radius = upper.nextUp }
    }
    return radius
}
