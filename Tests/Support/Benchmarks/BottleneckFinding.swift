import Foundation
import SwiftGraph

public struct BottleneckFinding: Codable, Equatable, Sendable {
    public var kind: BottleneckKind
    public var severity: String
    public var summary: String
    public var evidence: String

    public init(kind: BottleneckKind, severity: String, summary: String, evidence: String) {
        self.kind = kind
        self.severity = severity
        self.summary = summary
        self.evidence = evidence
    }
}
