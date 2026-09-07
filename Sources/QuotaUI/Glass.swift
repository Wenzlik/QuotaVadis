import SwiftUI

/// Liquid Glass on macOS 26 / iOS 26, translucent material before that. One place to keep the look consistent.
public struct GlassCard: ViewModifier {
    let cornerRadius: CGFloat
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08)))
        }
    }
}

public extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View { modifier(GlassCard(cornerRadius: cornerRadius)) }
}

/// Usage colour by level, shared by bars and charts.
public func usageTint(_ percent: Double) -> Color {
    switch percent {
    case ..<50: Color(red: 0.30, green: 0.78, blue: 0.47)
    case ..<80: Color(red: 0.98, green: 0.75, blue: 0.25)
    default: Color(red: 0.96, green: 0.36, blue: 0.34)
    }
}

/// Rounded, glowing progress bar used everywhere a window or credit line is drawn.
public struct GlowBar: View {
    let percent: Double
    let height: CGFloat
    public init(percent: Double, height: CGFloat = 7) { self.percent = percent; self.height = height }

    public var body: some View {
        let tint = usageTint(percent)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(1, max(0, percent / 100))))
                    .shadow(color: tint.opacity(0.45), radius: 4, y: 1)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
