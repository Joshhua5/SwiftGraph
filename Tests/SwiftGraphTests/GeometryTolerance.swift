import SwiftGraph

/// A margin for "on the outline" checks that never drops below Float resolution at the coordinates involved.
/// A fixed margin stops working once coordinates grow: at y ≈ 2000 one ulp is 2.4e-4, so shrinking a rectangle by
/// 1e-4 (or 1e-6) rounds back to the same rectangle, and a point exactly on its outline counts as inside it.
func outlineTolerance(_ minimum: Float, _ p: Point, _ r: Rect) -> Float {
    max(minimum, 4 * [r.left, r.right, r.top, r.bottom, p.x, p.y].map(abs).max()!.ulp)
}

/// True when `p` lies on the outline of `r`, within `outlineTolerance(minimum, p, r)` either side.
func liesOnOutline(_ p: Point, _ r: Rect, minimum: Float = 1e-6) -> Bool {
    let tolerance = outlineTolerance(minimum, p, r)
    return r.inflated(by: tolerance).contains(p) && !r.inflated(by: -tolerance).contains(p)
}
