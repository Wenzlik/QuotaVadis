import SwiftUI
import QuotaCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var updater: Updater
    @State private var showKeychainPicker = false
    @State private var showSignIn = false

    private var refreshDescription: String {
        var text = model.isAdaptiveRefresh
            ? "Adaptive: every 2 min right after you open the panel, 5 min while you work with the tools or looked within the hour, 15–30 min when idle, 30 min on Low Power. Opening the panel always refreshes."
            : "Fixed interval. Claude Code is still read at most every 5 minutes: Anthropic's usage API throttles faster polling."
        if let reason = model.adaptiveReason, let next = model.nextRefreshAt {
            text += " Now: \(reason.rawValue), next check \(next.formatted(.relative(presentation: .named)))."
        }
        text += " After an HTTP 429 the app backs off and keeps the last values."
        return text
    }

    private var syncDescription: String {
        if let error = model.lastSyncError { return error }
        guard model.syncEnabled else {
            return model.isSyncing ? "Removing this Mac's published data…" : "Sync is off. Local widget data stays on this Mac."
        }
        switch model.syncStatus {
        case .noAccount: return "Sign in to iCloud in System Settings to sync."
        case .restricted: return "iCloud is restricted on this Mac."
        case .unavailable(let why): return why
        case .unknown, .available:
            if let error = model.lastSyncError { return "Last push failed: \(error)" }
            if let date = model.lastSyncPush { return "Last pushed \(date.formatted(.relative(presentation: .named))). " }
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
                    Picker("Refresh", selection: $model.refreshIntervalSeconds) {
                        Text("Adaptive (2–30 min)").tag(0)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("30 minutes").tag(1800)
                    }
                    Toggle("Launch at login", isOn: $model.launchAtLogin)
                    Text(refreshDescription).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Button(model.cliInstalled ? "Reinstall command line tool" : "Install command line tool") { model.installCLI() }
                        Spacer()
                        Text(model.cliInstalled ? "installed at /usr/local/bin/quotavadis" : "").font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = model.cliInstallMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Text("`quotavadis` prints the same limits in Terminal: a table, `--json`, `--watch 60`, `--provider codex`, `cost`. Uses the same logins as the app.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Command line") }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            pane {
                Section("Menu bar") {
                    Picker("Style", selection: $model.menuBarDisplayStyle) {
                        Text("Icon").tag(MenuBarDisplayStyle.icon)
                        Text("Filled bars").tag(MenuBarDisplayStyle.bars)
                    }
                    .pickerStyle(.segmented)
                    if model.menuBarDisplayStyle == .icon {
                        Picker("Show", selection: $model.menuBarSource) {
                            ForEach(model.menuBarSourceOptions, id: \.0) { option in
                                Text(option.1).tag(option.0)
                            }
                        }
                        Toggle("Show percentage", isOn: $model.showPercentInMenuBar)
                        Toggle("Colour icon", isOn: $model.useAppIconInMenuBar)
                    } else {
                        Toggle("Show percentage", isOn: $model.showPercentInMenuBar)
                        Toggle("Show vendor mark", isOn: $model.menuBarShowVendorIcons)
                        if model.showPercentInMenuBar {
                            Picker("Percentage", selection: $model.menuBarPercentPlacement) {
                                Text("Beside each bar").tag(MenuBarPercentPlacement.beside)
                                Text("Inside each bar").tag(MenuBarPercentPlacement.inside)
                            }
                        }
                        ForEach(Array(model.menuBarBarSources.enumerated()), id: \.offset) { index, source in
                            HStack {
                                Picker("Bar \(index + 1)", selection: Binding(
                                    get: { source },
                                    set: { model.setBarSource($0, at: index) })) {
                                    ForEach(model.menuBarSourceOptions, id: \.0) { option in
                                        Text(option.1).tag(option.0)
                                    }
                                }
                                if model.menuBarBarSources.count > 1 {
                                    Button(role: .destructive) { model.removeBar(at: index) } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                        if model.menuBarBarSources.count < AppModel.maxBars {
                            Button("Add bar") { model.addBar() }
                        }
                        Text("Each bar fills bottom-up with its usage (or spend, against a cap) percent. Up to \(AppModel.maxBars) bars.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.menuBarDisplayStyle == .icon, model.menuBarSource == .worst {
                    Section {
                        ForEach(model.menuBarCandidates, id: \.key) { candidate in
                            Toggle(candidate.label, isOn: Binding(
                                get: { !model.menuBarExcluded.contains(candidate.key) },
                                set: { on in if on { model.menuBarExcluded.remove(candidate.key) } else { model.menuBarExcluded.insert(candidate.key) } }))
                        }
                    } header: {
                        Text("Counted in “Highest usage”")
                    } footer: {
                        Text("Untick a window to leave it out of the menu bar number. New windows count by default.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                Section("Extra usage") {
                    Toggle("Alert when paid extra usage grows", isOn: $model.notifyExtraUsage)
                    Text("Two cases: extra usage grows while your limits are not exhausted (a model outside your seat, e.g. Fable on a Standard seat, is billed separately), and extra usage starts after a window hit 100%. At most once per hour per account.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Send test notifications") { model.sendTestNotifications() }
                    Text("Delivers one sample of each kind so you can see the wording, the sound and the Snooze action. If nothing appears, allow QuotaVadis in System Settings ▸ Notifications.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Notifications", systemImage: "bell") }

            pane {
                Section {
                    Picker("Read limits from", selection: $model.claudeSource) {
                        Text("Automatic").tag(UsageService.ClaudeSource.automatic)
                        Text("Claude Code login").tag(UsageService.ClaudeSource.claudeCode)
                        Text("claude.ai web session").tag(UsageService.ClaudeSource.web)
                    }
                    LabeledContent("QuotaVadis sign-in", value: model.claudeOwnLoginActive ? "signed in — no Keychain prompts" : "not signed in")
                    if model.claudeOwnLoginActive {
                        Button("Sign out") { model.signOutClaudeOwnLogin() }
                    } else {
                        Button("Sign in to Claude…") { showSignIn = true }
                            .popover(isPresented: $showSignIn) { ClaudeSignInView(model: model, isPresented: $showSignIn) }
                    }
                    LabeledContent("Claude Code", value: model.claudeCodeAvailable ? "logged in on this Mac" : "not found")
                    LabeledContent("claude.ai session", value: model.claudeWebAvailable ? "found (Claude app, Chrome or pasted key)" : "not found")
                    SecureField("Paste a claude.ai sessionKey (optional)", text: $model.manualClaudeSessionKey)
                } header: {
                    Text("Claude source")
                } footer: {
                    Text("Signing in gives QuotaVadis a login of its own. It is the only source macOS never asks about: every other one borrows an item another app owns — Claude Code replaces its Keychain item whenever it refreshes its token, which throws away the permission you granted, so the dialog keeps coming back. Without a sign-in, automatic uses your Claude Code login and adds organizations from your claude.ai session; the session of the Claude desktop app or Chrome works too. Safari is not read yet; paste the sessionKey cookie from claude.ai instead.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Text("Only needed if you belong to more than one Claude organization and use Claude Code: each organization needs its own Claude Code login, and “Add organization…” walks you through it. With a claude.ai web session, organizations are picked up automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Claude", systemImage: "person.2") }

            pane {
                Section("iCloud") {
                    Toggle("Sync to iCloud", isOn: $model.syncEnabled)
                    HStack {
                        Button(model.syncEnabled ? "Sync now" : "Retry removal") { Task { await model.publishToCloud() } }
                            .disabled(model.isSyncing)
                        if model.isSyncing { ProgressView().controlSize(.small) }
                        Spacer()
                        if let attempt = model.lastSyncAttempt {
                            Text("Last attempt \(attempt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Text(SyncPrivacy.summary).font(.caption).foregroundStyle(.secondary)
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

/// QuotaVadis's own Claude sign-in: open the authorization page, paste back the code it shows.
/// Anthropic has no redirect registered for this app, so the code is copied by hand — the same callback page
/// the Claude Code CLI uses for its own login.
struct ClaudeSignInView: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var paste = ""
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Claude").font(.headline)
            Text("QuotaVadis gets its own login, kept in its own Keychain item. macOS stops asking for permission, because nothing here reads an item another app owns.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            step(1, "Open the Claude authorization page and approve the request.")
            Button("Sign in to Claude…") { model.beginClaudeSignIn() }

            step(2, "Claude shows a code when you approve. Paste it here.")
            TextField("code#state", text: $paste).textFieldStyle(.roundedBorder)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Done") {
                    working = true
                    Task {
                        problem = await model.completeClaudeSignIn(paste: paste)
                        working = false
                        if problem == nil { isPresented = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").font(.caption.bold()).foregroundStyle(.secondary)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
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
