extension LayoutNode {
    /// The part of a group's header band that its title occupies: the band's leading `headerSize.width`
    /// (the whole band when no width was given). Routes must avoid this rectangle, but may cross the rest of the
    /// band, so edges can enter a group's first row from above instead of wrapping round through the side padding.
    public var groupTitleBounds: Rect? {
        guard isGroup, let band = groupHeaderBounds, band.width > 0, band.height > 0 else { return nil }
        let titleWidth = groupFrame?.headerSize.width ?? 0
        return Rect(
            x: band.x,
            y: band.y,
            width: titleWidth > 0 ? min(band.width, titleWidth) : band.width,
            height: band.height
        )
    }
}
