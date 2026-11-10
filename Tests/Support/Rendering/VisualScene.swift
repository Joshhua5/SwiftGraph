import Foundation
import SwiftGraph

#if os(macOS)
import CoreGraphics
import CoreText
import ImageIO
#endif

enum VisualPrimitive {
    case box(Rect, fill: String, stroke: String, width: Float)
    case line([Point], color: String, width: Float, dashed: Bool)
    case polygon([Point], color: String)
    case text(String, Rect, size: Float, color: String)

    var bounds: Rect {
        switch self {
        case .box(let r, _, _, let w): return r.inflated(by: w / 2)
        case .text(_, let r, _, _): return r
        case .line(let points, _, let width, _): return pointBounds(points).inflated(by: width / 2)
        case .polygon(let points, _): return pointBounds(points)
        }
    }

    func transformed(scale: Float, offset: Point) -> VisualPrimitive {
        func r(_ rect: Rect) -> Rect {
            Rect(
                x: rect.x * scale + offset.x,
                y: rect.y * scale + offset.y,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }
        func p(_ points: [Point]) -> [Point] { points.map { $0 * scale + offset } }
        switch self {
        case .box(let rect, let fill, let stroke, let width):
            return .box(r(rect), fill: fill, stroke: stroke, width: width * scale)
        case .line(let points, let color, let width, let dashed):
            return .line(p(points), color: color, width: width * scale, dashed: dashed)
        case .polygon(let points, let color): return .polygon(p(points), color: color)
        case .text(let text, let rect, let size, let color):
            return .text(text, r(rect), size: size * scale, color: color)
        }
    }
}

func pointBounds(_ points: [Point]) -> Rect {
    guard let first = points.first else { return Rect() }
    return points.dropFirst().reduce(Rect(x: first.x, y: first.y)) { $0.union(Rect(x: $1.x, y: $1.y)) }
}

struct VisualScene {
    var primitives: [VisualPrimitive]
    var bounds: Rect

    init(primitives: [VisualPrimitive], bounds: Rect) {
        self.primitives = primitives
        self.bounds = bounds
    }

