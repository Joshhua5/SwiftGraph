import Foundation
import SwiftGraph
import SwiftGraphUI

/// Placement for a topology: either a complete `LayoutPatternType` preset, or a single algorithm
/// wrapped in recursive group layout so the topology's nested groups are respected.
enum TopologyLayout: Hashable, Sendable, Identifiable {
    case preset(LayoutPatternType)
    case algorithm(Algorithm)

    enum Algorithm: String, CaseIterable, Sendable {
        case hierarchical = "Hierarchical"
        case organic = "Organic"
        case tree = "Tree"
        case radialTree = "Radial Tree"
        case balloon = "Balloon"
        case circular = "Circular"
        case orthogonal = "Orthogonal"
        case barycenter = "Barycenter"

        func make(routesEdges: Bool = true, backend: LayoutBackend = .cpu) -> any AsyncLayoutAlgorithm {
            switch self {
            case .hierarchical:
                let hierarchical = HierarchicalLayoutOperation(backend: backend)
                hierarchical.configuration.routesEdges = routesEdges
                return hierarchical
            case .organic:
                let organic = OrganicLayoutOperation(backend: backend)
                organic.configuration.iterations = 300
                return organic
            case .tree:
                return TreeLayoutOperation(style: .tree, backend: backend)
            case .radialTree:
                return RadialLayoutOperation(style: .tree, backend: backend)
            case .balloon:
                return TreeLayoutOperation(style: .balloon, backend: backend)
            case .circular:
                return BasicLayoutOperation(style: .circular, backend: backend)
            case .orthogonal:
                return BasicLayoutOperation(style: .orthogonal, backend: backend)
            case .barycenter:
                return BarycenterLayoutOperation(backend: backend)
            }
        }
    }

    static let all: [TopologyLayout] = LayoutPatternType.allCases.map(preset) + Algorithm.allCases.map(algorithm)
    static let `default` = TopologyLayout.preset(.enterpriseArchitecture)

    var id: String { title }

    var title: String {
        switch self {
        case .preset(let pattern): pattern.rawValue
        case .algorithm(let algorithm): algorithm.rawValue
        }
    }
}
