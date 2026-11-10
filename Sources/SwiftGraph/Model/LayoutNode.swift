/// Mutable reference identity is intentional. Confine a graph and its pipeline to one task.
public final class LayoutNode: Hashable {
    public let id: String
    public var name: String
    public var bounds: Rect
    public var data: Any?
    public var isGroup = false

    /// Nil uses the recursive wrapper's legacy `groupPadding`.
    public var groupFrame: GroupFrameOptions?

    /// Computed world-coordinate rectangles after recursive layout.
    public internal(set) var groupContentBounds: Rect?
    public internal(set) var groupHeaderBounds: Rect?
    public var children: [LayoutNode] = []
    public weak var parent: LayoutNode?
    public var tags: Set<String> = []
    public var metadata: [String: Any] = [:]

    public init(id: String, width: Float, height: Float, data: Any? = nil) {
        self.id = id
        name = id
        bounds = Rect(width: width, height: height)
        self.data = data
    }

    @_disfavoredOverload
    public convenience init(id: String, width: Double, height: Double, data: Any? = nil) {
        self.init(id: id, width: Float(width), height: Float(height), data: data)
    }

    public var x: Float {
        get { bounds.x }
        set { bounds.x = newValue }
    }

    public var y: Float {
        get { bounds.y }
        set { bounds.y = newValue }
    }

    public var width: Float {
        get { bounds.width }
        set { bounds.width = newValue }
    }

    public var height: Float {
        get { bounds.height }
        set { bounds.height = newValue }
    }

    public var center: Point {
        get { bounds.center }
        set {
            bounds.x = newValue.x - width / 2
            bounds.y = newValue.y - height / 2
        }
    }

    public static func == (a: LayoutNode, b: LayoutNode) -> Bool { a === b }

    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
