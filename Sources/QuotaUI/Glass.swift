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

/// A colour with separate light/dark variants: bright on dark glass, deeper on light backgrounds so
/// coloured text stays readable over a white desktop.
public func adaptiveColor(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
    #if os(macOS)
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let c = isDark ? dark : light
        return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    })
    #else
    Color(uiColor: UIColor { traits in
        let c = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    })
    #endif
}

/// Usage colour by level, shared by bars, labels and charts.
public func usageTint(_ percent: Double) -> Color {
    switch percent {
    case ..<50: adaptiveColor(light: (0.12, 0.55, 0.30), dark: (0.30, 0.78, 0.47))
    case ..<80: adaptiveColor(light: (0.72, 0.45, 0.00), dark: (0.98, 0.75, 0.25))
    default: adaptiveColor(light: (0.80, 0.16, 0.16), dark: (0.96, 0.36, 0.34))
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
