import SwiftUI
import QuotaCore

/// The whole UI: one row per provider, a footer. Nothing else.
struct MenuPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.visibleProviders.isEmpty {
                ContentUnavailableView("Nothing to track", systemImage: "gauge.with.dots.needle.0percent",
                                       description: Text("Log in to Claude Code, Codex or Cursor on this Mac."))
                    .frame(height: 160)
            } else {
                ForEach(model.visibleProviders) { id in
                    ProviderRow(provider: id, state: model.states[id] ?? .unavailable,
                                isExpanded: model.expanded.contains(id)) {
                        withAnimation(.snappy(duration: 0.2)) {
                            if model.expanded.contains(id) { model.expanded.remove(id) } else { model.expanded.insert(id) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if id != model.visibleProviders.last { Divider().padding(.horizontal, 14) }
                }
            }
            Divider()
            footer
        }
        .frame(width: 300)
        .background(.regularMaterial)
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
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh now")
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button {
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Image(systemName: "info.circle") }
                .help("About QuotaVadis")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Collapsed: name, plan and the main bars. Expanded: every window, credits, resets, account, freshness.
struct ProviderRow: View {
    let provider: ProviderID
    let state: ProviderState
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(provider.displayName).font(.headline)
                    if let plan = state.snapshot?.plan {
                        Text([plan, isExpanded ? state.snapshot?.seat : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if case .failed(let error, _) = state {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(error.localizedDescription)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let snapshot = state.snapshot {
                ForEach(mainWindows(snapshot)) { window in
                    UsageBar(window: window)
                }
                if isExpanded {
                    ForEach(snapshot.windows.filter { $0.kind == .model }) { window in
                        UsageBar(window: window, compact: true)
                    }
                    ForEach(snapshot.credits) { credits in
                        CreditsLine(credits: credits)
                    }
                    if let resets = snapshot.resetCreditsAvailable {
                        DetailLine(title: "Limit resets available", value: "\(resets)")
                    }
                    if let account = snapshot.account {
                        DetailLine(title: "Account", value: account)
                    }
                    if case .failed(let error, _) = state {
                        DetailLine(title: "Last error", value: error.localizedDescription).foregroundStyle(.orange)
                    }
                    DetailLine(title: "Updated", value: snapshot.fetchedAt.formatted(.relative(presentation: .named)))
                }
            } else if case .failed(let error, _) = state {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Collapsed rows show the session and the weekly/monthly bar only.
    private func mainWindows(_ snapshot: UsageSnapshot) -> [UsageWindow] {
        snapshot.windows.filter { $0.kind != .model }
    }
}

struct DetailLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// "Extra usage   $15.65 / $5.00" — spend against a cap, no bar.
struct CreditsLine: View {
    let credits: UsageCredits

    var body: some View {
        HStack {
            Text(credits.title).font(.caption)
            Spacer()
            Text(amount(credits.used) + (credits.limit.map { " / " + amount($0) } ?? ""))
                .font(.caption.monospacedDigit())
                .foregroundStyle(overCap ? .red : .secondary)
        }
    }

    private var overCap: Bool { credits.limit.map { credits.used >= $0 } ?? false }

    private func amount(_ value: Double) -> String {
        value.formatted(.currency(code: credits.currency).precision(.fractionLength(2)))
    }
}

struct UsageBar: View {
    let window: UsageWindow
    /// Sub-window (per-model breakdown): indented, thinner bar.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title).font(.caption).foregroundStyle(compact ? .secondary : .primary)
                Spacer()
                if let reset = window.resetsAt {
                    Text(reset, format: .relative(presentation: .numeric))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * min(1, max(0, window.usedPercent / 100)))
                }
            }
            .frame(height: compact ? 3 : 5)
        }
        .padding(.leading, compact ? 12 : 0)
    }

    private var tint: Color {
        switch window.usedPercent {
        case ..<50: .green
        case ..<80: .yellow
        default: .red
        }
    }
}
