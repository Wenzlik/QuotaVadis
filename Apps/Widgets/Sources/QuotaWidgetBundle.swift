import SwiftUI
import WidgetKit

@main
struct QuotaWidgetBundle: WidgetBundle {
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
