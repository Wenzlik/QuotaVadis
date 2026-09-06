import SwiftUI
import QuotaCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var updater: Updater
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
        // Standard macOS settings tabs; each pane scrolls on its own so the window fits small displays.
        TabView {
            pane {
                Section("Track") {
                    ForEach(ProviderID.allCases) { id in
                        ProviderToggleRow(model: model, provider: id)
                    }
                }
                .onAppear { model.refreshCredentialStatuses() }
                Section {
                    Picker("Refresh every", selection: $model.refreshIntervalMinutes) {
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                    }
                    Toggle("Launch at login", isOn: $model.launchAtLogin)
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            pane {
                Section("Menu bar") {
                    Picker("Show", selection: $model.menuBarSource) {
                        ForEach(model.menuBarSourceOptions, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                    Toggle("Show percentage", isOn: $model.showPercentInMenuBar)
                    Toggle("Colour icon", isOn: $model.useAppIconInMenuBar)
                }
            }
            .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }

            pane {
                Section("Notifications") {
                    Picker("Notify at", selection: $model.warnAtPercent) {
                        Text("Never").tag(101)
                        Text("70%").tag(70)
                        Text("80%").tag(80)
                        Text("90%").tag(90)
                    }
                    Toggle("Notify when a window resets", isOn: $model.notifyOnReset)
                        .disabled(model.warnAtPercent > 100)
                    Text("One alert per window when it crosses the threshold, with a “Snooze 1 hour” action. Reset alerts fire when a nearly used-up window is available again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Notifications", systemImage: "bell") }

            pane {
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
            }
            .tabItem { Label("Claude", systemImage: "person.2") }

            pane {
                Section("iCloud") {
                    Toggle("Sync to iCloud", isOn: $model.syncEnabled)
                    HStack {
                        Button("Sync now") { Task { await model.publishToCloud() } }
                            .disabled(!model.syncEnabled || model.isSyncing)
                        if model.isSyncing { ProgressView().controlSize(.small) }
                        Spacer()
                        if let attempt = model.lastSyncAttempt {
                            Text("Last attempt \(attempt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Text(syncDescription).font(.caption).foregroundStyle(model.lastSyncError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
                    HStack {
                        Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
                        Spacer()
                        if let date = updater.lastCheck {
                            Text("Last checked \(date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .tabItem { Label("iCloud & Updates", systemImage: "icloud") }

            pane {
                Section("Cost estimates") {
                    Toggle("Price Codex Fast mode at 2x", isOn: $model.fastModeAt2x)
                    Text("Costs are estimates at API list prices from local logs (Cursor: from its dashboard). Subscriptions are not billed per token.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Cost", systemImage: "dollarsign.circle") }
        }
        .frame(width: 480, height: 400)
    }

    /// A grouped, scrolling settings pane.
    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.automatic)
    }
}

struct ProviderToggleRow: View {
    @Bindable var model: AppModel
    let provider: ProviderID

    private var isOn: Binding<Bool> {
        Binding(get: { model.enabledProviders.contains(provider) },
                set: { on in if on { model.enabledProviders.insert(provider) } else { model.enabledProviders.remove(provider) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(provider.displayName, isOn: isOn)
            if let status = model.credentialStatuses[provider] {
                Text(status.summary).font(.caption)
                    .foregroundStyle(status.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .lineLimit(2).truncationMode(.middle)
            }
        }
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
