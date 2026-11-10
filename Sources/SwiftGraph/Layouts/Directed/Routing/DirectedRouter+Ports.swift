import Foundation

extension DirectedRouter {
    private struct End {
        var edge: LayoutEdge
        var source: Bool
        var neighbor: Point
        var group = 3
        var depth: Float = 0.0
        var want: Float?
    }

    private struct SideKey: Hashable {
        var node: LayoutNode
        var side: PortConstraint
    }

    /// The span of a left/right side where a port may sit: clear of the corners.
    static func sideRange(_ r: Rect) -> (lo: Float, hi: Float) {
        r.height > 16 ? (r.top + 8, r.bottom - 8) : (r.center.y, r.center.y)
    }

    static func onSide(_ point: Point, _ side: PortConstraint, of r: Rect, margin: Float) -> Bool {
        switch side {
        case .left: return abs(point.x - r.left) < 0.001 && point.y >= r.top + margin && point.y <= r.bottom - margin
        case .right: return abs(point.x - r.right) < 0.001 && point.y >= r.top + margin && point.y <= r.bottom - margin
        case .top: return abs(point.y - r.top) < 0.001 && point.x >= r.left + margin && point.x <= r.right - margin
        case .bottom:
            return abs(point.y - r.bottom) < 0.001 && point.x >= r.left + margin && point.x <= r.right - margin
        case .none: return false
        }
    }

    /// The nearest coordinate in [lo, hi] to `desired` that keeps `minimum` from every taken one.
    static func nearestFree(_ desired: Float, taken: [Float], lo: Float, hi: Float, minimum: Float) -> Float? {
        func free(_ t: Float) -> Bool {
            t >= lo - 0.0001 && t <= hi + 0.0001 && !taken.contains { abs($0 - t) < minimum - 0.0001 }
        }
        let wanted = min(hi, max(lo, desired))
        if free(wanted) { return wanted }
        let candidates = ([lo, hi] + taken.flatMap { [$0 - minimum, $0 + minimum] }).filter(free)
        return candidates.min {
            abs($0 - desired) == abs($1 - desired) ? $0 < $1 : abs($0 - desired) < abs($1 - desired)
        }
    }

