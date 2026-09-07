import SwiftUI
import QuotaCore

@main
struct QuotaVadisApp: App {
    @State private var model = AppModel()
    @State private var updater = Updater()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
                .onAppear {
                    if !model.hasOnboarded {
                        openWindow(id: "welcome")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome", id: "welcome") {
            WelcomeView(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView(model: model, updater: updater)
        }

        Window("About QuotaVadis", id: "about") {
            AboutView(updater: updater)
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
            Image(model.useAppIconInMenuBar ? "MenuBarColor" : "MenuBarMono")
            if model.menuBarIsStale { Image(systemName: "exclamationmark.circle") }
            if model.showPercentInMenuBar, let percent = model.menuBarPercent {
                Text("\(Int(percent.rounded()))%")
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(model.menuBarAccessibilityLabel)
        .help(model.menuBarAccessibilityLabel)
    }

}
