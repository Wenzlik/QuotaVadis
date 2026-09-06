import Charts
import SwiftUI
import QuotaCore
import QuotaUI

struct ProviderDetailView: View {
    let snapshot: UsageSnapshot
    let cost: CostReport?
    let deviceName: String

    var body: some View {
        List {
            Section {
                ForEach(snapshot.windows.filter(\.prominent)) { WindowLine(window: $0).padding(.vertical, 4) }
                let sub = snapshot.windows.filter { !$0.prominent }
                if !sub.isEmpty {
                    ForEach(sub) { WindowLine(window: $0, compact: true).padding(.vertical, 2) }
                }
            } header: { Text("Limits") }

            if !snapshot.credits.isEmpty || snapshot.resetCreditsAvailable != nil {
                Section("Credits") {
                    ForEach(snapshot.credits) { credit in
                        LabeledContent(credit.title) {
                            Text(credit.used.formatted(.currency(code: credit.currency).precision(.fractionLength(2)))
                                 + (credit.limit.map { " / " + $0.formatted(.currency(code: credit.currency).precision(.fractionLength(2))) } ?? ""))
                                .monospacedDigit()
                                .foregroundStyle(credit.limit.map { credit.used >= $0 } == true ? .red : .secondary)
                        }
                    }
                    if let resets = snapshot.resetCreditsAvailable {
                        LabeledContent("Limit resets available", value: "\(resets)")
                        if !snapshot.resetCreditExpiries.isEmpty {
                            LabeledContent("Expire", value: snapshot.resetCreditExpiries.map { $0.formatted(.relative(presentation: .numeric)) }.joined(separator: " · "))
                        }
                    }
                }
            }

            Section("Account") {
                if let plan = snapshot.plan { LabeledContent("Plan", value: plan) }
                if let seat = snapshot.seat { LabeledContent("Seat", value: seat) }
                if let org = snapshot.organization { LabeledContent("Organization", value: org) }
                if let account = snapshot.account { LabeledContent("Account", value: account) }
                LabeledContent("Read on", value: deviceName)
                LabeledContent("Updated", value: snapshot.fetchedAt.formatted(.relative(presentation: .named)))
                Link(destination: snapshot.provider.dashboardURL) { Label("Open dashboard", systemImage: "chart.bar.xaxis") }
                Link(destination: snapshot.provider.statusURL) { Label("Status page", systemImage: "waveform.path.ecg") }
            }

            if let cost {
                Section {
                    CostSection(report: cost).padding(.vertical, 4)
                } header: { Text("Cost & tokens") } footer: {
                    Text("Estimates at API list prices from the tool's local logs on your Mac. Subscriptions are not billed per token.")
                }
            }
        }
        .navigationTitle(snapshot.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
