import Foundation
import SwiftGraph

struct VisualSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var id: String
    var family: String
    var title: String
    var configuration: [String: String]
    var contracts: VisualContracts
    var nodes: [VisualNode]
    var edges: [VisualEdge]
    var previousBounds: [String: Rect] = [:]
    var fixedCenters: [String: Point] = [:]
    var reportedMetrics: [String: Double] = [:]
    var measuredMetrics: [String: Double]?
    var notes: [String] = []

    init(case item: VisualCase, drawing: VisualDrawing) {
        id = item.id
        family = item.family
        title = item.title
        configuration = item.configuration
        contracts = item.contracts
        nodes = drawing.graph.nodes.map {
            VisualNode(
                id: $0.id,
                name: $0.name,
                bounds: $0.bounds,
                parent: $0.parent === drawing.graph.root ? nil : $0.parent?.id,
                group: $0.isGroup,
                contentBounds: $0.groupContentBounds,
                headerBounds: $0.groupHeaderBounds,
                titleBounds: $0.groupTitleBounds
            )
        }
        edges = drawing.graph.edges.enumerated()
            .map { index, edge in
                VisualEdge(
                    id: "e\(index)",
                    source: edge.source.id,
                    target: edge.target.id,
                    path: edge.path,
                    label: edge.data as? String,
                    labelBounds: edge.labelBounds,
                    width: drawing.edgeWidths.indices.contains(index) ? drawing.edgeWidths[index] : 1.5,
                    fallback: drawing.fallbackEdges.contains(index),
                    bidirectional: drawing.bidirectionalEdges.contains(index) ? true : nil
                )
            }
        previousBounds = drawing.previousBounds
        fixedCenters = drawing.fixedCenters
        reportedMetrics = drawing.reportedMetrics
        notes = drawing.notes
    }

    var isFinite: Bool {
        nodes.allSatisfy {
            valid($0.bounds) && $0.contentBounds.map(valid) != false && $0.headerBounds.map(valid) != false
        }
            && edges.allSatisfy {
                valid($0.labelBounds) && $0.width.isFinite && $0.width > 0
                    && $0.path.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            } && previousBounds.values.allSatisfy(valid)
            && fixedCenters.values.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }
}

func valid(_ r: Rect) -> Bool {
    [r.x, r.y, r.width, r.height, r.right, r.bottom].allSatisfy(\.isFinite) && r.width >= 0 && r.height >= 0
}