    func assignPorts() {
        var ends: [SideKey: [End]] = [:]
        var assigned: [LayoutEdge: [Point]] = [:]
        var loops: [LayoutNode: Int] = [:]
        for edge in edges {
            let a = edge.source.bounds
            let b = edge.target.bounds
            let sides: (PortConstraint, PortConstraint)
            if edge.source === edge.target {
                sides = (.top, .top)
            } else if feedback.contains(edge) {
                // Reporting links use the facing horizontal sides when vertically separated.
                // Forcing both ends onto the top sends lower targets around unrelated ranks.
                if a.bottom + clearance * 2 < b.top {
                    sides = (.bottom, .top)
                } else if b.bottom + clearance * 2 < a.top {
                    sides = (.top, .bottom)
                } else {
                    sides = (.top, .top)
                }
            } else if edge.sourcePort != .none && edge.targetPort != .none {
                sides = (edge.sourcePort, edge.targetPort)
            } else if a.center.x < b.center.x {
                sides = (.right, .left)
            } else {
                sides = (.left, .right)
            }
            var source = End(edge: edge, source: true, neighbor: edge.path.count > 2 ? edge.path[1] : b.center)
            var target = End(
                edge: edge,
                source: false,
                neighbor: edge.path.count > 2 ? edge.path[edge.path.count - 2] : a.center
            )
            // Top and bottom ends order by the other endpoint, not by a stale path: left-going ends sit
            // left and right-going ends right, with self-loops between them. The farther the other
            // endpoint, the outer its arc and the nearer to the centre its port, so it never crosses
            // a nearer arc's horizontal run. Groups: 0 left-going, 1 loop starts, 2 loop ends, 3 aligned, 4
            // right-going.
            if edge.source === edge.target {
                let level = loops[edge.source, default: 0]
                loops[edge.source] = level + 1
                source.group = 1
                source.depth = Float(level + 1)
                target.group = 2
                target.depth = Float(level + 1)
            } else {
                for (end, node, other) in [(0, edge.source, edge.target), (1, edge.target, edge.source)] {
                    let dx = other.center.x - node.center.x
                    let group = dx < 0 ? 0 : (dx > 0 ? 4 : 3)
                    if end == 0 {
                        source.group = group
                        source.depth = abs(dx)
                    } else {
                        target.group = group
                        target.depth = abs(dx)
                    }
                }
            }
            // Facing left/right ends slide along their side toward the other end, so a pair whose sides overlap
            // gets one shared coordinate (a straight edge) and neighbours more than a side apart still aim at each
            // other.
            if sides.0 != .top && sides.0 != .bottom && sides.1 != .top && sides.1 != .bottom
                && edge.source !== edge.target
            {
                let direct = edge.path.count <= 2
                let (su, sv) = (Self.sideRange(a), Self.sideRange(b))
                let lo = max(su.lo, sv.lo)
                let hi = min(su.hi, sv.hi)
                if direct {
                    let mid = (a.center.y + b.center.y) / 2
                    if lo <= hi {
                        source.want = min(hi, max(lo, mid))
                        target.want = source.want
                    } else {
                        source.want = min(su.hi, max(su.lo, b.center.y))
                        target.want = min(sv.hi, max(sv.lo, a.center.y))
                    }
                } else {
                    source.want = min(su.hi, max(su.lo, source.neighbor.y))
                    target.want = min(sv.hi, max(sv.lo, target.neighbor.y))
                }
            }
            ends[SideKey(node: edge.source, side: sides.0), default: []].append(source)
            ends[SideKey(node: edge.target, side: sides.1), default: []].append(target)
            assigned[edge] = [.zero, .zero, .zero, .zero]
        }
        for (key, unsorted) in ends {
            let vertical = key.side == .left || key.side == .right
            let sorted = unsorted.sorted {
                let ai = edgeIndices[required: $0.edge]
                let bi = edgeIndices[required: $1.edge]
                if !vertical {
                    if $0.group != $1.group { return $0.group < $1.group }
                    if $0.depth != $1.depth {
                        return [1, 4].contains($0.group) ? $0.depth > $1.depth : $0.depth < $1.depth
                    }
                    if ai != bi { return $0.group == 4 ? ai > bi : ai < bi }
                    return $0.source && !$1.source
                }
                if $0.neighbor.y != $1.neighbor.y { return $0.neighbor.y < $1.neighbor.y }
                return ai == bi ? $0.source && !$1.source : ai < bi
            }
            let r = key.node.bounds
            let extent = vertical ? r.height : r.width
            let count = sorted.count
            let spacing = min(pitch, max(0, extent - 24) / Float(max(1, count - 1)))
            let middle = vertical ? r.center.y : r.center.x
            var slots = (0..<count).map { middle + (Float($0) - Float(count - 1) / 2) * spacing }
            if vertical && sorted.contains(where: { $0.want != nil }) {
                // Ordered ports as close to their wanted coordinates as the spacing and the side allow.
                let range = Self.sideRange(r)
                let step: Float = count > 1 ? min(pitch, max(0, range.hi - range.lo) / Float(count - 1)) : 0
                let fit = isotonicFit(
                    sorted.enumerated().map { ($1.want ?? slots[$0]) - Float($0) * step },
                    weights: Array(repeating: 1, count: count)
                )
                let top = range.lo
                let bottom = range.hi - Float(count - 1) * step
                slots = fit.enumerated().map { min(max($1, min(top, bottom)), max(top, bottom)) + Float($0) * step }
            }
            // Prior ports stay where they are; a new end takes the nearest free gap, in order
            // between its neighbours. Only when no gap keeps the spacing is the side re-spread.
            if configuration.mode != .fresh {
                var kept = [Float?](repeating: nil, count: count)
                for (i, end) in sorted.enumerated() {
                    guard let path = configuration.previousPaths[edgeIndices[required: end.edge]], path.count >= 2
                    else {
                        continue
                    }
                    // The guard above ensured `path.count >= 2`.
                    let point = end.source ? path[0] : path.last!
                    if Self.onSide(point, key.side, of: r, margin: 6) { kept[i] = vertical ? point.y : point.x }
                }
                if kept.contains(where: { $0 != nil }) {
                    var taken = kept.compactMap { $0 }
                    var positions = kept
                    var fits = true
                    let lo = (vertical ? r.top : r.left) + 6
                    let hi = (vertical ? r.bottom : r.right) - 6
                    for i in 0..<count where positions[i] == nil {
                        let before = positions[..<i].last(where: { $0 != nil }) ?? nil
                        let after = positions[(i + 1)...].first(where: { $0 != nil }) ?? nil
                        let desired =
                            before.map { b in after.map { ($0 + b) / 2 } ?? b + spacing } ?? after.map { $0 - spacing }
                            ?? slots[i]
                        guard let t = Self.nearestFree(desired, taken: taken, lo: lo, hi: hi, minimum: spacing) else {
                            fits = false
                            break
                        }
                        positions[i] = t
                        taken.append(t)
                    }
                    if fits {
                        // `fits` means the loop above filled every nil position.
                        slots = positions.map { $0! }
                    } else {
                        // No gap is wide enough: keep the order and move the prior ports as little as the spacing
                        // demands.
                        let wanted = (0..<count)
                            .map { i -> Float in
                                if let k = kept[i] { return k }
                                let before = kept[..<i].last(where: { $0 != nil }) ?? nil
                                let after = kept[(i + 1)...].first(where: { $0 != nil }) ?? nil
                                return before.map { b in after.map { ($0 + b) / 2 } ?? b + spacing } ?? after.map {
                                    $0 - spacing
                                } ?? slots[i]
                            }
                        let fit = isotonicFit(
                            wanted.enumerated().map { $1 - Float($0) * spacing },
                            weights: Array(repeating: 1, count: count)
                        )
                        let first = lo
                        let last = hi - Float(count - 1) * spacing
                        slots = fit.enumerated()
                            .map { min(max($1, min(first, last)), max(first, last)) + Float($0) * spacing }
                    }
                }
            }
            for (i, end) in sorted.enumerated() {
                let p: Point
                let d: Point
                switch key.side {
                case .left:
                    p = Point(x: r.left, y: slots[i])
                    d = Point(x: -1, y: 0)
                case .right:
                    p = Point(x: r.right, y: slots[i])
                    d = Point(x: 1, y: 0)
                case .top:
                    p = Point(x: slots[i], y: r.top)
                    d = Point(x: 0, y: -1)
                case .bottom:
                    p = Point(x: slots[i], y: r.bottom)
                    d = Point(x: 0, y: 1)
                case .none: continue
                }
                // Every end was collected in the loop that also seeded `assigned[edge]`.
                assigned[end.edge]![end.source ? 0 : 1] = p
                assigned[end.edge]![end.source ? 2 : 3] = d
            }
        }
        for (edge, p) in assigned { ports[edge] = (p[0], p[1], p[2], p[3]) }
    }

