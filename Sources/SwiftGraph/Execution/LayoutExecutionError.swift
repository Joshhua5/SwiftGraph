import Foundation

public enum LayoutExecutionError: Error, Equatable, Sendable {
    case invalidInput(String)
    case precisionLimit
    case staleGraph
}
