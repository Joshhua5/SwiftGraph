import Foundation

public enum OrganicLayoutError: Error, CustomStringConvertible {
    case metalUnavailable
    case invalidConfiguration(String)
    case metalFailure(String)

    public var description: String {
        switch self {
        case .metalUnavailable: return "No Metal compute device is available. Select cpuExact or cpuBarnesHut."
        case .invalidConfiguration(let message): return "Invalid layout input: \(message)"
        case .metalFailure(let message): return "Metal layout failed: \(message)"
        }
    }
}
