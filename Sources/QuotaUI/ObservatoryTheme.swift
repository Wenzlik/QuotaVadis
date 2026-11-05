import SwiftUI
import QuotaCore

/// Observatory theme: an optional space-inspired visual mode that brings a cosmic aesthetic
/// to QuotaVadis. Named after Aether's Observatory visual mode. OFF by default; when ON,
/// transforms the UI chrome with deep blue/violet tones and subtle starfield-like accents.
///
/// The theme composes with existing QV layout preferences:
/// - Claude-style layout with large main bar + smaller cards
/// - Per-provider main bar choice
/// - Red warning text high contrast (no dark plates)
/// - "Most at risk" placement setting
public enum ObservatoryTheme {
    
    /// UserDefaults key for the Observatory mode toggle.
    public static let enabledKey = "observatoryModeEnabled"
    
    /// Whether Observatory mode is enabled. Defaults to false.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    
    // MARK: - Core Colors
    
    /// Deep space background — the base layer of the Observatory look.
    public static var spaceBackground: Color {
        adaptiveColor(
            light: (0.10, 0.11, 0.18),  // Deep blue-grey in light (inverted for panels)
            dark: (0.06, 0.07, 0.12)    // Near-black with blue undertone
        )
    }
    
    /// Nebula accent — secondary background with a subtle purple shift.
    public static var nebulaAccent: Color {
        adaptiveColor(
            light: (0.15, 0.14, 0.22),
            dark: (0.10, 0.09, 0.16)
        )
    }
    
    /// Starlight — text and UI elements, warm white with slight blue tint.
    public static var starlight: Color {
        adaptiveColor(
            light: (0.92, 0.93, 0.96),
            dark: (0.88, 0.90, 0.95)
        )
    }
    
    /// Aurora green — healthy/safe status, echoing northern lights.
    public static var auroraGreen: Color {
        adaptiveColor(
            light: (0.20, 0.72, 0.50),
            dark: (0.30, 0.85, 0.60)
        )
    }
    
    /// Solar flare — warning status, warm orange-gold.
    public static var solarFlare: Color {
        adaptiveColor(
            light: (0.90, 0.60, 0.15),
            dark: (0.98, 0.72, 0.25)
        )
    }
    
    /// Red giant — critical status, maintains high contrast per QV requirements.
    public static var redGiant: Color {
        adaptiveColor(
            light: (0.85, 0.20, 0.18),
            dark: (0.98, 0.38, 0.35)
        )
    }
    
    /// Card surface — translucent panels with cosmic tint. Made more visible with higher saturation.
    public static var cardSurface: Color {
        adaptiveColor(
            light: (0.22, 0.22, 0.32),
            dark: (0.14, 0.15, 0.24)
        )
    }
    
    /// Panel/popover background — the deep space backdrop.
    public static var panelBackground: Color {
        adaptiveColor(
            light: (0.12, 0.13, 0.20),
            dark: (0.08, 0.09, 0.15)
        )
    }
    
    /// Header/footer background — slightly lighter than panel for visual hierarchy.
    public static var chromeBackground: Color {
        adaptiveColor(
            light: (0.15, 0.16, 0.24),
            dark: (0.10, 0.11, 0.18)
        )
    }
    
    /// Secondary text color for Observatory mode.
    public static var secondaryText: Color {
        adaptiveColor(
            light: (0.70, 0.72, 0.78),
            dark: (0.58, 0.60, 0.68)
        )
    }
    
    /// Subtle starfield shimmer for interactive elements.
    public static var shimmer: Color {
        adaptiveColor(
            light: (0.50, 0.52, 0.65),
            dark: (0.40, 0.42, 0.55)
        )
    }
    
    // MARK: - Gradients
    
