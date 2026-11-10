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
