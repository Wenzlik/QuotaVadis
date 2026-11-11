import SwiftUI
import QuotaCore

extension EnvironmentValues {
    /// The resolved theme (never `.auto`) for everything below. Set once at each window or widget root.
    @Entry public var appTheme: AppTheme = .standard
}

/// GoodLimits.ai: QuotaVadis in GoodData.AI brand colours (brand guidelines 2026,
/// https://www.gooddata.ai/brand-guidelines/). Flat surfaces, thin borders, Lime as the accent fill on dark.
/// Follows the system light/dark appearance, so system `.secondary`/`.tertiary` text stays correct on it.
public enum GoodLimitsTheme {
    public static let name = "GoodLimits.ai"

    // Brand palette (exact hexes from the guidelines). Lime is the main brand colour: fills, accents, borders,
    // and text only on dark — never Lime text on a light background.
    static let black: UInt32 = 0x09090C
    static let white: UInt32 = 0xFFFFFF
    static let lime: UInt32 = 0xDAFE85
    static let gray50: UInt32 = 0xF2F2F2, gray100: UInt32 = 0xE6E6E7, gray150: UInt32 = 0xCECECE
    static let gray400: UInt32 = 0x848486, gray700: UInt32 = 0x3A3A3D, gray800: UInt32 = 0x222224
    static let success200: UInt32 = 0x08D796, success300: UInt32 = 0x157A47
    static let warning200: UInt32 = 0xFC7B12, warning300: UInt32 = 0xB34700
    static let error200: UInt32 = 0xFF424B, error300: UInt32 = 0xDD0A14

    // Roles. Light → dark per the guidelines' light and dark mode tables.
    public static var background: Color { color(light: white, dark: black) }
    /// Background Gray 1: cards.
    public static var card: Color { color(light: gray50, dark: gray800) }
    /// Background Gray 2: raised or selected surfaces.
    public static var surface: Color { color(light: gray100, dark: gray700) }
    public static var border: Color { color(light: gray150, dark: gray400) }
    public static var textPrimary: Color { color(light: black, dark: white) }
    public static var textSecondary: Color { color(light: gray700, dark: gray150) }
    public static var link: Color { color(light: 0x285D92, dark: 0xCDE2F7) }
    /// The spiral and other accents: black on light, Lime on dark.
    public static var accent: Color { color(light: black, dark: lime) }
    public static var limeFill: Color { color(light: lime, dark: lime) }

    // Bars: black (light) / Lime (dark) while fine, status 200 colours once the limit is at risk.
    static var barTrack: Color { color(light: gray100, dark: gray700) }
    static func barFill(_ level: UsageLevel) -> Color {
        switch level {
        case .ok: color(light: black, dark: lime)
        case .warning: color(light: warning200, dark: warning200)
        case .critical: color(light: error200, dark: error200)
        }
    }
    /// Pace tick: a 1.5 pt core inside an outline of the opposite colour, so it shows on the track and on any fill
    /// (white core on the black light-mode fill, black core on the Lime dark-mode fill).
    static var markerCore: Color { color(light: white, dark: black) }
    static var markerOutline: Color { color(light: black, dark: white) }

    /// Risk text, colour only: 300 shades on light, 200 shades on dark.
    static func riskText(_ risk: UsageForecast.Risk) -> Color {
        switch risk {
        case .safe: color(light: success300, dark: success200)
        case .watch: color(light: warning300, dark: warning200)
        case .atRisk, .exhausted: color(light: error300, dark: error200)
        }
    }

