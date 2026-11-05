import SwiftUI

/// Draws a `GraphSnapshot` scaled to fit the available space (world y grows downwards, like SwiftUI).
struct GraphCanvas: View {
    let snapshot: GraphSnapshot
    var showLabels = true

    private let groupColors: [Color] = [.blue, .purple, .teal, .orange, .pink]

    var body: some View {
        Canvas { context, size in
            let world = snapshot.worldBounds.insetBy(dx: -24, dy: -24)
            let scale = min(size.width / max(world.width, 1), size.height / max(world.height, 1), 2)
            // Centre the drawing in the canvas.
            let offset = CGPoint(x: (size.width - world.width * scale) / 2 - world.minX * scale,
                                 y: (size.height - world.height * scale) / 2 - world.minY * scale)
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
            func map(_ r: CGRect) -> CGRect {
                CGRect(origin: map(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale))
            }
            let fontSize = max(7, min(13, 12 * scale))

            for node in snapshot.nodes where node.isGroup {
                let color = groupColors[node.depth % groupColors.count]
                let frame = map(node.frame)
                let shape = Path(roundedRect: frame, cornerRadius: 8 * scale)
                context.fill(shape, with: .color(color.opacity(0.06)))
                context.stroke(shape, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                let header = node.headerFrame.map(map) ?? CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: fontSize + 8)
                context.draw(Text(node.name).font(.system(size: fontSize, weight: .semibold)).foregroundColor(color),
                             at: CGPoint(x: header.minX + 8, y: header.midY), anchor: .leading)
            }

            for edge in snapshot.edges where edge.points.count >= 2 {
                let points = edge.points.map(map)
                var path = Path()
                path.addLines(points)
                let color: Color = edge.isSelfLoop ? .orange : .secondary
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                drawArrowhead(in: &context, from: points[points.count - 2], to: points[points.count - 1], color: color)
                if edge.isBidirectional { drawArrowhead(in: &context, from: points[1], to: points[0], color: color) }
            }

            for node in snapshot.nodes where !node.isGroup {
                let frame = map(node.frame)
                let shape = Path(roundedRect: frame, cornerRadius: 6 * scale)
                context.fill(shape, with: .color(Color.nodeFill))
                context.stroke(shape, with: .color(.accentColor), lineWidth: 1.5)
                context.draw(Text(node.name).font(.system(size: fontSize)), at: CGPoint(x: frame.midX, y: frame.midY))
            }

            guard showLabels else { return }
            for edge in snapshot.edges {
                guard let label = edge.label, let labelFrame = edge.labelFrame else { continue }
                let frame = map(labelFrame)
                context.fill(Path(roundedRect: frame, cornerRadius: 3), with: .color(Color.labelBackground.opacity(0.9)))
                context.draw(Text(label).font(.system(size: fontSize * 0.85)).foregroundColor(.secondary),
                             at: CGPoint(x: frame.midX, y: frame.midY))
            }
        }
    }

    private func drawArrowhead(in context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, color: Color) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return }
        let ux = dx / length, uy = dy / length, size: CGFloat = 7
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - ux * size - uy * size * 0.5, y: end.y - uy * size + ux * size * 0.5))
        head.addLine(to: CGPoint(x: end.x - ux * size + uy * size * 0.5, y: end.y - uy * size - ux * size * 0.5))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

extension Color {
    #if canImport(AppKit)
    static let nodeFill = Color(nsColor: .controlBackgroundColor)
    static let labelBackground = Color(nsColor: .windowBackgroundColor)
    #else
    static let nodeFill = Color(uiColor: .secondarySystemBackground)
    static let labelBackground = Color(uiColor: .systemBackground)
    #endif
}