    /// Port pairs on the other sides, nearest first, each slotted into a free gap beside the ports
    /// already in use. An edge whose assigned sides are blocked is tried here before it is dropped.
    func alternatePorts(for edge: LayoutEdge) -> [Ports] {
        let current = ports[required: edge]
        let loop = edge.source === edge.target
        var options: [(distance: Float, order: Int, ports: Ports)] = []
        for (s, source) in [PortConstraint.top, .bottom, .left, .right].enumerated() {
            for (t, target) in [PortConstraint.top, .bottom, .left, .right].enumerated() where !loop || source == target
            {
                guard let sp = slot(on: edge.source, side: source, toward: edge.target.center, excluding: edge),
                    let tp = slot(
                        on: edge.target,
                        side: target,
                        toward: edge.source.center,
                        excluding: edge,
                        extra: loop ? sp.0 : nil
                    ),
                    sp.0 != current.0 || tp.0 != current.1
                else { continue }
                options.append((abs(sp.0.x - tp.0.x) + abs(sp.0.y - tp.0.y), s * 4 + t, (sp.0, tp.0, sp.1, tp.1)))
            }
        }
        return options.sorted { $0.distance == $1.distance ? $0.order < $1.order : $0.distance < $1.distance }.prefix(8)
            .map(\.ports)
    }

    private func slot(
        on node: LayoutNode,
        side: PortConstraint,
        toward p: Point,
        excluding edge: LayoutEdge,
        extra: Point? = nil
    ) -> (Point, Point)? {
        let r = node.bounds
        let vertical = side == .left || side == .right
        let lo = (vertical ? r.top : r.left) + 6
        let hi = (vertical ? r.bottom : r.right) - 6
        guard hi >= lo else { return nil }
        var taken = extra.map { [vertical ? $0.y : $0.x] } ?? []
        for (other, q) in ports where other !== edge {
            for (point, owner) in [(q.0, other.source), (q.1, other.target)]
            where owner === node && Self.onSide(point, side, of: r, margin: 0) {
                taken.append(vertical ? point.y : point.x)
            }
        }
        guard let t = Self.nearestFree(vertical ? p.y : p.x, taken: taken, lo: lo, hi: hi, minimum: edgeSpacing) else {
            return nil
        }
        switch side {
        case .left: return (Point(x: r.left, y: t), Point(x: -1, y: 0))
        case .right: return (Point(x: r.right, y: t), Point(x: 1, y: 0))
        case .top: return (Point(x: t, y: r.top), Point(x: 0, y: -1))
        case .bottom: return (Point(x: t, y: r.bottom), Point(x: 0, y: 1))
        case .none: return nil
        }
    }
}
