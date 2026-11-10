import Foundation

struct BundledPath: Sendable {
    var index: Int
    var points: [Point]
}

struct BundlingResult: Sendable {
    var paths: [BundledPath]
    var metrics: LayoutExecutionMetrics
    var unroutable: [Int] = []
}

struct BundlingState: Sendable {
    var positions: [SIMD2<Float>]
    var offsets: [UInt32]
    var compatible: [SIMD2<UInt32>]
    var springs: [Float]
    var segments: Int
}
