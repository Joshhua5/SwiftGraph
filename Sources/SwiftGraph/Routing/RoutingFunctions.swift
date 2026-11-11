import Foundation

func portPoint(_ node: LayoutNode, side: PortConstraint) -> Point {
    let r = node.bounds
    switch side {
    case .top: return Point(x: r.center.x, y: r.top)
    case .bottom: return Point(x: r.center.x, y: r.bottom)
    case .left: return Point(x: r.left, y: r.center.y)
    case .right: return Point(x: r.right, y: r.center.y)
    case .none: return r.center
    }
}

func portDirection(_ side: PortConstraint) -> Point {
    switch side {
    case .top: Point(x: 0, y: -1)
    case .bottom: Point(x: 0, y: 1)
    case .left: Point(x: -1, y: 0)
    case .right: Point(x: 1, y: 0)
    case .none: .zero
    }
}

func isAncestor(_ ancestor: LayoutNode, of node: LayoutNode) -> Bool {
    var current = node.parent
    var seen = Set<LayoutNode>()
    while let parent = current, seen.insert(parent).inserted {
        if parent === ancestor { return true }
        current = parent.parent
    }
    return false
}

func compactPath(_ path: [Point]) -> [Point] {
    var result: [Point] = []
    for p in path {
        if result.last == p { continue }
        if result.count >= 2 {
            let a = result[result.count - 2]
            let b = result[result.count - 1]
            let u = b - a
            let v = p - b
            if abs(u.x * v.y - u.y * v.x) < 1e-5 && u.x * v.x + u.y * v.y >= 0 { result.removeLast() }
        }
        result.append(p)
    }
    return result
}

/// `body` applied to every element of `items` on all cores, results in order. `body` must not depend on work done by
/// another call. Workers see no `RoutingCompute.current`: a transaction is not thread-safe, so they take the exact
/// CPU predicates, and they observe the transaction's cancellation.
func concurrentRoutingMap<Input, T>(_ items: [Input], _ body: (Input) -> T) -> [T] {
    guard items.count > 1 else { return items.map(body) }
    let cancellation = RoutingCompute.cancellation
    let output = UnsafeMutableBufferPointer<T?>.allocate(capacity: items.count)
    output.initialize(repeating: nil)
    defer {
        output.deinitialize()
        output.deallocate()
    }
    // Each worker writes only its own slot and reads `items`, which nothing mutates meanwhile.
    nonisolated(unsafe) let slots = output
    nonisolated(unsafe) let work = body
    nonisolated(unsafe) let inputs = items
    DispatchQueue.concurrentPerform(iterations: items.count) { k in
        RoutingCompute.$current.withValue(nil) {
            RoutingCompute.$cancellation.withValue(cancellation) { slots[k] = work(inputs[k]) }
        }
    }
    // `concurrentPerform` has run every iteration, and each wrote a non-optional `T` to its slot.
    return output.map { $0! }
}

/// Whether `path` cuts any of `obstacles`. Reporting only, so it stays on the CPU and never adds compute dispatches.
func cutsObstacle(_ path: [Point], _ obstacles: [Rect]) -> Bool {
    zip(path, path.dropFirst()).contains { a, b in obstacles.contains { $0.intersectsLine(a, b) } }
}

/// Replaces every segment of `path` that crosses an obstacle by a visibility detour; segments with no detour are kept.
/// A `rectilinear` detour is tried first when asked for, so an orthogonal route stays orthogonal where it can.
func detourBlocked(_ path: [Point], _ obstacles: [Rect], padding: Float = 8, rectilinear: Bool = false) -> [Point] {
    func detour(_ a: Point, _ b: Point) -> [Point]? {
        if rectilinear, let found = RectilinearRoute.search(a, b, obstacles, padding: padding) { return found }
        return ObstaclePolyline.search(a, b, obstacles, padding: padding)
    }
    var result = path
    var k = 0
    while k + 1 < result.count {
        if RoutingCompute.isCancelled { return result }
        let a = result[k]
        let b = result[k + 1]
        if !ObstaclePolyline.clear([a, b], obstacles),
            let detour = detour(a, b), detour.count > 2
        {
            result.replaceSubrange(k...(k + 1), with: detour)
            k += detour.count - 1
        } else {
            k += 1
        }
    }
    return result
}

func overlaps(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
    let u = b - a
    let v = d - c
    let length = u.length
    guard length > 1e-6, v.length > 1e-6 else { return false }
    let tolerance = 1e-5 * max(length, v.length)
    guard abs(u.x * v.y - u.y * v.x) < tolerance, abs(u.x * (c - a).y - u.y * (c - a).x) < tolerance else {
        return false
    }
    let tc = ((c - a).x * u.x + (c - a).y * u.y) / length
    let td = ((d - a).x * u.x + (d - a).y * u.y) / length
    return min(length, max(tc, td)) - max(0, min(tc, td)) > 1e-5
}

func onSegment(_ p: Point, _ a: Point, _ b: Point) -> Bool {
    let u = b - a
    let w = p - a
    let length = u.length
    guard length > 1e-6, abs(u.x * w.y - u.y * w.x) < 1e-5 * length else { return false }
    let t = (w.x * u.x + w.y * u.y) / (length * length)
    return t > 1e-5 && t < 1 - 1e-5
}
