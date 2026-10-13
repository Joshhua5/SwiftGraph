import Foundation
import SwiftGraph
#if os(macOS)
import CoreGraphics
import CoreText
import ImageIO
#endif

enum VisualPrimitive {
    case box(Rect, fill: String, stroke: String, width: Double)
    case line([Point], color: String, width: Double, dashed: Bool)
    case polygon([Point], color: String)
    case text(String, Rect, size: Double, color: String)

    var bounds: Rect {
        switch self {
        case let .box(r, _, _, w): return r.inflated(by: w / 2)
        case let .text(_, r, _, _): return r
        case let .line(points, _, width, _): return pointBounds(points).inflated(by: width / 2)
        case let .polygon(points, _): return pointBounds(points)
        }
    }
    func transformed(scale: Double, offset: Point) -> VisualPrimitive {
        func r(_ rect: Rect) -> Rect { Rect(x: rect.x * scale + offset.x, y: rect.y * scale + offset.y, width: rect.width * scale, height: rect.height * scale) }
        func p(_ points: [Point]) -> [Point] { points.map { $0 * scale + offset } }
        switch self {
        case let .box(rect, fill, stroke, width): return .box(r(rect), fill: fill, stroke: stroke, width: width * scale)
        case let .line(points, color, width, dashed): return .line(p(points), color: color, width: width * scale, dashed: dashed)
        case let .polygon(points, color): return .polygon(p(points), color: color)
        case let .text(text, rect, size, color): return .text(text, r(rect), size: size * scale, color: color)
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
    init(primitives: [VisualPrimitive], bounds: Rect) { self.primitives = primitives; self.bounds = bounds }
    init(snapshot: VisualSnapshot, tint: String? = nil) {
        primitives = []; bounds = Rect()
        let palette = ["#2563eb", "#b45309", "#7c3aed", "#087f8c", "#be185d", "#4d7c0f"]
        let groups = snapshot.nodes.filter(\.group).sorted { a, b in
            let aa = a.bounds.width * a.bounds.height, bb = b.bounds.width * b.bounds.height
            return aa == bb ? a.id < b.id : aa > bb
        }
        for group in groups {
            primitives.append(.box(group.bounds, fill: tint == nil ? "#f1f5f9" : "none", stroke: tint ?? "#94a3b8", width: 1))
            let header = group.headerBounds ?? Rect(x: group.bounds.x + 4, y: group.bounds.y + 2, width: max(1, group.bounds.width - 8), height: 16)
            if header.height > 0 {
                primitives.append(.text(group.name, header, size: 11, color: tint ?? "#475569"))
            }
        }
        for (i, edge) in snapshot.edges.enumerated() where edge.path.count >= 2 {
            let color = tint ?? (edge.fallback ? "#dc2626" : palette[i % palette.count])
            primitives.append(.line(edge.path, color: color, width: edge.width, dashed: edge.fallback))
            if let end = edge.path.last, let from = edge.path.dropLast().last(where: { ($0 - end).length > 1e-6 }) {
                let unit = (end - from) / (end - from).length, length = 2.5 * edge.width + 4
                let base = end - unit * length, side = Point(x: -unit.y, y: unit.x) * (length / 2)
                primitives.append(.polygon([end, base + side, base - side], color: color))
            }
        }
        for node in snapshot.nodes where !node.group {
            primitives.append(.box(node.bounds, fill: tint == nil ? "#ffffff" : "none", stroke: tint ?? "#334155", width: 1.5))
            if tint == nil {
                let r = Rect(x: node.bounds.x + 3, y: node.bounds.y + 2, width: max(1, node.bounds.width - 6), height: max(1, node.bounds.height - 4))
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
                let b = primitives.first.map { first in primitives.dropFirst().reduce(first.bounds) { $0.union($1.bounds) } } ?? Rect(width: 300, height: 100)
                primitives.append(.text("Missing routes: " + missing.joined(separator: ", "), Rect(x: b.x, y: b.bottom + 8, width: max(300, b.width), height: 24), size: 12, color: "#dc2626"))
            }
        }
        if primitives.isEmpty { primitives = [.text("Empty graph", Rect(width: 240, height: 100), size: 16, color: "#64748b")] }
        bounds = primitives.dropFirst().reduce(primitives[0].bounds) { $0.union($1.bounds) }.inflated(by: 24)
    }

    static func overlay(_ before: VisualSnapshot, _ after: VisualSnapshot) -> VisualScene {
        let a = VisualScene(snapshot: before, tint: "#c026d3"), b = VisualScene(snapshot: after, tint: "#0891b2")
        return VisualScene(primitives: a.primitives + b.primitives, bounds: a.bounds.union(b.bounds))
    }

    static func contactSheet(_ snapshots: [VisualSnapshot]) -> VisualScene {
        var primitives: [VisualPrimitive] = []
        let width = 420.0, height = 300.0
        for (index, snapshot) in snapshots.enumerated() {
            let x = Double(index % 3) * width, y = Double(index / 3) * height
            primitives.append(.box(Rect(x: x + 4, y: y + 4, width: width - 8, height: height - 8), fill: "#ffffff", stroke: "#cbd5e1", width: 1))
            primitives.append(.text(snapshot.id, Rect(x: x + 12, y: y + 10, width: width - 24, height: 22), size: 13, color: "#0f172a"))
            let scene = VisualScene(snapshot: snapshot)
            let scale = min((width - 24) / scene.bounds.width, (height - 50) / scene.bounds.height)
            let offset = Point(x: x + width / 2 - scene.bounds.center.x * scale, y: y + 38 + (height - 50) / 2 - scene.bounds.center.y * scale)
            primitives += scene.primitives.map { $0.transformed(scale: scale, offset: offset) }
        }
        return VisualScene(primitives: primitives, bounds: Rect(width: width * 3, height: max(1, ceil(Double(snapshots.count) / 3)) * height))
    }
}

enum VisualRenderError: Error { case invalidCanvas, pngUnavailable, imageCreation }

enum VisualRenderer {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    static func number(_ value: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value) }
    static func svg(_ scene: VisualScene) -> String {
        func rect(_ r: Rect) -> String { "x=\"\(number(r.x))\" y=\"\(number(r.y))\" width=\"\(number(r.width))\" height=\"\(number(r.height))\"" }
        func points(_ p: [Point]) -> String { p.map { "\(number($0.x)),\(number($0.y))" }.joined(separator: " ") }
        let b = scene.bounds
        var body = ["<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(number(b.x)) \(number(b.y)) \(number(b.width)) \(number(b.height))\" width=\"\(number(b.width))\" height=\"\(number(b.height))\">", "<rect \(rect(b)) fill=\"white\"/>"]
        for (i, item) in scene.primitives.enumerated() {
            switch item {
            case let .box(r, fill, stroke, width): body.append("<rect \(rect(r)) fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"\(number(width))\"/>")
            case let .line(p, color, width, dashed): body.append("<polyline points=\"\(points(p))\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(number(width))\" stroke-linejoin=\"round\" \(dashed ? "stroke-dasharray=\"6 4\"" : "")/>")
            case let .polygon(p, color): body.append("<polygon points=\"\(points(p))\" fill=\"\(color)\"/>")
            case let .text(text, r, size, color):
                body.append("<defs><clipPath id=\"t\(i)\"><rect \(rect(r))/></clipPath></defs><text x=\"\(number(r.center.x))\" y=\"\(number(r.center.y + size * 0.35))\" text-anchor=\"middle\" font-family=\"Helvetica, sans-serif\" font-size=\"\(number(size))\" fill=\"\(color)\" clip-path=\"url(#t\(i))\">\(escape(text))</text>")
            }
        }
        body.append("</svg>"); return body.joined(separator: "\n") + "\n"
    }

    static func write(_ scene: VisualScene, to stem: URL) throws {
        guard valid(scene.bounds), scene.bounds.width > 0, scene.bounds.height > 0 else { throw VisualRenderError.invalidCanvas }
        try svg(scene).write(to: stem.appendingPathExtension("svg"), atomically: true, encoding: .utf8)
        try png(scene, to: stem.appendingPathExtension("png"))
    }

    static func png(_ scene: VisualScene, to url: URL) throws {
        #if os(macOS)
        let b = scene.bounds
        guard valid(b), b.width > 0, b.height > 0 else { throw VisualRenderError.invalidCanvas }
        let scale = min(2, 2400 / max(b.width, b.height))
        let width = max(1, Int(ceil(b.width * scale))), height = max(1, Int(ceil(b.height * scale)))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VisualRenderError.imageCreation }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: Double(height)); ctx.scaleBy(x: scale, y: -scale); ctx.translateBy(x: -b.x, y: -b.y)
        draw(scene, context: ctx)
        guard let image = ctx.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw VisualRenderError.imageCreation }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VisualRenderError.imageCreation }
        #else
        throw VisualRenderError.pngUnavailable
        #endif
    }

    #if os(macOS)
    private static func color(_ hex: String) -> CGColor {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: hex == "none" ? 0 : 1)
    }
    private static func draw(_ scene: VisualScene, context ctx: CGContext) {
        func rect(_ r: Rect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }
        for primitive in scene.primitives {
            ctx.saveGState()
            switch primitive {
            case let .box(r, fill, stroke, width):
                ctx.setFillColor(color(fill)); ctx.fill(rect(r)); ctx.setStrokeColor(color(stroke)); ctx.setLineWidth(width); ctx.stroke(rect(r))
            case let .line(points, c, width, dashed):
                if let first = points.first {
                    ctx.setStrokeColor(color(c)); ctx.setLineWidth(width); ctx.setLineJoin(.round)
                    if dashed { ctx.setLineDash(phase: 0, lengths: [6, 4]) }
                    ctx.move(to: CGPoint(x: first.x, y: first.y)); for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }; ctx.strokePath()
                }
            case let .polygon(points, c):
                if let first = points.first {
                    ctx.setFillColor(color(c)); ctx.move(to: CGPoint(x: first.x, y: first.y))
                    for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }; ctx.closePath(); ctx.fillPath()
                }
            case let .text(text, r, size, c):
                ctx.clip(to: rect(r))
                let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(c)]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                ctx.translateBy(x: r.center.x - width / 2, y: r.center.y + (ascent - descent) / 2)
                ctx.scaleBy(x: 1, y: -1); ctx.textMatrix = .identity; ctx.textPosition = .zero
                CTLineDraw(line, ctx)
            }
            ctx.restoreGState()
        }
    }
    #endif
}
