import SwiftUI
import QuotaCore
import QuotaUI

/// Overview card: brand mark, accent chrome, shared usage bars, spend lines — same language as the Mac panel.
struct ProviderCard: View {
    let snapshot: UsageSnapshot
    let status: ProviderSyncStatus
    /// Forecast for a window at a moment, from the phone's history of this Mac's measurements.
    var forecast: ((UsageWindow, Date) -> UsageForecast?)?
    /// The window the user picked for the big bar; nil or no longer reported = the session.
    var primaryWindowID: String?
    /// Off where tapping selects in place instead of pushing (two panes).
    var showsChevron = true

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
                    // Same rule as the bars: the forecast's risk, the usage level without one. Text colour only.
                    Text("\(Int(worst.usedPercent.rounded()))%")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .riskTextStyle(UsageForecast.Risk(usedPercent: worst.usedPercent, forecast: forecast?(worst, .now)))
                        .accessibilityLabel("\(Int(worst.usedPercent.rounded())) percent used")
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
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
                // Claude-style, as in the Mac panel: the session (or the pick) as the big bar, the rest as cards.
                LimitOverview(snapshot: snapshot, primaryWindowID: primaryWindowID, forecast: forecast)
                ForEach(snapshot.credits.filter { $0.used > 0 }) { credit in
                    CreditsLine(credits: credit)
                }
            }
        }
        .padding(16)
        .themedCard(snapshot.provider.accent, cornerRadius: 22)
    }
}
