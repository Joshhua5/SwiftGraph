import Foundation

/// Carries routes along with moved nodes: each path's ends follow their nodes (points between blend the two moves, so a
/// rigid move translates the path), and a route left crossing a node is searched afresh between its ends. A route made
/// only of horizontal and vertical legs stays so: its legs slide rigidly, and a search for it tries rectilinear shapes
/// first.
func followMovedNodes(_ graph: LayoutGraph, from old: [Rect]) {
    let moves = zip(graph.nodes, old).map { Point(x: $0.x - $1.x, y: $0.y - $1.y) }
    guard moves.contains(where: { $0 != .zero }) else { return }
    let move = Dictionary(zip(graph.nodes, moves), uniquingKeysWith: { a, _ in a })
    // A lone straight leg only counts as rectilinear in an orthogonal drawing: the recorded style, else every route
    // rectilinear and some bending.
    let routed = graph.edges.filter { $0.path.count >= 2 }
    let orthogonal = graph.isOrthogonalDrawing(routed)
    for e in routed {
        let ds = move[e.source] ?? .zero
        let dt = move[e.target] ?? .zero
        let rectilinear = isRectilinear(e.path) && (e.path.count >= 3 || orthogonal)
        if ds != .zero || dt != .zero {
            e.path = rectilinear ? carriedRectilinear(e.path, ds, dt) : carried(e.path, ds, dt)
        }
        guard e.source !== e.target else { continue }
        let obstacles = ObstaclePolyline.obstacles(e, graph)
        guard !ObstaclePolyline.clear(e.path, obstacles) else { continue }
        let start = e.path[0]
        let end = e.path[e.path.count - 1]
        if rectilinear, let found = RectilinearRoute.simple(start, end, obstacles) {
            e.path = found
        } else if orthogonal, rectilinear, let found = RectilinearRoute.search(start, end, obstacles, padding: 10) {
            e.path = found
        } else if let found = ObstaclePolyline.search(start, end, obstacles, padding: 10) {
            e.path = found
        }
    }
}

private func carried(_ path: [Point], _ ds: Point, _ dt: Point) -> [Point] {
    // `along` starts with one element and only grows, so `last` always has a value.
    var along: [Float] = [0.0]
    for (a, b) in zip(path, path.dropFirst()) { along.append(along.last! + (b - a).length) }
    return path.indices.map { i in
        let f = along.last! > 0 ? along[i] / along.last! : Float(i) / Float(path.count - 1)
        return path[i] + ds * (1 - f) + dt * f
    }
}

/// Slides the legs of a rectilinear route with the moves of its ends: each leg shifts across itself by the end move at
/// its end of the route (the first and last legs exactly), blending between for the legs in the middle. A single leg
/// whose two ends move differently across it gets a jog half way.
private func carriedRectilinear(_ route: [Point], _ ds: Point, _ dt: Point) -> [Point] {
    let path = compactPath(route)
    guard path.count >= 2 else { return carried(route, ds, dt) }
    let legs = zip(path, path.dropFirst()).map { abs($0.y - $1.y) < 1e-5 }  // true: horizontal, shifts in y
    guard zip(legs, legs.dropFirst()).allSatisfy({ $0 != $1 }) else { return carried(route, ds, dt) }
    let first = path[0] + ds
    let last = path[path.count - 1] + dt
    if legs.count == 1 {
        if legs[0] ? abs(first.y - last.y) < 1e-5 : abs(first.x - last.x) < 1e-5 { return [first, last] }
        return legs[0]
            ? [first, Point(x: (first.x + last.x) / 2, y: first.y), Point(x: (first.x + last.x) / 2, y: last.y), last]
            : [first, Point(x: first.x, y: (first.y + last.y) / 2), Point(x: last.x, y: (first.y + last.y) / 2), last]
    }
    // `along` starts with one element and only grows, so `last` always has a value.
    var along: [Float] = [0.0]
    for (a, b) in zip(path, path.dropFirst()) { along.append(along.last! + (b - a).length) }
    let total = max(along.last!, 1e-6)
    let shift = legs.indices.map { j -> Float in
        let f: Float = j == 0 ? 0 : j == legs.count - 1 ? 1 : (along[j] + along[j + 1]) / (2 * total)
        let from = legs[j] ? ds.y : ds.x
        let to = legs[j] ? dt.y : dt.x
        return from + (to - from) * f
    }
    var result = [first]
    for k in 1..<(path.count - 1) {
        let h = legs[k - 1] ? k - 1 : k
        let v = legs[k - 1] ? k : k - 1
        result.append(Point(x: path[k].x + shift[v], y: path[k].y + shift[h]))
    }
    return result + [last]
}
