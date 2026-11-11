import Foundation

/// What `LayeredRouter` needs from the layout that placed the drawing. The defaults are the directed layout's.
struct LayeredRoutingConfiguration {
    /// True when earlier routes should be kept where they still fit (the directed incremental and routes-only
    /// modes); false for a fresh drawing.
    var keepsPreviousRoutes = false

    /// Earlier routes by edge index, read only when `keepsPreviousRoutes` is true.
    var previousPaths: [Int: [Point]] = [:]
    var edgeWidths: [Float] = []

    /// Preferred separation between parallel runs; strokes never touch below the widest edge plus one.
    var edgeSpacing: Float = 10
    var clearance: Float = 10

    /// The smallest gap between rank columns when the coordinated strategy re-spaces ranks for their tracks.
    var minimumRankGap: Float = 100
}

extension LayeredRoutingConfiguration {
    init(_ directed: DirectedLayoutConfiguration) {
        keepsPreviousRoutes = directed.mode != .fresh
        previousPaths = directed.previousPaths
        edgeWidths = directed.edgeWidths
        edgeSpacing = directed.edgeSpacing
        clearance = directed.clearance
        minimumRankGap = directed.layerSpacing
    }
}
