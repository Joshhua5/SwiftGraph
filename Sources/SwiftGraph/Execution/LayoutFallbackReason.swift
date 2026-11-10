import Foundation

public enum LayoutFallbackReason: String, Sendable {
    case belowThreshold, metalUnavailable, precisionLimit, noWork
}
