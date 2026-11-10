import CoreGraphics
import Foundation
import SwiftGraph

extension CGRect {
    public init(_ rect: Rect) {
        self.init(x: CGFloat(rect.x), y: CGFloat(rect.y), width: CGFloat(rect.width), height: CGFloat(rect.height))
    }
}

extension CGPoint {
    public init(_ point: Point) {
        self.init(x: CGFloat(point.x), y: CGFloat(point.y))
    }
}
