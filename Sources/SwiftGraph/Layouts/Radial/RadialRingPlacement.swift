import Foundation

/// Circumscribed node circles provide clearance both within and between rings.
func placeRadialRings(
    _ nodes: [LayoutNode],
    depth: [Int],
    angles inputAngles: [Double],
    minimumStep: Float,
    compactDepths: Bool = false
) throws {
    guard let maximumDepth = depth.max() else { return }
    let step: Float = minimumStep.isFinite ? max(0, minimumStep) : 100
    var previousRadius: Float = 0.0
    var previousHalf: Float = 0.0
    var angles = inputAngles
    var placed: [Rect] = []
    for d in 0...maximumDepth {
        try Task.checkCancellation()
        let ring = nodes.indices.filter { depth[$0] == d }
        guard !ring.isEmpty else { continue }
        // The guard above leaves `ring` non-empty.
        let half = ring.map { hypot(nodes[$0].width, nodes[$0].height) / 2 }.max()!
        var radius: Float = d == 0 ? 0 : previousRadius + (compactDepths ? step : max(step, previousHalf + half + 20))
        // Extremely deep sectors can collapse at floating-point precision.
        if ring.count > 1
            && ring.enumerated()
                .contains(where: { offset, i in
                    ring.dropFirst(offset + 1).contains { abs(sin((angles[i] - angles[$0]) / 2)) < 1e-12 }
                })
        {
            for (offset, i) in ring.enumerated() { angles[i] = Double(offset) * 2 * .pi / Double(ring.count) }
        }
        for (offset, i) in ring.enumerated() {
            for j in ring.dropFirst(offset + 1) {
                let chord = Float(2 * abs(sin((angles[i] - angles[j]) / 2)))
                let distance =
                    (hypot(nodes[i].width, nodes[i].height) + hypot(nodes[j].width, nodes[j].height)) / 2 + 20
                radius = max(radius, distance / chord)
            }
        }
        if compactDepths {
            radius = fittedRadialDepth(
                ring.map { nodes[$0] },
                angles: ring.map { angles[$0] },
                previous: placed,
                minimum: radius
            )
        }
        for i in ring { nodes[i].center = Point(x: radius * Float(cos(angles[i])), y: radius * Float(sin(angles[i]))) }
        placed += ring.map { nodes[$0].bounds }
        previousRadius = radius
        previousHalf = half
    }
}
