import SwiftUI
import QuotaCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Track") {
                ForEach(ProviderID.allCases) { id in
                    Toggle(id.displayName, isOn: Binding(
                        get: { model.enabledProviders.contains(id) },
                        set: { on in if on { model.enabledProviders.insert(id) } else { model.enabledProviders.remove(id) } }))
                }
            }
            Section("Menu bar") {
                Picker("Show", selection: $model.menuBarSource) {
                    ForEach(model.menuBarSourceOptions, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
                Toggle("Show percentage", isOn: $model.showPercentInMenuBar)
            }
            Section {
                Picker("Refresh every", selection: $model.refreshIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
                Picker("Notify at", selection: $model.warnAtPercent) {
                    Text("Never").tag(101)
                    Text("70%").tag(70)
                    Text("80%").tag(80)
                    Text("90%").tag(90)
                }
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            }
            Section("Cost estimates") {
                Toggle("Price Codex Fast mode at 2x", isOn: $model.fastModeAt2x)
                Text("Costs are estimates at API list prices from local logs (Cursor: from its dashboard). Subscriptions are not billed per token.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}
