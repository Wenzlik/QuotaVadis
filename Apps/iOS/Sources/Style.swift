import SwiftUI
import QuotaCore
import QuotaUI

extension ProviderID {
    /// iOS-only accent alias used by older card chrome; prefer `accent` from QuotaUI for new UI.
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.24)
        case .codex: Color(red: 0.16, green: 0.65, blue: 0.55)
        case .cursor: Color(red: 0.45, green: 0.42, blue: 0.95)
        case .gemini: Color(red: 0.26, green: 0.55, blue: 0.96)
        }
    }
}

func levelColor(_ percent: Double) -> Color { usageTint(percent) }

extension UsageSnapshot {
    var displayTitle: String {
        instanceID == provider.rawValue ? provider.displayName : "\(provider.displayName) · \(organization ?? instanceID)"
    }
}
