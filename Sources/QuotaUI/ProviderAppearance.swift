import SwiftUI
import QuotaCore

/// Identity colour per provider: header accents, chart series, fallback tile fill. Deliberately separate from
/// `usageTint`, which keeps meaning "how much is used" — an accent never stands in for a warning.
/// These are QuotaVadis's own design choices, not the vendors' brand colours (the brand marks themselves
/// carry their own colour when a bundled vendor image is available).
public extension ProviderID {
    var accent: Color {
        switch self {
        case .claude: adaptiveColor(light: (0.80, 0.39, 0.18), dark: (0.93, 0.52, 0.30))   // warm orange
        case .codex: adaptiveColor(light: (0.05, 0.53, 0.52), dark: (0.25, 0.78, 0.74))    // teal
        case .cursor: adaptiveColor(light: (0.44, 0.30, 0.82), dark: (0.66, 0.55, 0.98))   // violet
        case .gemini: adaptiveColor(light: (0.16, 0.42, 0.86), dark: (0.42, 0.63, 0.99))   // blue
        }
    }

    /// SF Symbol fallback when no bundled vendor mark exists (currently Gemini).
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .gemini: "diamond.fill"
        }
    }

    /// Asset-catalog name for the provider's real app/brand mark (original rendering).
    /// Claude/Cursor/Codex ship colour marks extracted from the installed Mac apps Václav uses;
    /// Gemini stays on the geometric SF Symbol until a local app icon is available.
    var vendorImageName: String? {
        switch self {
        case .claude: "VendorClaude"
        case .cursor: "VendorCursor"
        case .codex: "VendorCodex"
        case .gemini: nil
        }
    }
}

/// Provider identity mark: real brand app icon when bundled, otherwise a rounded accent tile with an SF Symbol.
public struct ProviderMark: View {
    let provider: ProviderID
    let size: CGFloat
    public init(provider: ProviderID, size: CGFloat = 24) { self.provider = provider; self.size = size }

    public var body: some View {
        if let name = provider.vendorImageName {
            Image(name)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            Image(systemName: provider.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(LinearGradient(colors: [provider.accent.opacity(0.85), provider.accent], startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18)))
                .accessibilityHidden(true)
        }
    }
}

/// A card tinted very lightly with the provider's accent, over the platform's glass/material.
public struct AccentCard: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(accent.opacity(reduceTransparency ? 0.10 : 0.06), in: shape)
            .modifier(GlassCard(cornerRadius: cornerRadius))
            .overlay(shape.strokeBorder(accent.opacity(0.22), lineWidth: 1))
    }
}

public extension View {
    func accentCard(_ accent: Color, cornerRadius: CGFloat = 14) -> some View { modifier(AccentCard(accent: accent, cornerRadius: cornerRadius)) }
}
