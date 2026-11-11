import SwiftUI
import QuotaCore
import QuotaUI

/// The whole UI: a header, one card per provider, a footer. Charts live in the dashboard window.
struct MenuPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    private var theme: AppTheme { model.resolvedTheme }
    private var isObservatory: Bool { theme == .observatory }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(isObservatory ? 0.3 : 1)
            if !model.hasOnboarded {
                setupPrompt
            } else {
                // A bare ScrollView inside a MenuBarExtra window gets no height proposal and collapses to zero.
                // fixedSize makes it report its content height; the frame then caps it so long lists scroll.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.showClaudeConnectTip { connectTip }
                        if needsClaudeConnect { connectCard }
                        if model.visibleInstances.isEmpty && !needsClaudeConnect {
                            ContentUnavailableView("Nothing to track on this Mac", systemImage: "flame",
                                                   description: Text("Log in to a provider on this Mac, then Refresh."))
                        } else {
                            if model.riskSummaryPlacement == .top { riskSummary }
                            Text("This Mac")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isObservatory ? ObservatoryTheme.secondaryText : .secondary)
                            providerRows
                            if model.riskSummaryPlacement == .bottom { riskSummary }
                        }
                    }
                    .padding(10)
                }
                .scrollBounceBehavior(.basedOnSize)
                // With a mouse attached macOS uses legacy scrollers that take width. While a card expands the
                // window resizes a frame late, the scroller pops in, text rewraps, and the panel jitters.
                .scrollIndicators(.never)
                .frame(maxHeight: maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(isObservatory ? 0.3 : 1)
            footer
        }
        .frame(width: 360)
        .themedPanelBackground()
        .environment(\.appTheme, theme)
        .onAppear { model.panelOpened() }
    }

    /// Leave room for the menu bar, header and footer on the smallest common display.
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, screen - 160)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if theme == .goodLimits {
                GoodLimitsWordmark(size: 14)
            } else {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text("QuotaVadis")
                    .font(.headline)
                    .foregroundStyle(isObservatory ? ObservatoryTheme.starlight : .primary)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let date = model.lastRefresh {
                Text("Updated \(date, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(isObservatory ? ObservatoryTheme.secondaryText : .secondary)
            }
            Button { model.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .foregroundStyle(isObservatory ? ObservatoryTheme.starlight : .primary)
                .help("Refresh now (⌘R)")
                .accessibilityLabel("Refresh now")
                .keyboardShortcut("r")
                .disabled(!model.hasOnboarded)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .themedChromeBackground()
    }

    private var setupPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(ProviderID.claude.accent)
            Text("Finish setting up").font(.headline)
            Text("QuotaVadis reads nothing until you choose what to track.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Continue setup") { bringToFront { openWindow(id: "welcome") } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    /// Claude is on, but nothing can read it: no QuotaVadis login, no Claude Code, no claude.ai session.
    private var needsClaudeConnect: Bool {
        model.enabledProviders.contains(.claude) && model.claudeConnection == .notConnected
            && !model.visibleInstances.contains { $0.provider == .claude }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                ProviderMark(provider: .claude, size: 26)
                Text("Claude").font(.headline)
                Spacer()
                StatusBadge(connection: .notConnected)
            }
            Text("Connect your Claude subscription to see its limits here.").font(.caption).foregroundStyle(.secondary)
            Button { openAccounts() } label: { Label("Connect Claude…", systemImage: "link") }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(ProviderID.claude.accent)
        }
        .padding(14)
        .themedCard(ProviderID.claude.accent)
    }

    /// Existing installs reading Claude Code's item: one dismissible suggestion, never a forced migration.
    private var connectTip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(ProviderID.claude.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Stop Keychain prompts for Claude").font(.caption.weight(.semibold))
                Text("Connect QuotaVadis’s own Claude login in Settings.").font(.caption).foregroundStyle(.secondary)
                Button("Connect…") { openAccounts() }.controlSize(.small)
            }
            Spacer()
            Button { model.claudeConnectTipDismissed = true } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(tipBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if isObservatory {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(ProviderID.claude.accent.opacity(0.3), lineWidth: 1)
            }
        }
    }

    private var tipBackground: Color {
        switch theme {
        case .observatory: ObservatoryTheme.cardSurface
        case .goodLimits: GoodLimitsTheme.card
        case .auto, .standard: ProviderID.claude.accent.opacity(0.08)
        }
    }

    @ViewBuilder private var providerRows: some View {
        ForEach(model.visibleInstances) { instance in
            if model.states[instance.id] == nil, model.isRefreshing {
                // First read after setup: a spinner, not "sign in and refresh" for the second the fetch takes.
                loadingCard(instance)
            } else {
            // Cost reports come from local logs and cannot be split per organization: primary instance only.
            ProviderRow(provider: instance.provider, title: model.title(for: instance),
                        state: model.states[instance.id] ?? .unavailable,
                        cost: instance.id == instance.provider.rawValue ? model.costs[instance.provider] : nil,
                        isExpanded: model.expanded.contains(instance.id),
                        forecast: { model.forecast(instanceID: instance.id, window: $0, now: $1) },
                        primaryWindowID: model.primaryWindowIDs[instance.id],
                        action: action(for: instance),
                        showDetails: { bringToFront { openWindow(id: "dashboard", value: instance.id) } }) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    if model.expanded.contains(instance.id) { model.expanded.remove(instance.id) } else { model.expanded.insert(instance.id) }
                }
            }
            .padding(14)
            .themedCard(instance.provider.accent)
            .contextMenu {
                Button("View details") { bringToFront { openWindow(id: "dashboard", value: instance.id) } }
                if let windows = model.states[instance.id]?.snapshot?.windows, windows.count > 1 {
                    Picker("Show as main bar", selection: model.primaryWindowBinding(instance.id)) {
                        Text("Default").tag(String?.none)
                        ForEach(windows) { Text($0.title).tag(Optional($0.id)) }
                    }
                }
            }
            }
        }
    }

    private func loadingCard(_ instance: AppModel.Instance) -> some View {
        HStack(spacing: 9) {
            ProviderMark(provider: instance.provider, size: 26)
            Text(model.title(for: instance)).font(.headline)
            Spacer()
            ProgressView().controlSize(.small)
            Text("Reading limits…").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .themedCard(instance.provider.accent)
        .accessibilityElement(children: .combine)
    }

    /// Reconnect lives on the card it fixes; the flow itself is in Settings ▸ Accounts.
    private func action(for instance: AppModel.Instance) -> ProviderRowAction? {
        guard instance.id == "claude", model.claudeConnection == .reconnectRequired else { return nil }
        return ProviderRowAction(title: "Reconnect Claude…", systemImage: "arrow.triangle.2.circlepath", isWarning: true) { openAccounts() }
    }

    private func openAccounts() {
        model.settingsSection = .accounts
        bringToFront { openSettings() }
    }

    /// Recomputed on every tick: forecasts and "N limits at risk" move with the clock, not only with refreshes.
    /// No card while nothing has a snapshot yet. Hidden in Settings ▸ General = no card and no badge anywhere.
    private var riskSummary: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let summary = model.riskSummary(now: context.date) {
                RiskSummaryCard(summary: summary, now: context.date)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { bringToFront { openSettings() } } label: { Label("Settings", systemImage: "gearshape") }
                .help("Settings (⌘,)")
                .keyboardShortcut(",")
                .foregroundStyle(isObservatory ? ObservatoryTheme.starlight : .primary)
            Spacer()
            Button { bringToFront { openWindow(id: "about") } } label: { Image(systemName: "info.circle") }
                .help("About QuotaVadis")
                .accessibilityLabel("About QuotaVadis")
                .foregroundStyle(isObservatory ? ObservatoryTheme.secondaryText : .secondary)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit (⌘Q)")
                .accessibilityLabel("Quit QuotaVadis")
                .keyboardShortcut("q")
                .foregroundStyle(isObservatory ? ObservatoryTheme.secondaryText : .secondary)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .themedChromeBackground()
    }
}

