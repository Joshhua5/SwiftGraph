import SwiftUI

/// Draws a `GraphSnapshot` scaled to fit the available space (world y grows downwards, like SwiftUI).
struct GraphCanvas: View {
    let snapshot: GraphSnapshot
    var showLabels = true
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    private let groupColors: [Color] = [.blue, .purple, .teal, .orange, .pink]
    private let edgeColors: [Color] = [
        Color(red: 0.22, green: 0.42, blue: 0.78),
        Color(red: 0.08, green: 0.52, blue: 0.56),
        Color(red: 0.46, green: 0.32, blue: 0.76),
        Color(red: 0.72, green: 0.36, blue: 0.14),
        Color(red: 0.18, green: 0.56, blue: 0.34),
        Color(red: 0.68, green: 0.22, blue: 0.44),
    ]

    var body: some View {
        Canvas { context, size in
            let world = snapshot.worldBounds.insetBy(dx: -28, dy: -28)
            let fitScale = min(size.width / max(world.width, 1), size.height / max(world.height, 1), 1.6)
            let scale = fitScale * max(0.25, zoom)
            // Centre the drawing in the canvas, then apply interactive pan.
            let offset = CGPoint(
                x: (size.width - world.width * scale) / 2 - world.minX * scale + pan.width,
                y: (size.height - world.height * scale) / 2 - world.minY * scale + pan.height
            )
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
            func map(_ r: CGRect) -> CGRect {
                CGRect(origin: map(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale))
            }
            let fontSize = max(6.5, min(13, 11.5 * scale))
            let edgeWidth = max(0.85, min(1.6, 1.3 * scale))
            let arrowSize = max(4.0, min(8.0, 6.8 * scale))

            // 1. Swimlanes
            for (index, lane) in snapshot.lanes.enumerated() {
                let frame = map(lane.frame)
                let radius = max(4, 8 * scale)
                let shape = Path(roundedRect: frame, cornerRadius: radius)
                let tint: Color = index.isMultiple(of: 2) ? .blue : .teal
                context.fill(shape, with: .color(tint.opacity(0.045)))

                let headerHeight = max(fontSize + 8, lane.headerHeight * scale)
                let headerRect = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(headerHeight, frame.height))
                context.drawLayer { headerLayer in
                    headerLayer.clip(to: shape)
                    headerLayer.fill(Path(headerRect), with: .color(tint.opacity(0.11)))
                }
                var divider = Path()
                divider.move(to: CGPoint(x: frame.minX, y: headerRect.maxY))
                divider.addLine(to: CGPoint(x: frame.maxX, y: headerRect.maxY))
                context.stroke(divider, with: .color(tint.opacity(0.28)), lineWidth: max(0.75, scale))
                context.stroke(shape, with: .color(tint.opacity(0.35)), lineWidth: max(0.85, 1.1 * scale))
                context.draw(
                    Text(lane.title).font(.system(size: fontSize, weight: .semibold)).foregroundColor(tint),
                    at: CGPoint(x: headerRect.midX, y: headerRect.midY)
                )
            }

            // 2. Group containers (outer to inner)
            for node in snapshot.nodes where node.isGroup {
                let color = groupColors[node.depth % groupColors.count]
                let frame = map(node.frame)
                let radius = max(4, 8 * scale)
                let shape = Path(roundedRect: frame, cornerRadius: radius)
                context.fill(shape, with: .color(color.opacity(0.055)))

                let titleInset = max(6, 8 * scale)

                if let reservedHeader = node.headerFrame.map(map) {
                    // The layout reserved header space inside the frame, so draw a filled band over exactly
                    // that space. Growing it to fit a minimum font size would cover the first row of children.
                    let headerBand = CGRect(
                        x: frame.minX,
                        y: frame.minY,
                        width: frame.width,
                        height: min(frame.height, reservedHeader.maxY - frame.minY)
                    )
                    context.drawLayer { headerLayer in
                        headerLayer.clip(to: shape)
                        headerLayer.fill(Path(headerBand), with: .color(color.opacity(0.11)))
                    }
                    var divider = Path()
                    divider.move(to: CGPoint(x: frame.minX, y: headerBand.maxY))
                    divider.addLine(to: CGPoint(x: frame.maxX, y: headerBand.maxY))
                    context.stroke(divider, with: .color(color.opacity(0.28)), lineWidth: max(0.75, 0.9 * scale))
                    let titleBox = CGSize(width: frame.width - titleInset * 2, height: reservedHeader.height)
                    if let title = fittedText(context, node.name, weight: .semibold, color: color, preferredSize: fontSize, in: titleBox) {
                        context.draw(title, at: CGPoint(x: frame.minX + titleInset, y: headerBand.midY), anchor: .leading)
                    }
                } else if let title = fittedText(
                    context, node.name, weight: .semibold, color: color, preferredSize: fontSize,
                    in: CGSize(width: frame.width - titleInset * 2, height: .infinity)
                ) {
                    // No reserved header: hang the title as a tab above the top edge so it never covers children.
                    let titleSize = title.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
                    let padding = CGSize(width: max(3, 5 * scale), height: max(1.5, 2.5 * scale))
                    let tab = CGRect(
                        x: frame.minX + titleInset - padding.width,
                        y: frame.minY - titleSize.height - padding.height * 2,
                        width: titleSize.width + padding.width * 2,
                        height: titleSize.height + padding.height * 2
                    )
                    let tabShape = Path(roundedRect: tab, cornerRadius: max(2.5, 4 * scale))
                    context.fill(tabShape, with: .color(Color.canvasBackground))
                    context.fill(tabShape, with: .color(color.opacity(0.16)))
                    context.draw(title, at: CGPoint(x: tab.midX, y: tab.midY), anchor: .center)
                }

                let dashUnit = max(2.5, 5 * scale)
                context.stroke(
                    shape,
                    with: .color(color.opacity(0.65)),
                    style: StrokeStyle(lineWidth: max(0.9, 1.15 * scale), dash: [dashUnit, dashUnit * 0.65])
                )
            }

            // 3. Edges with crossing bridges, rounded bends, port dots, and arrowheads
            for edge in snapshot.edges where edge.points.count >= 2 {
                let points = edge.points.map(map)
                let color: Color = edge.isSelfLoop ? .orange : edgeColors[edge.id % edgeColors.count].opacity(0.88)

                // Draw bridge halos over earlier edges at crossing points.
                if !edge.bridges.isEmpty {
                    var bridgePath = Path()
                    for bridge in edge.bridges {
                        bridgePath.move(to: map(bridge.start))
                        bridgePath.addLine(to: map(bridge.end))
                    }
                    context.stroke(
                        bridgePath,
                        with: .color(Color.canvasBackground),
                        style: StrokeStyle(lineWidth: edgeWidth + max(2.5, 3.4 * scale), lineCap: .butt)
                    )
                }

                let trimmed = trimmedPoints(points, trimStart: edge.isBidirectional ? arrowSize * 0.55 : 0, trimEnd: arrowSize * 0.55)
                let path = roundedPath(for: trimmed, cornerRadius: max(2, 6 * scale))
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: edgeWidth, lineCap: .round, lineJoin: .round)
                )

