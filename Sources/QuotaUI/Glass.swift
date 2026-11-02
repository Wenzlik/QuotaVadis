import SwiftUI
import QuotaCore

/// Liquid Glass on macOS 26 / iOS 26, translucent material before that. One place to keep the look consistent.
/// With Reduce Transparency on, an opaque grouped background instead.
public struct GlassCard: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(opaqueCardBackground, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.12)))
        } else if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08)))
        }
    }
}

private var opaqueCardBackground: Color {
    #if os(macOS)
    Color(nsColor: .controlBackgroundColor)
    #else
    Color(uiColor: .secondarySystemGroupedBackground)
    #endif
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
    switch UsageLevel(percent) {
    case .ok: adaptiveColor(light: (0.12, 0.55, 0.30), dark: (0.30, 0.78, 0.47))
    case .warning: adaptiveColor(light: (0.72, 0.45, 0.00), dark: (0.98, 0.75, 0.25))
    case .critical: adaptiveColor(light: (0.80, 0.16, 0.16), dark: (0.96, 0.36, 0.34))
    }
}

/// Colour for a limit's risk (bar, percentage, headline): fits green, tight orange, runs out / reached red.
/// Pair with `UsageForecast.Risk(usedPercent:forecast:)`, which falls back to the usage level without a forecast.
public func riskTint(_ risk: UsageForecast.Risk) -> Color { usageTint(riskTintPercent(risk)) }

/// `riskTint` as a percentage for `GlowBar(tintPercent:)`.
public func riskTintPercent(_ risk: UsageForecast.Risk) -> Double {
    switch risk {
    case .safe: 0
    case .watch: 60
    case .atRisk, .exhausted: 100
    }
}

/// Small risk-coloured text. Red text sits on a light/dark backdrop in a deeper (light) or paler (dark) red:
/// the bar red on tinted glass falls well under 4.5:1, this clears it on any card.
struct RiskTextStyle: ViewModifier {
    let risk: UsageForecast.Risk

    func body(content: Content) -> some View {
        if risk >= .atRisk {
            content
                .foregroundStyle(adaptiveColor(light: (0.66, 0.07, 0.07), dark: (1.00, 0.62, 0.59)))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(opaqueCardBackground.opacity(0.85), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            content.foregroundStyle(riskTint(risk))
        }
    }
}

public extension View {
    func riskTextStyle(_ risk: UsageForecast.Risk) -> some View { modifier(RiskTextStyle(risk: risk)) }
}

/// Rounded, glowing progress bar used everywhere a window or credit line is drawn.
public struct GlowBar: View {
    let percent: Double
    let height: CGFloat
    let marker: Double?
    let tintPercent: Double?
    public init(percent: Double, height: CGFloat = 7, marker: Double? = nil, tintPercent: Double? = nil) {
        self.percent = percent; self.height = height; self.marker = marker; self.tintPercent = tintPercent
    }

    public var body: some View {
        let tint = usageTint(tintPercent ?? percent)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                // Exactly zero is an empty track; anything above keeps a visible nub so 0.4 % is not "nothing".
                if percent > 0 {
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geo.size.width * min(1, percent / 100)))
                        .shadow(color: tint.opacity(0.22), radius: 2, y: 1)
                }
            }
        }
        .frame(height: height)
        // The pace marker sits on top of the track without changing its height: a tick across the bar and a
        // small triangle in the 6 pt reserved above it. Without a marker the bar is exactly `height` tall.
        .overlay {
            if let marker {
                GeometryReader { geo in
                    let x = geo.size.width * min(1, max(0, marker / 100))
                    Capsule()
                        .fill(.primary.opacity(0.75))
                        .frame(width: 1.5, height: height + 2)
                        .position(x: x, y: height / 2)
                    PaceTriangle()
                        .fill(.primary.opacity(0.85))
                        .frame(width: 7, height: 5)
                        .position(x: min(max(x, 3.5), max(3.5, geo.size.width - 3.5)), y: -3.5)
                }
            }
        }
        .padding(.top, marker == nil ? 0 : 6)
        .accessibilityHidden(true)
    }

    private struct PaceTriangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
            return path
        }
    }
}
