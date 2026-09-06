import SwiftUI
import QuotaCore

@main
struct QuotaVadisApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Menu bar item: a small gauge glyph plus the worst percentage across enabled providers.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        // MenuBarExtra labels support Text + Image only; keep it to that.
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            if model.showPercentInMenuBar, let percent = model.menuBarPercent {
                Text("\(Int(percent.rounded()))%")
                    .monospacedDigit()
            }
        }
    }

    private var symbolName: String {
        guard let p = model.menuBarPercent else { return "gauge.with.dots.needle.0percent" }
        switch p {
        case ..<25: return "gauge.with.dots.needle.0percent"
        case ..<50: return "gauge.with.dots.needle.33percent"
        case ..<80: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }
}
