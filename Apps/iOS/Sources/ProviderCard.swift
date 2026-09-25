import SwiftUI
import QuotaCore
import QuotaUI

/// Overview card: identity, the prominent windows as big bars, the first real spend line.
struct ProviderCard: View {
    let snapshot: UsageSnapshot
    let status: ProviderSyncStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProviderMark(provider: snapshot.provider, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.displayTitle).font(.headline)
                    if let subtitle = snapshot.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if let worst = snapshot.worstWindow {
                    Text("\(Int(worst.usedPercent.rounded()))% used")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(levelColor(worst.usedPercent))
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            MeasurementStatusView(status: status)
            if let error = status.errorCode { Text(error.nextStep).font(.caption).foregroundStyle(.orange) }
            if let notice = snapshot.modelLimitNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
            VStack(spacing: 10) {
                ForEach(snapshot.overviewWindows) { window in
                    WindowLine(window: window)
                }
                ForEach(snapshot.credits.filter { $0.used > 0 }) { credit in
                    HStack {
                        Text(credit.title).font(.subheadline)
                        Spacer()
                        Text(credit.used.formatted(.currency(code: credit.currency).precision(.fractionLength(2)))
                             + (credit.limit.map { " / " + $0.formatted(.currency(code: credit.currency).precision(.fractionLength(0))) } ?? ""))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(credit.limit.map { credit.used >= $0 } == true ? .red : .secondary)
                    }
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 22)
    }
}

struct WindowLine: View {
    let window: UsageWindow
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(compact ? .footnote : .subheadline).foregroundStyle(compact ? .secondary : .primary)
                Spacer()
                if let reset = window.resetsAt {
                    Text(reset.resetLabel()).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text("\(Int(window.usedPercent.rounded()))% used")
                    .font((compact ? Font.footnote : .subheadline).weight(.medium).monospacedDigit())
                    .foregroundStyle(levelColor(window.usedPercent))
            }
            GlowBar(percent: window.usedPercent, height: compact ? 6 : 9)
        }
    }
}
