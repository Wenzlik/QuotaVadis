import SwiftUI
import QuotaCore

/// Two panes side by side for windows regular in both axes: iPad and iPhone Duo's inner display. On iOS 27.1 the
/// system's split arrangement places them around the fold; before that (no hinged device exists) a plain HStack.
struct SplitPanes<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        // `ArrangementView` exists only in the iOS 27.1 SDK; #available guards the runtime, not the compile.
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary.avoidsReservedRegions()
            } secondary: {
                secondary.avoidsReservedRegions()
            }
            .arrangementViewStyle(.split)
        } else {
            stack
        }
        #else
        stack
        #endif
    }

    private var stack: some View {
        HStack(spacing: 0) {
            primary.frame(minWidth: 320, maxWidth: 440)
            Divider().ignoresSafeArea()
            secondary.frame(maxWidth: .infinity)
        }
    }
}

extension View {
    /// Caps the width and centres it on windows regular in both axes. Every iPhone layout, an iPhone Max in landscape
    /// included, keeps the full width it had.
    func readableWidth(_ maxWidth: CGFloat) -> some View { modifier(ReadableWidth(maxWidth: maxWidth)) }

    /// Keeps text and controls off regions the system reserves at this view's edges (iOS 27.1): iPhone Duo's side
    /// status column, the fold beside a pane. Pads the safe area, so backgrounds still run to the edge. Changes
    /// nothing where the system reserves nothing, or before iOS 27.1.
    func avoidsReservedRegions() -> some View { modifier(AvoidsReservedRegions()) }
}

private struct AvoidsReservedRegions: ViewModifier {
    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            // Measured outside the padding, so the padding never feeds back into the measurement.
            content
                .safeAreaPadding(insets)
                .onGeometryChange(for: ReservedEdgeInsets.self) { proxy in
                    let regions = proxy.reservedRegions(kind: .occlusion) + proxy.reservedRegions(kind: .division)
                    return ReservedEdgeInsets(avoiding: regions.map(\.frame), in: proxy.size)
                } action: { edges in
                    insets = EdgeInsets(top: edges.top, leading: edges.leading, bottom: edges.bottom, trailing: edges.trailing)
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: horizontalSizeClass == .regular && verticalSizeClass == .regular ? maxWidth : .infinity)
            .frame(maxWidth: .infinity)
    }
}
