import Foundation
import SwiftGraph

#if canImport(CryptoKit)
import CryptoKit
#endif

struct VisualManifest: Codable {
    var version = 1
    var kind: String
    var command: [String]
    var environment: [String: String]
    var cases: [VisualResult]
    var contactSheets: [String] = []
    var failed: Bool { cases.contains(where: \.failed) }
}
