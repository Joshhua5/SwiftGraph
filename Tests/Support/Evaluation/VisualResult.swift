import Foundation
import SwiftGraph

#if canImport(CryptoKit)
import CryptoKit
#endif

struct VisualResult: Codable {
    var id: String
    var family: String
    var title: String
    var status: String
    var milliseconds: Double = 0
    var metrics: VisualMetrics?
    var difference: VisualDifference?
    var error: String?
    var hasSnapshot = false
    var hasBefore = false
    var notes: [String]?
    var failed: Bool { status == "contract-failure" || status == "error" }
}
