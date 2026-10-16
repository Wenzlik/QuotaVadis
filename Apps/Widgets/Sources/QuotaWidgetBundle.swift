import SwiftUI
import WidgetKit
import QuotaCore

@main
struct QuotaWidgetBundle: WidgetBundle {
    #if os(macOS)
    /// Lets the app see which build this process runs: after a Sparkle update an old one can linger and draw nothing.
    init() { SharedStore.recordWidgetExtensionLaunch() }
    #endif

    var body: some Widget {
        SwitcherWidget()
        OverviewWidget()
        ClaudeWidget()
        CodexWidget()
        CursorWidget()
        AntigravityWidget()
        ProviderWidget()
    }
}
