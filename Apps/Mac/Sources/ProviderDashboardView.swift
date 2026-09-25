import SwiftUI
import QuotaCore
import QuotaUI

/// One provider instance in a resizable window: limits and notices first, then tokens/cost, the history chart,
/// breakdowns, and account/source details last. Opened from "View details" on a panel card.
struct ProviderDashboardView: View {
    @Bindable var model: AppModel
    let instanceID: String
    @Environment(\.openSettings) private var openSettings

    private var instance: AppModel.Instance? { model.visibleInstances.first { $0.id == instanceID } }

    var body: some View {
        Group {
            if let instance {
                content(instance)
            } else {
                // The account was removed, the provider turned off, or its login went away since the window opened.
                ContentUnavailableView("Not available", systemImage: "questionmark.folder",
                                       description: Text("This account is no longer tracked. Turn it on in Settings ▸ Accounts."))
            }
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 480, idealHeight: 720)
    }

    private func content(_ instance: AppModel.Instance) -> some View {
        let state = model.states[instance.id] ?? .unavailable
        let snapshot = state.snapshot
        // Local logs are not split per organization, so only the primary instance carries a cost report.
        let cost = instance.id == instance.provider.rawValue ? model.costs[instance.provider] : nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ProviderMark(provider: instance.provider, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title(for: instance)).font(.title2.weight(.semibold))
                        if let plan = snapshot?.plan { Text(plan).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button { model.refreshNow() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(model.isRefreshing)
                }

                section("Limits", systemImage: "gauge.with.dots.needle.50percent", accent: instance.provider.accent) {
                    if let snapshot {
                        if let notice = snapshot.modelLimitNotice {
                            Label(notice, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                        }
                        ForEach(snapshot.windows) { UsageBar(window: $0, compact: !$0.prominent) }
                        ForEach(snapshot.credits) { CreditsLine(credits: $0) }
                    } else {
                        Text("No limits read yet.").foregroundStyle(.secondary)
                    }
                    if case .failed(let error, _) = state {
                        Label(error.localizedDescription, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    }
                    // The fix for a rejected Claude login lives in Settings; offer it where the failure is shown.
                    if instance.id == "claude", model.claudeConnection == .reconnectRequired {
                        Button {
                            model.settingsSection = .accounts
                            bringToFront { openSettings() }
                        } label: { Label("Reconnect Claude…", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.borderedProminent).tint(.orange)
                    }
                }

                if let cost {
                    section("Tokens & estimated cost", systemImage: "chart.bar.fill", accent: instance.provider.accent) {
                        CostSection(report: cost, style: .dashboard)
                    }
                } else if instance.id == instance.provider.rawValue {
                    section("Tokens & estimated cost", systemImage: "chart.bar.fill", accent: instance.provider.accent) {
                        Text(model.isRefreshingCosts ? "Reading local logs…" : "No cost data for this provider yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                section("Account", systemImage: "person.crop.circle", accent: instance.provider.accent) {
                    if let org = snapshot?.organization { DetailLine(title: "Organization", value: org) }
                    if let account = snapshot?.account { DetailLine(title: "Account", value: account) }
                    if let seat = snapshot?.seat { DetailLine(title: "Seat", value: seat) }
                    if let fetched = snapshot?.fetchedAt {
                        DetailLine(title: "Updated", value: fetched.formatted(.relative(presentation: .named)))
                    }
                    HStack(spacing: 14) {
                        Link(destination: instance.provider.dashboardURL) { Label("Open provider website", systemImage: "arrow.up.right.square") }
                        Link(destination: instance.provider.statusURL) { Label("Status", systemImage: "waveform.path.ecg") }
                        Spacer()
                    }
                    .font(.callout)
                }
            }
            .padding(20)
        }
        .navigationTitle(model.title(for: instance))
    }

    private func section<Content: View>(_ title: String, systemImage: String, accent: Color,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline).foregroundStyle(accent)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accentCard(accent, cornerRadius: 14)
    }
}
