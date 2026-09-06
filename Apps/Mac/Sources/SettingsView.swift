import SwiftUI
import QuotaCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var showKeychainPicker = false

    private var syncDescription: String {
        guard model.syncEnabled else { return "Usage and cost summaries stay on this Mac." }
        switch model.syncStatus {
        case .noAccount: return "Sign in to iCloud in System Settings to sync."
        case .restricted: return "iCloud is restricted on this Mac."
        case .unavailable(let why): return why
        case .unknown, .available:
            if let error = model.lastSyncError { return "Last push failed: \(error)" }
            if let date = model.lastSyncPush { return "Last pushed \(date.formatted(.relative(presentation: .named))). Only derived numbers are synced, never credentials." }
            return "Publishes this Mac's numbers to your iCloud private database for the iOS app. No credentials leave this Mac."
        }
    }

    var body: some View {
        Form {
            Section("Track") {
                ForEach(ProviderID.allCases) { id in
                    Toggle(id.displayName, isOn: Binding(
                        get: { model.enabledProviders.contains(id) },
                        set: { on in if on { model.enabledProviders.insert(id) } else { model.enabledProviders.remove(id) } }))
                }
            }
            Section {
                ForEach(model.extraClaudeServices, id: \.self) { service in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.states["claude:" + AppModel.suffix(service)]?.snapshot?.organization ?? "Organization (\(AppModel.suffix(service)))")
                            Text(service).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.extraClaudeServices.removeAll { $0 == service } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add organization…") { showKeychainPicker = true }
                    .popover(isPresented: $showKeychainPicker) { ClaudeKeychainPicker(model: model, isPresented: $showKeychainPicker) }
            } header: {
                Text("Claude organizations")
            } footer: {
                Text("Claude Code holds one login per profile. For another organization run `CLAUDE_CONFIG_DIR=~/.claude-<name> claude login`, pick the organization, then add the new Keychain item here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Picker("Show", selection: $model.menuBarSource) {
                    ForEach(model.menuBarSourceOptions, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
                Toggle("Show percentage", isOn: $model.showPercentInMenuBar)
                Toggle("Colour icon", isOn: $model.useAppIconInMenuBar)
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
            Section("iCloud") {
                Toggle("Sync to iCloud", isOn: $model.syncEnabled)
                Text(syncDescription).font(.caption).foregroundStyle(.secondary)
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

/// Lists Claude Code's Keychain items (attributes only, no prompt) so the user can pick another organization's login.
struct ClaudeKeychainPicker: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    private var entries: [ClaudeCredentials.KeychainEntry] {
        ClaudeCredentials.keychainEntries().filter { $0.service != ClaudeCredentials.keychainService && !model.extraClaudeServices.contains($0.service) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code logins in your Keychain").font(.headline)
            Text("Pick the item created by your `claude login` for the other organization. Reading it asks for Keychain access once; choose Always Allow.")
                .font(.caption).foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("No extra Claude Code logins found.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entries) { entry in
                            Button {
                                model.extraClaudeServices.append(entry.service)
                                isPresented = false
                            } label: {
                                HStack {
                                    Text(entry.suffix).font(.body.monospaced())
                                    Spacer()
                                    Text(entry.modified.map { "modified " + $0.formatted(.relative(presentation: .named)) } ?? "")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}
