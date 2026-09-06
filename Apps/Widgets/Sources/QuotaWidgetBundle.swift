import SwiftUI
import WidgetKit

@main
struct QuotaWidgetBundle: WidgetBundle {
    var body: some Widget {
        ProviderWidget()
        OverviewWidget()
    }
}
