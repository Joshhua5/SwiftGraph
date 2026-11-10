import Foundation

/// Force-scan overlap removal (Misue et al. 1995): sweeps each axis in center order and shifts everything
/// beyond a conflict by the same amount, so no left/right or above/below relation between nodes changes.
/// A few ulps at the largest coordinate involved. Spacing checks subtract this rather than a fixed epsilon: with Float
/// geometry a gap of exactly `spacing`, recomputed from centres or edges, can land an ulp short and would otherwise be
/// "separated" again by a rounding-sized step, so overlap removal was not idempotent.
/// Must match `spacingTolerance` in Shaders/BasicLayouts.metal exactly for CPU/GPU parity.
func spacingTolerance(_ a: Rect, _ b: Rect, spacing: Float) -> Float {
    let m = max(
        max(max(abs(a.left), abs(b.left)), max(abs(a.top), abs(b.top))),
        max(max(abs(a.right), abs(b.right)), max(abs(a.bottom), abs(b.bottom)))
    )
    return 4 * Float.ulpOfOne * max(m, abs(spacing))
}

func forceScan(_ nodes: [LayoutNode], spacing: Float) throws {
    for horizontal in [true, false] {
        try Task.checkCancellation()
        let centers = nodes.map(\.center)
        let key = { (i: Int) in horizontal ? centers[i].x : centers[i].y }
        let order = nodes.indices.sorted { key($0) == key($1) ? $0 < $1 : key($0) < key($1) }
        var i = 0
        while i < order.count {
            var k = i
            while k + 1 < order.count && key(order[k + 1]) == key(order[i]) { k += 1 }
            var shift: Float = 0.0
            for m in order[i...k] {
                for j in order[(k + 1)...] {
                    let a = nodes[m].bounds
                    let b = nodes[j].bounds
                    let d = b.center - a.center
                    let needX = (a.width + b.width) / 2 + spacing
                    let needY = (a.height + b.height) / 2 + spacing
                    let tolerance = spacingTolerance(a, b, spacing: spacing)
                    guard abs(d.x) < needX - tolerance && abs(d.y) < needY - tolerance else { continue }
                    // Scale the center offset until either axis clears; this axis takes its component.
                    let t = min(d.x != 0 ? needX / abs(d.x) : .infinity, d.y != 0 ? needY / abs(d.y) : .infinity)
                    shift = max(shift, (horizontal ? d.x : d.y) * (t - 1))
                }
            }
            if shift > 0 {
                for j in order[(k + 1)...] { if horizontal { nodes[j].x += shift } else { nodes[j].y += shift } }
            }
            i = k + 1
        }
    }
}

/// Pushes each pair closer than `spacing` on both axes apart along the axis needing the smaller move,
/// so rows stay rows and columns stay columns. Pairs with one fixed member move only the other;
/// fixed pairs are left alone. Returns false if the pass budget runs out before every pair is clear.
func separateOverlaps(_ nodes: [LayoutNode], spacing: Float, movable: [Bool], passes: Int = 200) throws -> Bool {
    let candidates = nodes.indices.filter { !nodes[$0].isGroup }
    for pass in 0..<passes {
        // Most runs settle long before the pass budget; the caller's stage snaps to complete on return.
        if pass % 16 == 0 {
            try Task.checkCancellation()
            LayoutStageScope.tick(asymptotic: pass, halfLife: 8)
        }
        // Window by the pass-start positions; pairs missed after a move are caught by the next pass,
        // and the final, motionless pass is exact.
        let order = candidates.sorted { nodes[$0].x == nodes[$1].x ? $0 < $1 : nodes[$0].x < nodes[$1].x }
        let lefts = order.map { nodes[$0].x }
        let rights = order.map { nodes[$0].bounds.right }
        var moved = false
        for k in order.indices {
            for m in (k + 1)..<order.count {
                if lefts[m] >= rights[k] + spacing { break }
                let (i, j) = (order[k], order[m])
                guard movable[i] || movable[j] else { continue }
                let a = nodes[i].bounds
                let b = nodes[j].bounds
                let needX = min(a.right, b.right) - max(a.left, b.left) + spacing
                let needY = min(a.bottom, b.bottom) - max(a.top, b.top) + spacing
                let tolerance = spacingTolerance(a, b, spacing: spacing)
                guard needX > tolerance && needY > tolerance else { continue }
                let horizontal = needX <= needY
                let forward =
                    horizontal
                    ? (a.center.x == b.center.x ? i < j : a.center.x < b.center.x)
                    : (a.center.y == b.center.y ? i < j : a.center.y < b.center.y)
                let need = horizontal ? needX : needY
                let share = movable[i] && movable[j] ? need / 2 : need
                let step = forward ? share : -share
                if movable[i] { if horizontal { nodes[i].x -= step } else { nodes[i].y -= step } }
                if movable[j] { if horizontal { nodes[j].x += step } else { nodes[j].y += step } }
                moved = true
            }
        }
        if !moved { return true }
    }
    return false
}
