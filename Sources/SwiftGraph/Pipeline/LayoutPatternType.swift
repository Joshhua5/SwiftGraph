import Foundation

public enum LayoutPatternType: String, CaseIterable, Sendable {
    case standardHierarchical, standardOrganic, standardTree, standardCircular
    case progressiveRefinement, hybridLayout
    case enterpriseArchitecture, networkTopology, callGraph, socialNetwork, organizationChart, dataFlow, mindMap
    case smallGraphPreset, mediumGraphPreset, largeGraphPreset, denseGraphPreset
}
