import CoreGraphics

/// How far content must stay off each edge of a view so no text or control sits under a region the system reserves:
/// iPhone Duo's side status column on the outer display, or the fold. Frames are in the view's own
/// layout-direction-aware space (x = 0 is the leading edge). Each region gives up the smaller side of the view along
/// with the region itself, so content keeps the larger side: a column at an edge pads that edge, a fold through a
/// full-window screen leaves it on one half (the leading one, or the top one in tabletop, when the halves are equal).
public struct ReservedEdgeInsets: Equatable, Sendable {
    public var top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0

    public init(avoiding regions: [CGRect], in size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        for region in regions {
            let r = region.intersection(bounds)
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            if r.height >= r.width {
                // A column: keep the wider side of it.
                if r.minX < size.width - r.maxX { leading = max(leading, r.maxX) }
                else { trailing = max(trailing, size.width - r.minX) }
            } else {
                // A band: keep the taller side of it.
                if r.minY < size.height - r.maxY { top = max(top, r.maxY) }
                else { bottom = max(bottom, size.height - r.minY) }
            }
        }
    }
}
