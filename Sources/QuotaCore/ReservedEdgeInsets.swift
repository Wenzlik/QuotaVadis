import Foundation

/// How far content must stay off each edge of a view so no text or control sits under a region the system reserves
/// there: iPhone Duo's side status column on the outer display, or the fold along a pane's edge. Frames are in the
/// view's own layout-direction-aware space (x = 0 is the leading edge). A region crossing the middle of the view gives
/// no inset; there the two-pane split is what keeps content off the fold.
public struct ReservedEdgeInsets: Equatable, Sendable {
    public var top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0

    public init(avoiding regions: [CGRect], in size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        for region in regions {
            let r = region.intersection(bounds)
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            if r.height >= r.width {
                // A column along a side.
                if r.minX <= 0.5 { leading = max(leading, r.maxX) }
                else if r.maxX >= size.width - 0.5 { trailing = max(trailing, size.width - r.minX) }
            } else {
                // A band across the top or bottom.
                if r.minY <= 0.5 { top = max(top, r.maxY) }
                else if r.maxY >= size.height - 0.5 { bottom = max(bottom, size.height - r.minY) }
            }
        }
    }
}
