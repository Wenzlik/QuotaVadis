import SwiftUI
import QuotaCore
import QuotaUI

/// Overview card: brand mark, accent chrome, shared usage bars, spend lines — same language as the Mac panel.
struct ProviderCard: View {
    let snapshot: UsageSnapshot
    let status: ProviderSyncStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProviderMark(provider: snapshot.provider, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.displayTitle).font(.headline)
                    if let subtitle = snapshot.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    } else if let plan = snapshot.plan {
                        Text(plan).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let worst = snapshot.worstWindow {
                    Text("\(Int(worst.usedPercent.rounded()))%")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(usageTint(worst.usedPercent))
                        .accessibilityLabel("\(Int(worst.usedPercent.rounded())) percent used")
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            MeasurementStatusView(status: status)
            if let error = status.errorCode {
                Text(error.nextStep).font(.caption).foregroundStyle(.orange)
            }
            if let notice = snapshot.modelLimitNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            VStack(spacing: 8) {
                ForEach(snapshot.overviewWindows) { window in
                    UsageBar(window: window)
                }
                ForEach(snapshot.credits.filter { $0.used > 0 }) { credit in
                    CreditsLine(credits: credit)
                }
            }
        }
        .padding(16)
        .accentCard(snapshot.provider.accent, cornerRadius: 22)
    }
}
