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

        Window("About QuotaVadis", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Menu bar item: a flame glyph (monochrome, or the colour app icon) plus the chosen percentage.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        // MenuBarExtra labels support Text + Image only; keep it to that.
        HStack(spacing: 3) {
            if model.useAppIconInMenuBar {
                Image("MenuBarIcon")
            } else {
                Image(systemName: "flame.fill")
            }
            if model.showPercentInMenuBar, let percent = model.menuBarPercent {
                Text("\(Int(percent.rounded()))%")
                    .monospacedDigit()
            }
        }
    }

}
