import Foundation
import SwiftGraph

#if os(macOS)
import CoreGraphics
import CoreText
import ImageIO
#endif

enum VisualRenderer {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value)
    }

    static func number(_ value: Float) -> String { number(Double(value)) }

    static func svg(_ scene: VisualScene) -> String {
        func rect(_ r: Rect) -> String {
            "x=\"\(number(r.x))\" y=\"\(number(r.y))\" width=\"\(number(r.width))\" height=\"\(number(r.height))\""
        }
        func points(_ p: [Point]) -> String { p.map { "\(number($0.x)),\(number($0.y))" }.joined(separator: " ") }
        let b = scene.bounds
        var body = [
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(number(b.x)) \(number(b.y)) \(number(b.width)) \(number(b.height))\" width=\"\(number(b.width))\" height=\"\(number(b.height))\">",
            "<rect \(rect(b)) fill=\"white\"/>",
        ]
        for (i, item) in scene.primitives.enumerated() {
            switch item {
            case .box(let r, let fill, let stroke, let width):
                body.append(
                    "<rect \(rect(r)) fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"\(number(width))\"/>"
                )
            case .line(let p, let color, let width, let dashed):
                body.append(
                    "<polyline points=\"\(points(p))\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(number(width))\" stroke-linejoin=\"round\" \(dashed ? "stroke-dasharray=\"6 4\"" : "")/>"
                )
            case .polygon(let p, let color): body.append("<polygon points=\"\(points(p))\" fill=\"\(color)\"/>")
            case .text(let text, let r, let size, let color):
                let estWidth = max(1, Float(text.count) * size * 0.56)
                let fitSize = r.width > 0 && estWidth > r.width ? max(size * 0.65, size * (r.width / estWidth)) : size
                body.append(
                    "<defs><clipPath id=\"t\(i)\"><rect \(rect(r))/></clipPath></defs><text x=\"\(number(r.center.x))\" y=\"\(number(r.center.y + fitSize * 0.35))\" text-anchor=\"middle\" font-family=\"Helvetica, sans-serif\" font-size=\"\(number(fitSize))\" fill=\"\(color)\" clip-path=\"url(#t\(i))\">\(escape(text))</text>"
                )
            }
        }
        body.append("</svg>")
        return body.joined(separator: "\n") + "\n"
    }

    static func write(_ scene: VisualScene, to stem: URL) throws {
        guard valid(scene.bounds), scene.bounds.width > 0, scene.bounds.height > 0 else {
            throw VisualRenderError.invalidCanvas
        }
        try svg(scene).write(to: stem.appendingPathExtension("svg"), atomically: true, encoding: .utf8)
        try png(scene, to: stem.appendingPathExtension("png"))
    }

    static func png(_ scene: VisualScene, to url: URL) throws {
        #if os(macOS)
        let b = scene.bounds
        guard valid(b), b.width > 0, b.height > 0 else { throw VisualRenderError.invalidCanvas }
        let scale = min(2.0, 2400.0 / Double(max(b.width, b.height)))
        let width = max(1, Int(ceil(Double(b.width) * scale)))
        let height = max(1, Int(ceil(Double(b.height) * scale)))
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw VisualRenderError.imageCreation }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -Double(b.x), y: -Double(b.y))
        draw(scene, context: ctx)
        guard let image = ctx.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw VisualRenderError.imageCreation }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VisualRenderError.imageCreation }
        #else
        throw VisualRenderError.pngUnavailable
        #endif
    }

    #if os(macOS)

    private static func color(_ hex: String) -> CGColor {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255,
            alpha: hex == "none" ? 0 : 1
        )
    }

    private static func draw(_ scene: VisualScene, context ctx: CGContext) {
        func rect(_ r: Rect) -> CGRect {
            CGRect(x: Double(r.x), y: Double(r.y), width: Double(r.width), height: Double(r.height))
        }
        for primitive in scene.primitives {
            ctx.saveGState()
            switch primitive {
            case .box(let r, let fill, let stroke, let width):
                ctx.setFillColor(color(fill))
                ctx.fill(rect(r))
                ctx.setStrokeColor(color(stroke))
                ctx.setLineWidth(Double(width))
                ctx.stroke(rect(r))
            case .line(let points, let c, let width, let dashed):
                if let first = points.first {
                    ctx.setStrokeColor(color(c))
                    ctx.setLineWidth(Double(width))
                    ctx.setLineJoin(.round)
                    if dashed { ctx.setLineDash(phase: 0, lengths: [6, 4]) }
                    ctx.move(to: CGPoint(x: Double(first.x), y: Double(first.y)))
                    for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: Double(p.x), y: Double(p.y))) }
                    ctx.strokePath()
                }
            case .polygon(let points, let c):
                if let first = points.first {
                    ctx.setFillColor(color(c))
                    ctx.move(to: CGPoint(x: Double(first.x), y: Double(first.y)))
                    for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: Double(p.x), y: Double(p.y))) }
                    ctx.closePath()
                    ctx.fillPath()
                }
            case .text(let text, let r, let size, let c):
                ctx.clip(to: rect(r))
                func makeLine(_ fontSize: Double) -> (CTLine, Double, CGFloat, CGFloat) {
                    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                    let attrs: [NSAttributedString.Key: Any] = [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(c),
                    ]
                    let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                    var asc: CGFloat = 0
                    var desc: CGFloat = 0
                    let w = CTLineGetTypographicBounds(ctLine, &asc, &desc, nil)
                    return (ctLine, w, asc, desc)
                }
                let sizeD = Double(size)
                let rWidthD = Double(r.width)
                var (line, width, ascent, descent) = makeLine(sizeD)
                if width > rWidthD && rWidthD > 0 {
                    let scaled = max(sizeD * 0.65, sizeD * (rWidthD / width) * 0.96)
                    (line, width, ascent, descent) = makeLine(scaled)
                }
                ctx.translateBy(x: Double(r.center.x) - width / 2, y: Double(r.center.y) + (ascent - descent) / 2)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textMatrix = .identity
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
            }
            ctx.restoreGState()
        }
    }
    #endif
}