    static func color(light: UInt32, dark: UInt32) -> Color { adaptiveColor(light: rgb(light), dark: rgb(dark)) }
    private static func rgb(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}

/// The GoodData spiral, drawn from the official `logo symbol_black.svg` path (viewBox 0 0 355 351). A Shape so it
/// works in the app and in widgets without bundled resources. Scales uniformly and centres in its frame: never
/// stretched or rotated.
public struct GoodDataSymbol: Shape {
    public static let aspectRatio: CGFloat = 355.0 / 351.0
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 355, rect.height / 351)
        let ox = rect.minX + (rect.width - 355 * scale) / 2
        let oy = rect.minY + (rect.height - 351 * scale) / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * scale, y: oy + y * scale) }
        var p = Path()
        p.move(to: pt(327.153, 215.809))
        p.addCurve(to: pt(268.096, 128.196), control1: pt(326.177, 174.168), control2: pt(303.19, 141.116))
        p.addLine(to: pt(268.096, 55.7229))
        p.addCurve(to: pt(239.961, 41.775), control1: pt(259.235, 50.0584), control2: pt(249.804, 45.3753))
        p.addLine(to: pt(239.961, 197.692))
        p.addCurve(to: pt(202.604, 242.372), control1: pt(239.961, 228.579), control2: pt(225.632, 242.372))
        p.addCurve(to: pt(161.434, 197.124), control1: pt(180.186, 242.372), control2: pt(161.434, 225.439))
        p.addCurve(to: pt(218.322, 146.219), control1: pt(161.434, 165.519), control2: pt(186.067, 146.219))
        p.addCurve(to: pt(227.339, 146.787), control1: pt(221.309, 146.164), control2: pt(224.351, 146.32))
        p.addLine(to: pt(227.339, 119.196))
        p.addCurve(to: pt(218.322, 118.478), control1: pt(224.351, 118.681), control2: pt(221.364, 118.424))
        p.addCurve(to: pt(132.939, 197.185), control1: pt(170.451, 118.478), control2: pt(132.939, 147.822))
        p.addCurve(to: pt(204.515, 269.97), control1: pt(132.939, 244.646), control2: pt(166.792, 269.97))
        p.addCurve(to: pt(248.524, 253.443), control1: pt(222.393, 269.97), control2: pt(237.854, 263.893))
        p.addCurve(to: pt(268.212, 201.401), control1: pt(259.188, 242.994), control2: pt(268.212, 227.909))
        p.addLine(to: pt(268.212, 158.211))
        p.addCurve(to: pt(299.491, 218.489), control1: pt(287.689, 167.942), control2: pt(299.437, 191.514))
        p.addCurve(to: pt(196.947, 312.226), control1: pt(299.389, 269.293), control2: pt(252.237, 312.226))
        p.addCurve(to: pt(193.39, 312.172), control1: pt(195.66, 312.226), control2: pt(194.678, 312.226))
        p.addCurve(to: pt(95.1215, 271.404), control1: pt(155.465, 312.125), control2: pt(122.126, 298.427))
        p.addCurve(to: pt(57.0402, 200.264), control1: pt(75.6913, 251.948), control2: pt(62.3991, 227.185))
        p.addCurve(to: pt(64.9735, 119.96), control1: pt(51.6813, 173.289), control2: pt(54.4115, 145.393))
        p.addCurve(to: pt(116.191, 57.5704), control1: pt(75.488, 94.5821), control2: pt(93.3126, 72.8583))
        p.addCurve(to: pt(193.485, 34.148), control1: pt(139.07, 42.2826), control2: pt(165.973, 34.148))
        p.addLine(to: pt(193.485, 5.83936))
        p.addCurve(to: pt(129.382, 18.5556), control1: pt(171.481, 5.83936), control2: pt(149.686, 10.1638))
        p.addCurve(to: pt(75.0206, 54.7957), control1: pt(109.078, 26.9473), control2: pt(90.5823, 39.298))
        p.addCurve(to: pt(25.9098, 173.086), control1: pt(43.5854, 86.143), control2: pt(25.9098, 128.711))
        p.addCurve(to: pt(74.9122, 291.43), control1: pt(25.9098, 217.454), control2: pt(43.5312, 260.028))
        p.addCurve(to: pt(193.329, 340.488), control1: pt(106.293, 322.831), control2: pt(148.907, 340.488))
        p.addLine(to: pt(196.886, 340.488))
        p.addCurve(to: pt(237.237, 334.309), control1: pt(210.544, 340.488), control2: pt(224.148, 338.376))
        p.addCurve(to: pt(237.393, 334.255), control1: pt(237.291, 334.309), control2: pt(237.339, 334.255))
        p.addCurve(to: pt(288.15, 305.019), control1: pt(256.301, 328.387), control2: pt(273.618, 318.398))
        p.addCurve(to: pt(327.159, 218.645), control1: pt(313.244, 281.854), control2: pt(327.058, 251.23))
        p.addCurve(to: pt(327.153, 215.809), control1: pt(327.207, 218.536), control2: pt(327.153, 215.863))
        p.closeSubpath()
        return p
    }
}