extension AppModel {
    /// Big-bar pick for one card; nil clears it back to the default. A pick the snapshot no longer reports reads
    /// as Default (a Picker with no matching tag would write its first tag back) but stays saved for its return.
    func primaryWindowBinding(_ instanceID: String) -> Binding<String?> {
        Binding(get: {
            self.states[instanceID]?.snapshot?.reportedWindowID(self.primaryWindowIDs[instanceID])
        }, set: { self.primaryWindowIDs[instanceID] = $0 })
    }
}

/// A menu bar app is never the active app, so its windows open behind whatever is frontmost.
/// Go regular and activate first, open, then make the newest window key once SwiftUI has created it.
/// The deprecated ignoringOtherApps form on purpose: cooperative `activate()` may be declined when another
/// app is frontmost, and this is always an explicit user request.
@MainActor
func bringToFront(_ open: () -> Void) {
    WindowActivationController.shared.setRegular(true)
    NSApp.activate(ignoringOtherApps: true)
    open()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        let candidates = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey && !($0.className.contains("StatusBar") || $0.className.contains("MenuBarExtra")) }
        candidates.last?.makeKeyAndOrderFront(nil)
        // Settles the policy even if nothing opened (back to accessory) or the window was already key.
        WindowActivationController.shared.update()
    }
}
