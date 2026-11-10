/// A frame grows to contain its contents. Measure title text in the caller's renderer.
public struct GroupFrameOptions: Hashable, Codable, Sendable {
    public var padding: LayoutInsets
    public var headerSize: Size

    /// Gap between the bottom of the header band and the group's content. Ignored when the header has no height.
    public var headerSpacing: Float
    public var minimumSize: Size

    public init(
        padding: LayoutInsets = LayoutInsets(),
        headerSize: Size = Size(),
        headerSpacing: Float = 12,
        minimumSize: Size = Size()
    ) {
        self.padding = padding
        self.headerSize = headerSize
        self.headerSpacing = headerSpacing
        self.minimumSize = minimumSize
    }

    public init(from decoder: Decoder) throws {
        // Payloads written before `headerSpacing` existed still decode, with the default gap.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        padding = try c.decode(LayoutInsets.self, forKey: .padding)
        headerSize = try c.decode(Size.self, forKey: .headerSize)
        headerSpacing = try c.decodeIfPresent(Float.self, forKey: .headerSpacing) ?? 12
        minimumSize = try c.decode(Size.self, forKey: .minimumSize)
    }

    /// The vertical space the header occupies above the content: the band plus its trailing gap.
    var headerExtent: Float { headerSize.height > 0 ? headerSize.height + headerSpacing : 0 }

    func validate() throws {
        guard
            [
                padding.top, padding.left, padding.bottom, padding.right, headerSize.width, headerSize.height,
                headerSpacing, minimumSize.width, minimumSize.height,
            ]
            .allSatisfy({ $0.isFinite && $0 >= 0 })
        else {
            throw LayoutExecutionError.invalidInput("Frame dimensions and padding must be finite and nonnegative.")
        }
    }
}
