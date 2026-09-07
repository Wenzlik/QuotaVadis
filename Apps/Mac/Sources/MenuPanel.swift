import SwiftUI
import QuotaCore
import QuotaUI

struct MenuPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !model.hasOnboarded {
                ContentUnavailableView("Welcome", systemImage: "flame",
                                       description: Text("Finish the welcome window to start reading your limits."))
                    .frame(height: 160)
            } else if model.enabledProviders.isEmpty {
                ContentUnavailableView {
                    Label("No tools selected", systemImage: "flame")
                } description: {
                    Text("Choose the tools you want to track on this Mac.")
                } actions: {
                    Button("Choose tools") { openSettings() }
                }
                .frame(height: 180)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let selectedID, let instance = model.visibleInstances.first(where: { $0.id == selectedID }) {
                            Button { self.selectedID = nil } label: { Label("All tools", systemImage: "chevron.left") }
                                .buttonStyle(.borderless).padding(14)
                            row(instance, detail: true)
                        } else {
                            ForEach(model.visibleInstances) { instance in
                                row(instance, detail: false)
                                if instance != model.visibleInstances.last { Divider().padding(.horizontal, 16) }
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: max(200, (NSScreen.main?.visibleFrame.height ?? 800) - 200))
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if let date = model.lastRefresh {
                    Text("Checked \(date, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Settings") { openSettings() }.keyboardShortcut(",")
            }
            .buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 380)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("QuotaVadis").font(.headline)
                Text(model.isRefreshing ? "Checking tools on this Mac…" : "This Mac · \(model.visibleInstances.count) tools")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.refresh(); await model.refreshCosts() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r").disabled(model.isRefreshing)
            .accessibilityLabel("Refresh usage and costs")
            Menu {
                Button("About QuotaVadis") { openWindow(id: "about"); NSApp.activate(ignoringOtherApps: true) }
                Button("Quit QuotaVadis") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions")
        }
        .buttonStyle(.borderless).padding(16)
    }

    @ViewBuilder private func row(_ instance: AppModel.Instance, detail: Bool) -> some View {
        if model.states[instance.id] == nil && model.isRefreshing {
            HStack { ProgressView().controlSize(.small); Text("Loading \(instance.provider.displayName)…").font(.callout) }
                .padding(16)
        } else {
            ProviderRow(provider: instance.provider, title: model.title(for: instance),
                        state: model.states[instance.id] ?? .unavailable,
                        cost: instance.id == instance.provider.rawValue ? model.costs[instance.provider] : nil,
                        isExpanded: detail) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    selectedID = detail ? nil : instance.id
                }
            }
            .padding(16)
        }
    }
}
