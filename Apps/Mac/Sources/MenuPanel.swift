import SwiftUI
import QuotaCore
import QuotaUI

/// The whole UI: a header, one card per provider, a footer. Charts live in the dashboard window.
struct MenuPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !model.hasOnboarded {
                setupPrompt
            } else if model.visibleInstances.isEmpty && !needsClaudeConnect {
                ContentUnavailableView("Nothing to track", systemImage: "flame",
                                       description: Text("Log in to Claude Code, Codex, Cursor or Antigravity on this Mac, then Refresh."))
                    .frame(height: 160)
            } else {
                // A bare ScrollView inside a MenuBarExtra window gets no height proposal and collapses to zero.
                // fixedSize makes it report its content height; the frame then caps it so long lists scroll.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.showClaudeConnectTip { connectTip }
                        if needsClaudeConnect { connectCard }
                        providerRows
                    }
                    .padding(10)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { model.panelOpened() }
    }

    /// Leave room for the menu bar, header and footer on the smallest common display.
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, screen - 160)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
            Text("QuotaVadis").font(.headline)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let date = model.lastRefresh {
                Text("Updated \(date, format: .relative(presentation: .named))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { model.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh now (⌘R)")
                .accessibilityLabel("Refresh now")
                .keyboardShortcut("r")
                .disabled(!model.hasOnboarded)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        .accentCard(ProviderID.claude.accent)
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
        .background(ProviderID.claude.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var providerRows: some View {
        ForEach(model.visibleInstances) { instance in
            // Cost reports come from local logs and cannot be split per organization: primary instance only.
            ProviderRow(provider: instance.provider, title: model.title(for: instance),
                        state: model.states[instance.id] ?? .unavailable,
                        cost: instance.id == instance.provider.rawValue ? model.costs[instance.provider] : nil,
                        isExpanded: model.expanded.contains(instance.id),
                        action: action(for: instance),
                        showDetails: { bringToFront { openWindow(id: "dashboard", value: instance.id) } }) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    if model.expanded.contains(instance.id) { model.expanded.remove(instance.id) } else { model.expanded.insert(instance.id) }
                }
            }
            .padding(14)
            .accentCard(instance.provider.accent)
            .contextMenu {
                Button("View details") { bringToFront { openWindow(id: "dashboard", value: instance.id) } }
            }
        }
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

    private var footer: some View {
        HStack(spacing: 12) {
            Button { bringToFront { openSettings() } } label: { Label("Settings", systemImage: "gearshape") }
                .help("Settings (⌘,)")
                .keyboardShortcut(",")
            Spacer()
            Button { bringToFront { openWindow(id: "about") } } label: { Image(systemName: "info.circle") }
                .help("About QuotaVadis")
                .accessibilityLabel("About QuotaVadis")
                .foregroundStyle(.secondary)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit (⌘Q)")
                .accessibilityLabel("Quit QuotaVadis")
                .keyboardShortcut("q")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A menu bar app is never the active app, so its windows open behind whatever is frontmost.
/// Activate first, open, then make the newest window key once SwiftUI has created it.
@MainActor
func bringToFront(_ open: () -> Void) {
    NSApp.activate(ignoringOtherApps: true)
    open()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        NSApp.activate(ignoringOtherApps: true)
        let candidates = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey && !($0.className.contains("StatusBar") || $0.className.contains("MenuBarExtra")) }
        candidates.last?.makeKeyAndOrderFront(nil)
    }
}