    init(snapshot: VisualSnapshot, tint: String? = nil, crossingJumps: Bool = true) {
        primitives = []
        bounds = Rect()
        let palette = ["#2563eb", "#b45309", "#7c3aed", "#087f8c", "#be185d", "#4d7c0f"]
        let groups = snapshot.nodes.filter(\.group)
            .sorted { a, b in
                let aa = a.bounds.width * a.bounds.height
                let bb = b.bounds.width * b.bounds.height
                return aa == bb ? a.id < b.id : aa > bb
            }
        for group in groups {
            primitives.append(
                .box(group.bounds, fill: tint == nil ? "#f1f5f9" : "none", stroke: tint ?? "#94a3b8", width: 1)
            )
        }
        var drawnSegments: [(Point, Point)] = []
        for (i, edge) in snapshot.edges.enumerated() where edge.path.count >= 2 {
            let color = tint ?? (edge.fallback ? "#dc2626" : palette[i % palette.count])
            let segs = VisualGeometry.segments(edge.path)
            if tint == nil && crossingJumps {
                for (a, b) in segs {
                    let len = (b - a).length
                    guard len > 8 else { continue }
                    let u = (b - a) / len
                    for (c, d) in drawnSegments where VisualGeometry.crossing(a, b, c, d) {
                        let v = d - c
                        let denom = VisualGeometry.cross(b - a, v)
                        guard abs(denom) > VisualGeometry.epsilon else { continue }
                        let t = VisualGeometry.cross(c - a, v) / denom
                        let hit = a + (b - a) * t
                        let half = min(Float(3.0), min(t * len, (1 - t) * len) * 0.45)
                        if half > 0.8 {
                            primitives.append(
                                .line(
                                    [hit - u * half, hit + u * half],
                                    color: "#ffffff",
                                    width: edge.width + 3.2,
                                    dashed: false
                                )
                            )
                        }
                    }
                }
            }
            primitives.append(.line(edge.path, color: color, width: edge.width, dashed: edge.fallback))
            if let end = edge.path.last, let from = edge.path.dropLast().last(where: { ($0 - end).length > 1e-5 }) {
                let unit = (end - from) / (end - from).length
                let length = 2.5 * edge.width + 4
                let base = end - unit * length
                let side = Point(x: -unit.y, y: unit.x) * (length / 2)
                primitives.append(.polygon([end, base + side, base - side], color: color))
            }
            if edge.bidirectional == true, let start = edge.path.first,
                let from = edge.path.dropFirst().first(where: { ($0 - start).length > 1e-5 })
            {
                let unit = (start - from) / (start - from).length
                let length = 2.5 * edge.width + 4
                let base = start - unit * length
                let side = Point(x: -unit.y, y: unit.x) * (length / 2)
                primitives.append(.polygon([start, base + side, base - side], color: color))
            }
            if crossingJumps { drawnSegments.append(contentsOf: segs) }
        }
        // Text remains legible over route antialiasing; header clearance is enforced by routing.
        for group in groups {
            let header =
                group.headerBounds
                ?? Rect(x: group.bounds.x + 4, y: group.bounds.y + 2, width: max(1, group.bounds.width - 8), height: 16)
            if header.height > 0 {
                primitives.append(.text(group.name, header, size: 11, color: tint ?? "#475569"))
            }
        }
        for node in snapshot.nodes where !node.group {
            primitives.append(
                .box(node.bounds, fill: tint == nil ? "#ffffff" : "none", stroke: tint ?? "#334155", width: 1.5)
            )
            if tint == nil {
                let r = Rect(
                    x: node.bounds.x + 3,
                    y: node.bounds.y + 2,
                    width: max(1, node.bounds.width - 6),
                    height: max(1, node.bounds.height - 4)
                )
                primitives.append(.text(node.name, r, size: 12, color: "#0f172a"))
            }
        }
        if tint == nil {
            for edge in snapshot.edges where edge.label != nil && edge.labelBounds.width > 0 {
                primitives.append(.box(edge.labelBounds, fill: "#fffbeb", stroke: "#d97706", width: 0.75))
                primitives.append(.text(edge.label!, edge.labelBounds, size: 11, color: "#78350f"))
            }
            let missing = snapshot.edges.filter { $0.path.count < 2 }.map(\.id)
            if !missing.isEmpty {
                let b =
                    primitives.first.map { first in primitives.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
                    } ?? Rect(width: 300, height: 100)
                primitives.append(
                    .text(
                        "Missing routes: " + missing.joined(separator: ", "),
                        Rect(x: b.x, y: b.bottom + 8, width: max(300, b.width), height: 24),
                        size: 12,
                        color: "#dc2626"
                    )
                )
            }
        }
        if primitives.isEmpty {
            primitives = [.text("Empty graph", Rect(width: 240, height: 100), size: 16, color: "#64748b")]
        }
        bounds = primitives.dropFirst().reduce(primitives[0].bounds) { $0.union($1.bounds) }.inflated(by: 24)
    }

    static func overlay(_ before: VisualSnapshot, _ after: VisualSnapshot) -> VisualScene {
        let a = VisualScene(snapshot: before, tint: "#c026d3")
        let b = VisualScene(snapshot: after, tint: "#0891b2")
        return VisualScene(primitives: a.primitives + b.primitives, bounds: a.bounds.union(b.bounds))
    }

    static func contactSheet(_ snapshots: [VisualSnapshot], crossingJumps: Bool = true) -> VisualScene {
        var primitives: [VisualPrimitive] = []
        let width: Float = 420.0
        let height: Float = 300.0
        for (index, snapshot) in snapshots.enumerated() {
            let x = Float(index % 3) * width
            let y = Float(index / 3) * height
            primitives.append(
                .box(
                    Rect(x: x + 4, y: y + 4, width: width - 8, height: height - 8),
                    fill: "#ffffff",
                    stroke: "#cbd5e1",
                    width: 1
                )
            )
            primitives.append(
                .text(
                    snapshot.id,
                    Rect(x: x + 12, y: y + 10, width: width - 24, height: 22),
                    size: 13,
                    color: "#0f172a"
                )
            )
            let scene = VisualScene(snapshot: snapshot, crossingJumps: crossingJumps)
            let scale = min((width - 24) / scene.bounds.width, (height - 50) / scene.bounds.height)
            let offset = Point(
                x: x + width / 2 - scene.bounds.center.x * scale,
                y: y + 38 + (height - 50) / 2 - scene.bounds.center.y * scale
            )
            primitives += scene.primitives.map { $0.transformed(scale: scale, offset: offset) }
        }
        return VisualScene(
            primitives: primitives,
            bounds: Rect(width: width * 3, height: max(1, ceil(Float(snapshots.count) / 3)) * height)
        )
    }
}
