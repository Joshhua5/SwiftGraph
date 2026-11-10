import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Theme and layout-rendering parameters for `GraphCanvas` and `GraphView`.
///
/// The default values match the presentation style of `graph-layout-previews`.
public struct GraphStyle: Sendable, Equatable {
    // MARK: Canvas & Scaling
    public var canvasBackground: Color
    public var worldPadding: CGFloat
    public var maxFitScale: CGFloat

    // MARK: Typography
    public var baseFontSize: CGFloat
    public var minimumLegibleFontSize: CGFloat

    // MARK: Leaf Nodes
    public var nodeFill: Color
    public var nodeStroke: Color
    public var nodeTextColor: Color
    public var nodeCornerRadius: CGFloat
    public var nodeStrokeWidth: CGFloat
    public var nodeFontWeight: Font.Weight

    // MARK: Groups
    public var groupPalette: [Color]
    public var groupFillOpacity: Double
    public var groupHeaderOpacity: Double
    public var groupStrokeOpacity: Double
    public var groupCornerRadius: CGFloat
    public var groupStrokeWidth: CGFloat
    public var groupDashUnit: CGFloat
    public var groupFontWeight: Font.Weight

    // MARK: Edges
    public var edgePalette: [Color]
    public var selfLoopColor: Color
    public var edgeLineWidth: CGFloat
    public var edgeCornerRadius: CGFloat
    public var arrowSize: CGFloat
    public var showsBridges: Bool
    public var showsPortDots: Bool
    public var showsArrowheads: Bool

    // MARK: Labels
    public var showsLabels: Bool
    public var labelBackground: Color
    public var labelStroke: Color
    public var labelTextColor: Color

    // MARK: Swimlanes
    public var lanePalette: [Color]
    public var laneFillOpacity: Double
    public var laneHeaderOpacity: Double
    public var laneStrokeOpacity: Double
    public var laneCornerRadius: CGFloat

    public static let `default` = GraphStyle()

    public init(
        canvasBackground: Color = .graphCanvasBackground,
        worldPadding: CGFloat = 28,
        maxFitScale: CGFloat = 1.6,
        baseFontSize: CGFloat = 11.5,
        minimumLegibleFontSize: CGFloat = 4.5,
        nodeFill: Color = .graphNodeFill,
        nodeStroke: Color = Color.accentColor.opacity(0.88),
        nodeTextColor: Color = .primary,
        nodeCornerRadius: CGFloat = 6,
        nodeStrokeWidth: CGFloat = 1.45,
        nodeFontWeight: Font.Weight = .medium,
        groupPalette: [Color] = [.blue, .purple, .teal, .orange, .pink],
        groupFillOpacity: Double = 0.055,
        groupHeaderOpacity: Double = 0.11,
        groupStrokeOpacity: Double = 0.65,
        groupCornerRadius: CGFloat = 8,
        groupStrokeWidth: CGFloat = 1.15,
        groupDashUnit: CGFloat = 5,
        groupFontWeight: Font.Weight = .semibold,
        edgePalette: [Color] = [
            Color(red: 0.22, green: 0.42, blue: 0.78),
            Color(red: 0.08, green: 0.52, blue: 0.56),
            Color(red: 0.46, green: 0.32, blue: 0.76),
            Color(red: 0.72, green: 0.36, blue: 0.14),
            Color(red: 0.18, green: 0.56, blue: 0.34),
            Color(red: 0.68, green: 0.22, blue: 0.44),
        ],
        selfLoopColor: Color = .orange,
        edgeLineWidth: CGFloat = 1.3,
        edgeCornerRadius: CGFloat = 6,
        arrowSize: CGFloat = 6.8,
        showsBridges: Bool = true,
        showsPortDots: Bool = true,
        showsArrowheads: Bool = true,
        showsLabels: Bool = true,
        labelBackground: Color = Color.graphLabelBackground.opacity(0.94),
        labelStroke: Color = Color.secondary.opacity(0.32),
        labelTextColor: Color = .secondary,
        lanePalette: [Color] = [.blue, .teal],
        laneFillOpacity: Double = 0.045,
        laneHeaderOpacity: Double = 0.11,
        laneStrokeOpacity: Double = 0.35,
        laneCornerRadius: CGFloat = 8
    ) {
        self.canvasBackground = canvasBackground
        self.worldPadding = worldPadding
        self.maxFitScale = maxFitScale
        self.baseFontSize = baseFontSize
        self.minimumLegibleFontSize = minimumLegibleFontSize
        self.nodeFill = nodeFill
        self.nodeStroke = nodeStroke
        self.nodeTextColor = nodeTextColor
        self.nodeCornerRadius = nodeCornerRadius
        self.nodeStrokeWidth = nodeStrokeWidth
        self.nodeFontWeight = nodeFontWeight
        self.groupPalette = groupPalette
        self.groupFillOpacity = groupFillOpacity
        self.groupHeaderOpacity = groupHeaderOpacity
        self.groupStrokeOpacity = groupStrokeOpacity
        self.groupCornerRadius = groupCornerRadius
        self.groupStrokeWidth = groupStrokeWidth
        self.groupDashUnit = groupDashUnit
        self.groupFontWeight = groupFontWeight
        self.edgePalette = edgePalette
        self.selfLoopColor = selfLoopColor
        self.edgeLineWidth = edgeLineWidth
        self.edgeCornerRadius = edgeCornerRadius
        self.arrowSize = arrowSize
        self.showsBridges = showsBridges
        self.showsPortDots = showsPortDots
        self.showsArrowheads = showsArrowheads
        self.showsLabels = showsLabels
        self.labelBackground = labelBackground
        self.labelStroke = labelStroke
        self.labelTextColor = labelTextColor
        self.lanePalette = lanePalette
        self.laneFillOpacity = laneFillOpacity
        self.laneHeaderOpacity = laneHeaderOpacity
        self.laneStrokeOpacity = laneStrokeOpacity
        self.laneCornerRadius = laneCornerRadius
    }
}

// MARK: - SwiftUI Environment Support
