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
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(id.displayName, isOn: Binding(
                            get: { model.enabledProviders.contains(id) },
                            set: { on in if on { model.enabledProviders.insert(id) } else { model.enabledProviders.remove(id) } }))
                        if let status = model.credentialStatuses[id] {
                            Text(status.summary).font(.caption).foregroundStyle(status.problem == nil ? .secondary : .orange)
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }
                }
            }
            .onAppear { model.refreshCredentialStatuses() }
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
                Text("Each organization needs its own Claude Code login. “Add organization…” walks you through it.")
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

/// Guides the user through adding another organization's Claude Code login and picks its Keychain item.
struct ClaudeKeychainPicker: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var profileName = "work"
    @State private var copied = false
    @State private var refreshTick = 0

    private var command: String { "CLAUDE_CONFIG_DIR=~/.claude-\(profileName.isEmpty ? "work" : profileName) claude login" }

    private var entries: [ClaudeCredentials.KeychainEntry] {
        _ = refreshTick
        return ClaudeCredentials.keychainEntries().filter { $0.service != ClaudeCredentials.keychainService && !model.extraClaudeServices.contains($0.service) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add another Claude organization").font(.headline)

            step(1, "Claude Code keeps one login per profile. Create a profile for the other organization and log in:")
            HStack(spacing: 6) {
                Text("Profile name").font(.caption).foregroundStyle(.secondary)
                TextField("work", text: $profileName).textFieldStyle(.roundedBorder).frame(width: 120)
            }
            HStack {
                Text(command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("Run it in Terminal and pick the organization when asked. It does not touch your normal `claude` login.")
                .font(.caption).foregroundStyle(.secondary)

            step(2, "Pick the login it created. The newest item is the one you just made; the others are older profiles.")
            HStack {
                Spacer()
                Button { refreshTick += 1 } label: { Label("Refresh list", systemImage: "arrow.clockwise") }.controlSize(.small)
            }
            if entries.isEmpty {
                Text("No extra Claude Code logins in the Keychain yet.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            Button {
                                model.extraClaudeServices.append(entry.service)
                                isPresented = false
                            } label: {
                                HStack {
                                    Text(entry.suffix).font(.body.monospaced())
                                    Spacer()
                                    Text(entry.modified.map { $0.formatted(.relative(presentation: .named)) } ?? "")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4).padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(entry == entries.first ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            step(3, "macOS asks once for Keychain access to that item. Choose Always Allow, otherwise it asks on every refresh.")
        }
        .padding(16)
        .frame(width: 420)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
