import SwiftUI
import QuotaCore
import QuotaUI

struct ProviderDetailView: View {
    let snapshot: UsageSnapshot
    let cost: CostReport?
    let deviceName: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                section("Limits", systemImage: "gauge.with.dots.needle.50percent") {
                    ForEach(snapshot.windows.filter(\.prominent)) { UsageBar(window: $0) }
                    ForEach(snapshot.windows.filter { !$0.prominent }) { UsageBar(window: $0, compact: true) }
                }

                if !snapshot.credits.isEmpty || snapshot.resetCreditsAvailable != nil {
                    section("Credits", systemImage: "creditcard") {
                        ForEach(snapshot.credits) { CreditsLine(credits: $0) }
                        if let resets = snapshot.resetCreditsAvailable {
                            DetailLine(title: "Limit resets available", value: "\(resets)")
                            if !snapshot.resetCreditExpiries.isEmpty {
                                DetailLine(
                                    title: "Expire",
                                    value: snapshot.resetCreditExpiries
                                        .map { $0.formatted(.dateTime.day().month(.abbreviated)) }
                                        .joined(separator: ", ")
                                )
                            }
                        }
                    }
                }

                if let cost {
                    section("Cost & tokens", systemImage: "chart.bar.fill") {
                        CostSection(report: cost, style: .compact)
                    }
                }

                section("Account", systemImage: "person.crop.circle") {
                    if let plan = snapshot.plan { DetailLine(title: "Plan", value: plan) }
                    if let seat = snapshot.seat { DetailLine(title: "Seat", value: seat) }
                    if let org = snapshot.organization { DetailLine(title: "Organization", value: org) }
                    if let account = snapshot.account { DetailLine(title: "Account", value: account) }
                    DetailLine(title: "Read on", value: deviceName)
                    DetailLine(title: "Updated", value: snapshot.fetchedAt.formatted(.relative(presentation: .named)))
                    HStack(spacing: 12) {
                        Link(destination: snapshot.provider.dashboardURL) {
                            Label("Open provider website", systemImage: "arrow.up.right.square")
                        }
                        Link(destination: snapshot.provider.statusURL) {
                            Label("Status", systemImage: "waveform.path.ecg")
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(snapshot.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var planSubtitle: String? {
        let parts = [snapshot.plan, snapshot.seat].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProviderMark(provider: snapshot.provider, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.displayTitle).font(.title3.weight(.semibold))
                if let plan = planSubtitle {
                    Text(plan).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .accentCard(snapshot.provider.accent, cornerRadius: 18)
    }

    private func section<Content: View>(_ title: String, systemImage: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(snapshot.provider.accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .accentCard(snapshot.provider.accent, cornerRadius: 16)
    }
}