                if !edge.isBidirectional, let start = points.first {
                    let dotRadius = max(1.2, min(2.4, 1.8 * scale))
                    let dotRect = CGRect(x: start.x - dotRadius, y: start.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                    context.fill(Path(ellipseIn: dotRect), with: .color(color))
                }

                if let end = points.last,
                   let from = points.dropLast().last(where: { hypot(end.x - $0.x, end.y - $0.y) > 0.5 }) {
                    drawArrowhead(in: &context, from: from, to: end, size: arrowSize, color: color)
                }
                if edge.isBidirectional, let start = points.first,
                   let from = points.dropFirst().first(where: { hypot(start.x - $0.x, start.y - $0.y) > 0.5 }) {
                    drawArrowhead(in: &context, from: from, to: start, size: arrowSize, color: color)
                }
            }

            // 4. Leaf nodes
            for node in snapshot.nodes where !node.isGroup {
                let frame = map(node.frame)
                let radius = max(3, 6 * scale)
                let shape = Path(roundedRect: frame, cornerRadius: radius)
                context.fill(shape, with: .color(Color.nodeFill))
                context.stroke(shape, with: .color(Color.accentColor.opacity(0.88)), lineWidth: max(1.0, 1.45 * scale))

                let labelBox = CGSize(width: frame.width - max(4, 10 * scale), height: frame.height)
                if let label = fittedText(context, node.name, weight: .medium, color: .primary, preferredSize: fontSize, in: labelBox) {
                    context.draw(label, at: CGPoint(x: frame.midX, y: frame.midY))
                }
            }

