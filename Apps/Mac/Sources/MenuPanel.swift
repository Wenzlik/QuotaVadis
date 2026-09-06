import SwiftUI
import QuotaCore
import QuotaUI

/// The whole UI: one row per provider, a footer. Nothing else.
struct MenuPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.visibleInstances.isEmpty {
                ContentUnavailableView("Nothing to track", systemImage: "gauge.with.dots.needle.0percent",
                                       description: Text("Log in to Claude Code, Codex or Cursor on this Mac."))
                    .frame(height: 160)
            } else {
                // A bare ScrollView inside a MenuBarExtra window gets no height proposal and collapses to zero.
                // fixedSize makes it report its content height; the frame then caps it so long lists scroll.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        providerRows
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .frame(width: 300)
        .background(.regularMaterial)
    }

    /// Leave room for the menu bar and the footer on the smallest common display.
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, screen - 120)
    }

    @ViewBuilder private var providerRows: some View {
                ForEach(model.visibleInstances) { instance in
                    // Cost reports come from local logs and cannot be split per organization: primary instance only.
                    ProviderRow(provider: instance.provider, title: model.title(for: instance),
                                state: model.states[instance.id] ?? .unavailable,
                                cost: instance.id == instance.provider.rawValue ? model.costs[instance.provider] : nil,
                                isExpanded: model.expanded.contains(instance.id)) {
                        withAnimation(.snappy(duration: 0.2)) {
                            if model.expanded.contains(instance.id) { model.expanded.remove(instance.id) } else { model.expanded.insert(instance.id) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if instance != model.visibleInstances.last { Divider().padding(.horizontal, 14) }
                }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            } else if let date = model.lastRefresh {
                Text("Updated \(date, format: .relative(presentation: .named))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.refresh(); await model.refreshCosts() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh now (⌘R)")
                .keyboardShortcut("r")
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .help("Settings (⌘,)")
                .keyboardShortcut(",")
            Button {
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Image(systemName: "info.circle") }
                .help("About QuotaVadis")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit (⌘Q)")
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
