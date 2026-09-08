import SwiftUI
import QuotaCore
import QuotaUI

extension ProviderID {
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.24)
        case .codex: Color(red: 0.16, green: 0.65, blue: 0.55)
        case .cursor: Color(red: 0.45, green: 0.42, blue: 0.95)
        case .gemini: Color(red: 0.26, green: 0.55, blue: 0.96)
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .gemini: "circle.hexagongrid"
        }
    }

    /// A real, colourless vendor mark (CC0-licensed, see Apps/iOS/Resources/Assets.xcassets), where one
    /// exists; nil falls back to `symbol`. Codex/OpenAI has none — see the Mac vendor-icon comment for why.
    var vendorImageName: String? {
        switch self {
        case .claude: "VendorClaude"
        case .cursor: "VendorCursor"
        case .gemini: "VendorGemini"
        case .codex: nil
        }
    }
}

func levelColor(_ percent: Double) -> Color { usageTint(percent) }

extension UsageSnapshot {
    var displayTitle: String {
        instanceID == provider.rawValue ? provider.displayName : "\(provider.displayName) · \(organization ?? instanceID)"
    }
}
