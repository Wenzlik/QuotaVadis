import SwiftUI
import QuotaCore

/// The whole UI: one row per provider, a footer. Nothing else.
struct MenuPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.visibleProviders.isEmpty {
                ContentUnavailableView("Nothing to track", systemImage: "gauge.with.dots.needle.0percent",
                                       description: Text("Log in to Claude Code, Codex or Cursor on this Mac."))
                    .frame(height: 160)
            } else {
                ForEach(model.visibleProviders) { id in
                    ProviderRow(provider: id, state: model.states[id] ?? .unavailable)
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
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct ProviderRow: View {
    let provider: ProviderID
    let state: ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.displayName).font(.headline)
                if let plan = state.snapshot?.plan {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .failed(let error, _) = state {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .help(error.localizedDescription)
                }
            }
            if let snapshot = state.snapshot {
                ForEach(snapshot.windows.filter { $0.kind != .model }) { window in
                    UsageBar(window: window)
                }
            } else if case .failed(let error, _) = state {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct UsageBar: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title).font(.caption)
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
            .frame(height: 5)
        }
    }

    private var tint: Color {
        switch window.usedPercent {
        case ..<50: .green
        case ..<80: .yellow
        default: .red
        }
    }
}
