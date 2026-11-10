import SwiftUI

/// Draws a `GraphSnapshot` scaled to fit the available space (world y grows downwards, like SwiftUI).
///
/// Customize the appearance globally using `.graphStyle(_:)` or per element using
/// `.graphNodeStyle(_:)`, `.graphGroupStyle(_:)`, `.graphEdgeStyle(_:)`, and `.graphLaneStyle(_:)`.
public struct GraphCanvas: View {
    public let snapshot: GraphSnapshot
    public var showLabels: Bool?
    public var zoom: CGFloat
    public var pan: CGSize

    @Environment(\.graphStyle) private var style
    @Environment(\.graphNodeStyleResolver) private var nodeStyleResolver
    @Environment(\.graphGroupStyleResolver) private var groupStyleResolver
    @Environment(\.graphEdgeStyleResolver) private var edgeStyleResolver
    @Environment(\.graphLaneStyleResolver) private var laneStyleResolver

    public init(
        snapshot: GraphSnapshot,
        showLabels: Bool? = nil,
        zoom: CGFloat = 1,
        pan: CGSize = .zero
    ) {
        self.snapshot = snapshot
        self.showLabels = showLabels
        self.zoom = zoom
        self.pan = pan
    }

    public init(
        snapshot: GraphSnapshot,
        viewport: GraphViewport,
        showLabels: Bool? = nil
    ) {
        self.snapshot = snapshot
        self.showLabels = showLabels
        self.zoom = viewport.zoom
        self.pan = viewport.pan
    }

    public var body: some View {
        let style = self.style
        let nodeResolver = self.nodeStyleResolver
        let groupResolver = self.groupStyleResolver
        let edgeResolver = self.edgeStyleResolver
        let laneResolver = self.laneStyleResolver
        let labelsVisible = showLabels ?? style.showsLabels

        Canvas { context, size in
            let world = snapshot.worldBounds.insetBy(dx: -style.worldPadding, dy: -style.worldPadding)
            let fitScale = min(size.width / max(world.width, 1), size.height / max(world.height, 1), style.maxFitScale)
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
            let fontSize = max(6.5, min(13, style.baseFontSize * scale))
            let defaultEdgeWidth = max(0.85, min(1.6, style.edgeLineWidth * scale))
            let arrowSize = max(4.0, min(8.0, style.arrowSize * scale))

            // 1. Swimlanes
            let lanePalette = style.lanePalette.isEmpty ? [Color.blue, Color.teal] : style.lanePalette
            for (index, lane) in snapshot.lanes.enumerated() {
                let override = laneResolver?(lane, index) ?? lane.style
                let frame = map(lane.frame)
                let baseRadius = override?.cornerRadius ?? style.laneCornerRadius
                let radius = max(4, baseRadius * scale)
                let shape = Path(roundedRect: frame, cornerRadius: radius)
                let tint: Color = override?.tint ?? lanePalette[index % lanePalette.count]
                let fillOpacity = override?.fillOpacity ?? style.laneFillOpacity
                let headerOpacity = override?.headerOpacity ?? style.laneHeaderOpacity
                let strokeOpacity = override?.strokeOpacity ?? style.laneStrokeOpacity

                context.fill(shape, with: .color(tint.opacity(fillOpacity)))

                let headerHeight = max(fontSize + 8, lane.headerHeight * scale)
                let headerRect = CGRect(
                    x: frame.minX,
                    y: frame.minY,
                    width: frame.width,
                    height: min(headerHeight, frame.height)
                )
                context.drawLayer { headerLayer in
                    headerLayer.clip(to: shape)
                    headerLayer.fill(Path(headerRect), with: .color(tint.opacity(headerOpacity)))
                }
                var divider = Path()
                divider.move(to: CGPoint(x: frame.minX, y: headerRect.maxY))
                divider.addLine(to: CGPoint(x: frame.maxX, y: headerRect.maxY))
                context.stroke(divider, with: .color(tint.opacity(strokeOpacity * 0.8)), lineWidth: max(0.75, scale))
                context.stroke(shape, with: .color(tint.opacity(strokeOpacity)), lineWidth: max(0.85, 1.1 * scale))
                context.draw(
                    Text(lane.title).font(.system(size: fontSize, weight: .semibold)).foregroundColor(tint),
                    at: CGPoint(x: headerRect.midX, y: headerRect.midY)
                )
            }

            // 2. Group containers (outer to inner)
            let groupPalette = style.groupPalette.isEmpty ? [Color.blue] : style.groupPalette
            for node in snapshot.nodes where node.isGroup {
                let override = groupResolver?(node) ?? node.groupStyle
                let color = override?.tint ?? groupPalette[node.depth % groupPalette.count]
                let frame = map(node.frame)
                let baseRadius = override?.cornerRadius ?? style.groupCornerRadius
                let radius = max(4, baseRadius * scale)
                let shape = Path(roundedRect: frame, cornerRadius: radius)
                let fillOpacity = override?.fillOpacity ?? style.groupFillOpacity
                let headerOpacity = override?.headerOpacity ?? style.groupHeaderOpacity
                let strokeOpacity = override?.strokeOpacity ?? style.groupStrokeOpacity
                let fontWeight = override?.fontWeight ?? style.groupFontWeight

                context.fill(shape, with: .color(color.opacity(fillOpacity)))

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
                        headerLayer.fill(Path(headerBand), with: .color(color.opacity(headerOpacity)))
                    }
                    var divider = Path()
                    divider.move(to: CGPoint(x: frame.minX, y: headerBand.maxY))
                    divider.addLine(to: CGPoint(x: frame.maxX, y: headerBand.maxY))
                    context.stroke(divider, with: .color(color.opacity(0.28)), lineWidth: max(0.75, 0.9 * scale))
                    let titleBox = CGSize(width: frame.width - titleInset * 2, height: reservedHeader.height)
                    if let title = fittedText(
                        context,
                        node.name,
                        weight: fontWeight,
                        color: color,
                        preferredSize: fontSize,
                        minimumSize: style.minimumLegibleFontSize,
                        in: titleBox
                    ) {
                        context.draw(
                            title,
                            at: CGPoint(x: frame.minX + titleInset, y: headerBand.midY),
                            anchor: .leading
                        )
                    }
                } else if let title = fittedText(
                    context,
                    node.name,
                    weight: fontWeight,
                    color: color,
                    preferredSize: fontSize,
                    minimumSize: style.minimumLegibleFontSize,
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
                    context.fill(tabShape, with: .color(style.canvasBackground))
                    context.fill(tabShape, with: .color(color.opacity(0.16)))
                    context.draw(title, at: CGPoint(x: tab.midX, y: tab.midY), anchor: .center)
                }

                let dashPattern: [CGFloat]
                if let customDash = override?.dash {
                    dashPattern = customDash.map { max(1, $0 * scale) }
                } else {
                    let dashUnit = max(2.5, style.groupDashUnit * scale)
                    dashPattern = [dashUnit, dashUnit * 0.65]
                }
                let baseLineWidth = override?.lineWidth ?? style.groupStrokeWidth
                context.stroke(
                    shape,
                    with: .color(color.opacity(strokeOpacity)),
                    style: StrokeStyle(lineWidth: max(0.9, baseLineWidth * scale), dash: dashPattern)
                )
            }