            // 5. Edge labels
            guard showLabels else { return }
            for edge in snapshot.edges {
                guard let label = edge.label, let labelFrame = edge.labelFrame else { continue }
                let frame = map(labelFrame).insetBy(dx: -2 * scale, dy: -1 * scale)
                let badge = Path(roundedRect: frame, cornerRadius: max(2.5, 4 * scale))
                context.fill(badge, with: .color(Color.labelBackground.opacity(0.94)))
                context.stroke(badge, with: .color(Color.secondary.opacity(0.32)), lineWidth: max(0.6, 0.8 * scale))
                context.draw(
                    Text(label).font(.system(size: max(6, fontSize * 0.85), weight: .medium)).foregroundColor(.secondary),
                    at: CGPoint(x: frame.midX, y: frame.midY)
                )
            }
        }
    }

    /// Smallest point size worth drawing; text that would need to be smaller is skipped rather than overflowing.
    private let minimumLegibleFontSize: CGFloat = 4.5

    /// Resolves `string` at the largest size up to `preferredSize` that fits `box` (height capped to ~72% of
    /// the box so text keeps some margin), measuring the real glyph width. Returns `nil` when it would be illegible.
    private func fittedText(
        _ context: GraphicsContext,
        _ string: String,
        weight: Font.Weight,
        color: Color,
        preferredSize: CGFloat,
        in box: CGSize
    ) -> GraphicsContext.ResolvedText? {
        func resolve(_ size: CGFloat) -> GraphicsContext.ResolvedText {
            context.resolve(Text(string).font(.system(size: size, weight: weight)).foregroundColor(color))
        }
        var size = min(preferredSize, box.height * 0.72)
        guard box.width > 0, size >= minimumLegibleFontSize else { return nil }
        var resolved = resolve(size)
        let width = resolved.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width
        if width > box.width {
            size *= box.width / width
            guard size >= minimumLegibleFontSize else { return nil }
            resolved = resolve(size)
        }
        return resolved
    }

    /// Pulls endpoints slightly back along the terminal segment so stroke caps don't protrude through arrowhead tips.
    private func trimmedPoints(_ points: [CGPoint], trimStart: CGFloat, trimEnd: CGFloat) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var out = points
        if trimStart > 0 {
            let p0 = out[0], p1 = out[1]
            let len = hypot(p1.x - p0.x, p1.y - p0.y)
            if len > trimStart * 1.5 {
                out[0] = CGPoint(x: p0.x + (p1.x - p0.x) / len * trimStart, y: p0.y + (p1.y - p0.y) / len * trimStart)
            }
        }
        if trimEnd > 0 {
            let n = out.count
            let pLast = out[n - 1], pPrev = out[n - 2]
            let len = hypot(pLast.x - pPrev.x, pLast.y - pPrev.y)
            if len > trimEnd * 1.5 {
                out[n - 1] = CGPoint(x: pLast.x - (pLast.x - pPrev.x) / len * trimEnd, y: pLast.y - (pLast.y - pPrev.y) / len * trimEnd)
            }
        }
        return out
    }

    /// Builds a polyline path with smooth circular fillets at interior bends, clamped so adjacent bends never overlap.
    private func roundedPath(for points: [CGPoint], cornerRadius: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2, cornerRadius > 0.5 else {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let p0 = points[i - 1], p1 = points[i], p2 = points[i + 1]
            let v1 = CGPoint(x: p0.x - p1.x, y: p0.y - p1.y)
            let v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
            let len1 = hypot(v1.x, v1.y), len2 = hypot(v2.x, v2.y)
            guard len1 > 1.5, len2 > 1.5 else {
                path.addLine(to: p1)
                continue
            }
            let u1 = CGPoint(x: v1.x / len1, y: v1.y / len1)
            let u2 = CGPoint(x: v2.x / len2, y: v2.y / len2)
            let cross = abs(u1.x * u2.y - u1.y * u2.x)
            let dot = max(-1, min(1, u1.x * u2.x + u1.y * u2.y))
            guard cross > 0.06, dot < 0.98 else {
                path.addLine(to: p1)
                continue
            }
            let maxTrim = min(len1, len2) * 0.38
            let halfAngle = acos(dot) / 2
            let radius = min(cornerRadius, maxTrim * tan(halfAngle))
            if radius > 0.5 {
                path.addArc(tangent1End: p1, tangent2End: p2, radius: radius)
            } else {
                path.addLine(to: p1)
            }
        }
        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }

    private func drawArrowhead(in context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, size: CGFloat, color: Color) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return }
        let ux = dx / length, uy = dy / length
        let wing = size * 0.46
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - ux * size - uy * wing, y: end.y - uy * size + ux * wing))
        head.addLine(to: CGPoint(x: end.x - ux * size * 0.82, y: end.y - uy * size * 0.82))
        head.addLine(to: CGPoint(x: end.x - ux * size + uy * wing, y: end.y - uy * size - ux * wing))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

extension Color {
    #if canImport(AppKit)
    static let nodeFill = Color(nsColor: .controlBackgroundColor)
    static let labelBackground = Color(nsColor: .windowBackgroundColor)
    static let canvasBackground = Color(nsColor: .textBackgroundColor)
    #else
    static let nodeFill = Color(uiColor: .secondarySystemBackground)
    static let labelBackground = Color(uiColor: .systemBackground)
    static let canvasBackground = Color(uiColor: .systemBackground)
    #endif
}
