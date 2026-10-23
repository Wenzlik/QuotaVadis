import CoreGraphics
import Testing
@testable import QuotaCore

// iPhone Duo reserves screen regions (outer display's side status column, the inner display's fold). Content pads
// the edge a region sits on; a fold through the middle leaves content on the larger side.

private let size = CGSize(width: 400, height: 800)

@Test func nothingReservedGivesNoInsets() {
    let insets = ReservedEdgeInsets(avoiding: [.null, .zero], in: size)
    #expect(insets.top == 0 && insets.leading == 0 && insets.bottom == 0 && insets.trailing == 0)
}

@Test func sideColumnInsetsItsEdge() {
    let trailing = ReservedEdgeInsets(avoiding: [CGRect(x: 360, y: 0, width: 60, height: 800)], in: size)
    #expect(trailing.trailing == 40 && trailing.leading == 0)
    let leading = ReservedEdgeInsets(avoiding: [CGRect(x: -10, y: 100, width: 50, height: 300)], in: size)
    #expect(leading.leading == 40 && leading.trailing == 0)
}

@Test func bandsInsetTopAndBottom() {
    let insets = ReservedEdgeInsets(avoiding: [CGRect(x: 0, y: 0, width: 400, height: 30),
                                               CGRect(x: 0, y: 780, width: 400, height: 40)], in: size)
    #expect(insets.top == 30 && insets.bottom == 20)
}

@Test func foldKeepsContentOnTheLargerSide() {
    // Vertical fold just right of centre: content keeps the leading side.
    let fold = ReservedEdgeInsets(avoiding: [CGRect(x: 210, y: 0, width: 20, height: 800)], in: size)
    #expect(fold.trailing == 190 && fold.leading == 0)
    // Equal halves: leading side; tabletop band through the middle: top half.
    let centred = ReservedEdgeInsets(avoiding: [CGRect(x: 190, y: 0, width: 20, height: 800)], in: size)
    #expect(centred.trailing == 210 && centred.leading == 0)
    let tabletop = ReservedEdgeInsets(avoiding: [CGRect(x: 0, y: 390, width: 400, height: 20)], in: size)
    #expect(tabletop.bottom == 410 && tabletop.top == 0)
}

@Test func regionsOutsideAreIgnored() {
    let outside = CGRect(x: 420, y: 0, width: 40, height: 800)
    #expect(ReservedEdgeInsets(avoiding: [outside], in: size) == ReservedEdgeInsets(avoiding: [], in: size))
}