/// Spiral + "GoodLimits.ai" in line. `size` is the text size; the spiral matches its cap height and a bit more.
public struct GoodLimitsWordmark: View {
    let size: CGFloat
    public init(size: CGFloat = 13) { self.size = size }

    public var body: some View {
        HStack(spacing: size * 0.4) {
            GoodDataSymbol()
                .fill(GoodLimitsTheme.accent)
                .frame(width: size * 1.25 * GoodDataSymbol.aspectRatio, height: size * 1.25)
            Text(verbatim: GoodLimitsTheme.name)
                .font(.system(size: size, weight: .semibold))
                .tracking(-0.015 * size)
                .foregroundStyle(GoodLimitsTheme.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: GoodLimitsTheme.name))
    }
}

// MARK: - Theme-aware surfaces

public extension AppTheme {
    /// Window/screen backdrop; nil keeps the platform default.
    var backdrop: Color? {
        switch self {
        case .observatory: ObservatoryTheme.panelBackground
        case .goodLimits: GoodLimitsTheme.background
        case .auto, .standard: nil
        }
    }
}

/// Provider card in the current theme: Observatory and the default look exactly as before, GoodLimits.ai flat
/// Gray 1 with a hairline border.
public struct ThemedCard: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat
    @Environment(\.appTheme) private var theme

    public func body(content: Content) -> some View {
        if theme == .goodLimits {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background(GoodLimitsTheme.card, in: shape)
                .overlay(shape.strokeBorder(GoodLimitsTheme.border.opacity(0.6), lineWidth: 0.5))
        } else {
            content.modifier(ObservatoryCard(accent: accent, cornerRadius: cornerRadius, isObservatory: theme == .observatory))
        }
    }
}

struct ThemedPanelBackground: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        if theme == .goodLimits {
            content.background { GoodLimitsTheme.background.ignoresSafeArea() }
        } else {
            content.modifier(ObservatoryPanelBackground(isObservatory: theme == .observatory))
        }
    }
}

struct ThemedChromeBackground: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        if theme == .goodLimits {
            content.background(GoodLimitsTheme.background)
        } else {
            content.modifier(ObservatoryChromeBackground(isObservatory: theme == .observatory))
        }
    }
}

public extension View {
    func themedCard(_ accent: Color, cornerRadius: CGFloat = 14) -> some View {
        modifier(ThemedCard(accent: accent, cornerRadius: cornerRadius))
    }
    func themedPanelBackground() -> some View { modifier(ThemedPanelBackground()) }
    func themedChromeBackground() -> some View { modifier(ThemedChromeBackground()) }
}

/// Flat GoodLimits.ai bar: no gradient or glow, a tick with an outline so the pace marker reads on every fill.
struct GoodLimitsBar: View {
    let percent: Double
    let height: CGFloat
    let marker: Double?
    let tintPercent: Double?

    var body: some View {
        let fill = GoodLimitsTheme.barFill(UsageLevel(tintPercent ?? percent))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(GoodLimitsTheme.barTrack)
                if percent > 0 {
                    Capsule().fill(fill).frame(width: max(height, geo.size.width * min(1, percent / 100)))
                }
            }
        }
        .frame(height: height)
        .overlay {
            if let marker {
                GeometryReader { geo in
                    let x = geo.size.width * min(1, max(0, marker / 100))
                    Capsule()
                        .fill(GoodLimitsTheme.markerOutline)
                        .frame(width: 3.5, height: height + 4)
                        .position(x: x, y: height / 2)
                    Capsule()
                        .fill(GoodLimitsTheme.markerCore)
                        .frame(width: 1.5, height: height + 2)
                        .position(x: x, y: height / 2)
                    GoodLimitsPaceTriangle()
                        .fill(GoodLimitsTheme.markerOutline)
                        .frame(width: 7, height: 5)
                        .position(x: min(max(x, 3.5), max(3.5, geo.size.width - 3.5)), y: -3.5)
                }
            }
        }
        .padding(.top, marker == nil ? 0 : 6)
        .accessibilityHidden(true)
    }
}

private struct GoodLimitsPaceTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
