import Foundation
import SwiftGraph

#if os(macOS)
import CoreGraphics
import CoreText
import ImageIO
#endif

enum VisualRenderError: Error { case invalidCanvas, pngUnavailable, imageCreation }