    /// Deep space gradient for backgrounds.
    public static var spaceGradient: LinearGradient {
        LinearGradient(
            colors: [
                adaptiveColor(light: (0.08, 0.09, 0.14), dark: (0.04, 0.05, 0.09)),
                adaptiveColor(light: (0.12, 0.11, 0.18), dark: (0.08, 0.07, 0.13)),
                adaptiveColor(light: (0.10, 0.12, 0.20), dark: (0.06, 0.08, 0.14))
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    /// Subtle aurora gradient for status highlights.
    public static var auroraGradient: LinearGradient {
        LinearGradient(
            colors: [
                auroraGreen.opacity(0.6),
                adaptiveColor(light: (0.15, 0.50, 0.70), dark: (0.25, 0.60, 0.80)).opacity(0.4)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Observatory Card Modifier

/// A card styled for Observatory mode: deep space background with subtle cosmic accents.
/// Falls back to the standard AccentCard when Observatory is disabled.
public struct ObservatoryCard: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat
    let isObservatory: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    
    public init(accent: Color, cornerRadius: CGFloat = 14, isObservatory: Bool) {
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.isObservatory = isObservatory
    }
    
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        
        if isObservatory {
            content
                .background {
                    ZStack {
                        ObservatoryTheme.cardSurface
                        accent.opacity(0.15)
                        LinearGradient(
                            colors: [accent.opacity(0.12), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [accent.opacity(0.5), ObservatoryTheme.shimmer.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                )
                .shadow(color: accent.opacity(0.2), radius: 8, y: 2)
        } else {
            content.modifier(AccentCard(accent: accent, cornerRadius: cornerRadius))
        }
    }
}

public extension View {
    /// Applies Observatory or standard card styling based on the theme state.
    func observatoryCard(_ accent: Color, cornerRadius: CGFloat = 14, isObservatory: Bool) -> some View {
        modifier(ObservatoryCard(accent: accent, cornerRadius: cornerRadius, isObservatory: isObservatory))
    }
}

// MARK: - Observatory Glass Modifier

/// Glass effect styled for Observatory mode: deeper, more cosmic feel.
public struct ObservatoryGlass: ViewModifier {
    let cornerRadius: CGFloat
    let isObservatory: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        
        if isObservatory {
            if reduceTransparency {
                content
                    .background(ObservatoryTheme.spaceBackground, in: shape)
                    .overlay(shape.strokeBorder(ObservatoryTheme.shimmer.opacity(0.2)))
            } else if #available(macOS 26.0, iOS 26.0, *) {
                content
                    .background(ObservatoryTheme.spaceBackground.opacity(0.7), in: shape)
                    .glassEffect(.regular, in: shape)
                    .overlay(shape.strokeBorder(ObservatoryTheme.shimmer.opacity(0.12)))
            } else {
                content
                    .background(ObservatoryTheme.spaceBackground.opacity(0.85), in: shape)
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.strokeBorder(ObservatoryTheme.shimmer.opacity(0.15)))
            }
        } else {
            content.modifier(GlassCard(cornerRadius: cornerRadius))
        }
    }
}

public extension View {
    func observatoryGlass(cornerRadius: CGFloat = 14, isObservatory: Bool) -> some View {
        modifier(ObservatoryGlass(cornerRadius: cornerRadius, isObservatory: isObservatory))
    }
}

// MARK: - Observatory Panel Background

/// Applies the Observatory deep-space background to a panel/popover when enabled.
public struct ObservatoryPanelBackground: ViewModifier {
    let isObservatory: Bool
    
    public func body(content: Content) -> some View {
        if isObservatory {
            content
                .background {
                    ZStack {
                        ObservatoryTheme.panelBackground
                        LinearGradient(
                            colors: [
                                ObservatoryTheme.shimmer.opacity(0.05),
                                Color.clear,
                                ObservatoryTheme.shimmer.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    .ignoresSafeArea()
                }
        } else {
            content
        }
    }
}

/// Styles header/footer chrome for Observatory mode.
public struct ObservatoryChromeBackground: ViewModifier {
    let isObservatory: Bool
    
    public func body(content: Content) -> some View {
        if isObservatory {
            content
                .background(ObservatoryTheme.chromeBackground)
        } else {
            content
        }
    }
}

public extension View {
    /// Applies Observatory panel background when enabled.
    func observatoryPanelBackground(isObservatory: Bool) -> some View {
        modifier(ObservatoryPanelBackground(isObservatory: isObservatory))
    }
    
    /// Applies Observatory chrome background to headers/footers when enabled.
    func observatoryChromeBackground(isObservatory: Bool) -> some View {
        modifier(ObservatoryChromeBackground(isObservatory: isObservatory))
    }
}

// MARK: - Observatory Usage Colors

/// Usage tint colors for Observatory mode — maintains high contrast for warnings.
public func observatoryUsageTint(_ percent: Double, isObservatory: Bool) -> Color {
    guard isObservatory else { return usageTint(percent) }
    
    switch UsageLevel(percent) {
    case .ok: return ObservatoryTheme.auroraGreen
    case .warning: return ObservatoryTheme.solarFlare
    case .critical: return ObservatoryTheme.redGiant
    }
}

// MARK: - Observatory Bar Style

/// Progress bar styled for Observatory mode with cosmic glow effects.
public struct ObservatoryBar: View {
    let percent: Double
    let height: CGFloat
    let marker: Double?
    let tintPercent: Double?
    let isObservatory: Bool
    
    public init(percent: Double, height: CGFloat = 7, marker: Double? = nil, tintPercent: Double? = nil, isObservatory: Bool = false) {
        self.percent = percent
        self.height = height
        self.marker = marker
        self.tintPercent = tintPercent
        self.isObservatory = isObservatory
    }
    
    public var body: some View {
        if isObservatory {
            observatoryBarBody
        } else {
            GlowBar(percent: percent, height: height, marker: marker, tintPercent: tintPercent)
        }
    }
    
    private var observatoryBarBody: some View {
        let tint = observatoryUsageTint(tintPercent ?? percent, isObservatory: true)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(ObservatoryTheme.shimmer.opacity(0.15))
                if percent > 0 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.7), tint, tint.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(height, geo.size.width * min(1, percent / 100)))
                        .shadow(color: tint.opacity(0.4), radius: 4, y: 0)
                        .shadow(color: tint.opacity(0.2), radius: 8, y: 2)
                }
            }
        }
        .frame(height: height)
        .overlay {
            if let marker {
                GeometryReader { geo in
                    let x = geo.size.width * min(1, max(0, marker / 100))
                    Capsule()
                        .fill(ObservatoryTheme.starlight.opacity(0.9))
                        .frame(width: 1.5, height: height + 2)
                        .position(x: x, y: height / 2)
                }
            }
        }
        .padding(.top, marker == nil ? 0 : 6)
        .accessibilityHidden(true)
    }
}
