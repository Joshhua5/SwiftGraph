import Foundation
import SwiftGraph

public enum ParityClassification: String, Codable, Sendable {
    case exact
    case floatEquivalent
    case heuristicDivergent
    case qualityRegression
}
