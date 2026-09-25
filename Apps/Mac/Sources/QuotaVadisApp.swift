import SwiftUI
import QuotaCore

@main
struct QuotaVadisApp: App {
    @State private var model = AppModel()
    @State private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to QuotaVadis", id: "welcome") {
            WelcomeView(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        // Keyed by instance id: one window per provider account, reopened in place rather than duplicated.
        WindowGroup("Usage details", id: "dashboard", for: String.self) { $instanceID in
            if let instanceID {
                ProviderDashboardView(model: model, instanceID: instanceID)
            }
        }
        .defaultSize(width: 640, height: 720)

        Settings {
            SettingsView(model: model, updater: updater)
        }
        .windowResizability(.contentMinSize)

        Window("About QuotaVadis", id: "about") {
            AboutView(updater: updater)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Menu bar item: either a flame glyph (monochrome, or the colour app icon) plus the chosen percentage,
/// or 1–4 CodexBar/Headroom-style filled bars.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Per launch: the label is the one view that exists from startup, so it presents the welcome window once.
    @State private var presentedWelcome = false

    private var isBars: Bool { model.menuBarDisplayStyle == .bars }
    private var isStale: Bool { isBars ? model.menuBarBarIsStale : model.menuBarIsStale }
    private var accessibilityText: String { isBars ? model.menuBarBarAccessibilityLabel : model.menuBarAccessibilityLabel }

    var body: some View {
        // MenuBarExtra labels reliably render only one Image plus one Text; a second sibling Image (e.g. a
        // 2nd bar) silently doesn't show up. So the bars, all their percent numbers and the stale dot are
        // baked into one composed image (MenuBarBarImage) instead of separate SwiftUI views per bar.
        HStack(spacing: 3) {
            if isBars {
                Image(nsImage: MenuBarBarImage.render(
                    percents: model.menuBarBarPercents,
                    icons: model.menuBarShowVendorIcons ? model.menuBarBarVendorIcons : [],
                    shortWindow: model.menuBarShowVendorIcons ? model.menuBarBarIconIsShortWindow : [],
                    placement: model.showPercentInMenuBar ? model.menuBarPercentPlacement : nil,
                    isStale: isStale))
            } else {
                Image(model.useAppIconInMenuBar ? "MenuBarColor" : "MenuBarMono")
                if isStale { Image(systemName: "exclamationmark.circle") }
                if model.showPercentInMenuBar, let percent = model.menuBarPercent {
                    Text("\(Int(percent.rounded()))%")
                        .monospacedDigit()
                }
            }
        }
        .accessibilityLabel(accessibilityText)
        .help(accessibilityText)
        .task {
            guard !model.hasOnboarded, !presentedWelcome else { return }
            presentedWelcome = true
            bringToFront { openWindow(id: "welcome") }
        }
    }

}