            // 3. Edges with crossing bridges, rounded bends, port dots, and arrowheads
            let edgePalette = style.edgePalette.isEmpty ? [Color.accentColor] : style.edgePalette
            for edge in snapshot.edges where edge.points.count >= 2 {
                let override = edgeResolver?(edge) ?? edge.style
                let points = edge.points.map(map)
                let defaultColor: Color =
                    edge.isSelfLoop
                    ? style.selfLoopColor
                    : edgePalette[edge.id % edgePalette.count].opacity(0.88)
                let color = override?.color ?? defaultColor
                let edgeWidth = override?.lineWidth.map { max(0.75, $0 * scale) } ?? defaultEdgeWidth
                let showsArrowhead = override?.showsArrowhead ?? style.showsArrowheads
                let showsPortDot = override?.showsPortDot ?? style.showsPortDots

                // Draw bridge halos over earlier edges at crossing points.
                if style.showsBridges, !edge.bridges.isEmpty {
                    var bridgePath = Path()
                    for bridge in edge.bridges {
                        bridgePath.move(to: map(bridge.start))
                        bridgePath.addLine(to: map(bridge.end))
                    }
                    context.stroke(
                        bridgePath,
                        with: .color(style.canvasBackground),
                        style: StrokeStyle(lineWidth: edgeWidth + max(2.5, 3.4 * scale), lineCap: .butt)
                    )
                }

                let trimEndAmount = showsArrowhead ? arrowSize * 0.55 : 0
                let trimStartAmount = (showsArrowhead && edge.isBidirectional) ? arrowSize * 0.55 : 0
                let trimmed = trimmedPoints(points, trimStart: trimStartAmount, trimEnd: trimEndAmount)
                let baseCornerRadius = override?.cornerRadius ?? style.edgeCornerRadius
                let path = roundedPath(for: trimmed, cornerRadius: max(2, baseCornerRadius * scale))
                let dash = override?.dash?.map { max(1, $0 * scale) } ?? []
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: edgeWidth, lineCap: .round, lineJoin: .round, dash: dash)
                )

                if showsPortDot, !edge.isBidirectional, let start = points.first {
                    let dotRadius = max(1.2, min(2.4, 1.8 * scale))
                    let dotRect = CGRect(
                        x: start.x - dotRadius,
                        y: start.y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    context.fill(Path(ellipseIn: dotRect), with: .color(color))
                }

                if showsArrowhead {
                    if let end = points.last,
                        let from = points.dropLast().last(where: { hypot(end.x - $0.x, end.y - $0.y) > 0.5 })
                    {
                        drawArrowhead(in: &context, from: from, to: end, size: arrowSize, color: color)
                    }
                    if edge.isBidirectional, let start = points.first,
                        let from = points.dropFirst().first(where: { hypot(start.x - $0.x, start.y - $0.y) > 0.5 })
                    {
                        drawArrowhead(in: &context, from: from, to: start, size: arrowSize, color: color)
                    }
                }
            }

            // 4. Leaf nodes
            for node in snapshot.nodes where !node.isGroup {
                let override = nodeResolver?(node) ?? node.nodeStyle
                let frame = map(node.frame)
                let baseRadius = override?.cornerRadius ?? style.nodeCornerRadius
                let radius = max(3, baseRadius * scale)
                let shape = Path(roundedRect: frame, cornerRadius: radius)
                let fill = override?.fill ?? style.nodeFill
                let stroke = override?.stroke ?? style.nodeStroke
                let textColor = override?.textColor ?? style.nodeTextColor
                let fontWeight = override?.fontWeight ?? style.nodeFontWeight
                let baseStrokeWidth = override?.lineWidth ?? style.nodeStrokeWidth
                let dash = override?.dash?.map { max(1, $0 * scale) } ?? []

                context.fill(shape, with: .color(fill))
                context.stroke(
                    shape,
                    with: .color(stroke),
                    style: StrokeStyle(lineWidth: max(1.0, baseStrokeWidth * scale), dash: dash)
                )

                let labelBox = CGSize(width: frame.width - max(4, 10 * scale), height: frame.height)
                if let label = fittedText(
                    context,
                    node.name,
                    weight: fontWeight,
                    color: textColor,
                    preferredSize: fontSize,
                    minimumSize: style.minimumLegibleFontSize,
                    in: labelBox
                ) {
                    context.draw(label, at: CGPoint(x: frame.midX, y: frame.midY))
                }
            }

            // 5. Edge labels
            guard labelsVisible else { return }
            for edge in snapshot.edges {
                guard let label = edge.label, let labelFrame = edge.labelFrame else { continue }
                let frame = map(labelFrame).insetBy(dx: -2 * scale, dy: -1 * scale)
                let badge = Path(roundedRect: frame, cornerRadius: max(2.5, 4 * scale))
                context.fill(badge, with: .color(style.labelBackground))
                context.stroke(badge, with: .color(style.labelStroke), lineWidth: max(0.6, 0.8 * scale))
                context.draw(
                    Text(label).font(.system(size: max(6, fontSize * 0.85), weight: .medium))
                        .foregroundColor(style.labelTextColor),
                    at: CGPoint(x: frame.midX, y: frame.midY)
                )
            }
        }
    }

    /// Resolves `string` at the largest size up to `preferredSize` that fits `box` (height capped to ~72% of
    /// the box so text keeps some margin), measuring the real glyph width. Returns `nil` when it would be illegible.
    private func fittedText(
        _ context: GraphicsContext,
        _ string: String,
        weight: Font.Weight,
        color: Color,
        preferredSize: CGFloat,
        minimumSize: CGFloat,
        in box: CGSize
    ) -> GraphicsContext.ResolvedText? {
        func resolve(_ size: CGFloat) -> GraphicsContext.ResolvedText {
            context.resolve(Text(string).font(.system(size: size, weight: weight)).foregroundColor(color))
        }
        var size = min(preferredSize, box.height * 0.72)
        guard box.width > 0, size >= minimumSize else { return nil }
        var resolved = resolve(size)
        let width = resolved.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width
        if width > box.width {
            size *= box.width / width
            guard size >= minimumSize else { return nil }
            resolved = resolve(size)
        }
        return resolved
    }

    /// Pulls endpoints slightly back along the terminal segment so stroke caps don't protrude through arrowhead tips.
    private func trimmedPoints(_ points: [CGPoint], trimStart: CGFloat, trimEnd: CGFloat) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var out = points
        if trimStart > 0 {
            let p0 = out[0]
            let p1 = out[1]
            let len = hypot(p1.x - p0.x, p1.y - p0.y)
            if len > trimStart * 1.5 {
                out[0] = CGPoint(x: p0.x + (p1.x - p0.x) / len * trimStart, y: p0.y + (p1.y - p0.y) / len * trimStart)
            }
        }
        if trimEnd > 0 {
            let n = out.count
            let pLast = out[n - 1]
            let pPrev = out[n - 2]
            let len = hypot(pLast.x - pPrev.x, pLast.y - pPrev.y)
            if len > trimEnd * 1.5 {
                out[n - 1] = CGPoint(
                    x: pLast.x - (pLast.x - pPrev.x) / len * trimEnd,
                    y: pLast.y - (pLast.y - pPrev.y) / len * trimEnd
                )
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
            let p0 = points[i - 1]
            let p1 = points[i]
            let p2 = points[i + 1]
            let v1 = CGPoint(x: p0.x - p1.x, y: p0.y - p1.y)
            let v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
            let len1 = hypot(v1.x, v1.y)
            let len2 = hypot(v2.x, v2.y)
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

    private func drawArrowhead(
        in context: inout GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        size: CGFloat,
        color: Color
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return }
        let ux = dx / length
        let uy = dy / length
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
