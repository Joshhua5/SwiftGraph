import SwiftUI

/// Viewport zoom and pan state for interactive graph canvases.
public struct GraphViewport: Sendable, Equatable {
    public var zoom: CGFloat
    public var pan: CGSize
    public var minZoom: CGFloat
    public var maxZoom: CGFloat

    public init(
        zoom: CGFloat = 1,
        pan: CGSize = .zero,
        minZoom: CGFloat = 0.4,
        maxZoom: CGFloat = 6.0
    ) {
        self.zoom = zoom
        self.pan = pan
        self.minZoom = minZoom
        self.maxZoom = maxZoom
    }

    /// Multiplies the current zoom by `factor`, clamped to `minZoom...maxZoom`.
    public mutating func zoomIn(factor: CGFloat = 1.25) {
        zoom = min(maxZoom, zoom * factor)
    }

    /// Divides the current zoom by `factor`, clamped to `minZoom...maxZoom`.
    public mutating func zoomOut(factor: CGFloat = 1.25) {
        zoom = max(minZoom, zoom / factor)
    }

    /// Resets zoom to `1` and pan to `.zero`.
    public mutating func reset() {
        zoom = 1
        pan = .zero
    }
}

/// Wraps `GraphCanvas` with drag-to-pan and pinch-to-zoom gestures.
public struct InteractiveGraphCanvas: View {
    public let snapshot: GraphSnapshot
    public var showLabels: Bool?

    private var externalViewport: Binding<GraphViewport>?
    @State private var ownedViewport = GraphViewport()
    @State private var dragStartPan: CGSize?
    @State private var pinchStartZoom: CGFloat?

    private var viewportBinding: Binding<GraphViewport> {
        externalViewport ?? $ownedViewport
    }

    public init(
        snapshot: GraphSnapshot,
        viewport: Binding<GraphViewport>? = nil,
        showLabels: Bool? = nil
    ) {
        self.snapshot = snapshot
        self.externalViewport = viewport
        self.showLabels = showLabels
    }

    public var body: some View {
        let currentViewport = viewportBinding.wrappedValue
        GraphCanvas(
            snapshot: snapshot,
            viewport: currentViewport,
            showLabels: showLabels
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let basePan = dragStartPan ?? viewportBinding.wrappedValue.pan
                    if dragStartPan == nil { dragStartPan = basePan }
                    viewportBinding.wrappedValue.pan = CGSize(
                        width: basePan.width + value.translation.width,
                        height: basePan.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    dragStartPan = nil
                }
        )
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    let current = viewportBinding.wrappedValue
                    let baseZoom = pinchStartZoom ?? current.zoom
                    if pinchStartZoom == nil { pinchStartZoom = baseZoom }
                    viewportBinding.wrappedValue.zoom = max(
                        current.minZoom,
                        min(current.maxZoom, baseZoom * value)
                    )
                }
                .onEnded { _ in
                    pinchStartZoom = nil
                }
        )
    }
}
