import SwiftUI
import QuotaCore

/// Overview card: identity, the prominent windows as big bars, the first real spend line.
struct ProviderCard: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(snapshot.provider.tint.opacity(0.18))
                    Image(systemName: snapshot.provider.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(snapshot.provider.tint)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.displayTitle).font(.headline)
                    if let subtitle = snapshot.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if let worst = snapshot.worstWindow {
                    Text("\(Int(worst.usedPercent.rounded()))%")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(levelColor(worst.usedPercent))
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            VStack(spacing: 10) {
                ForEach(snapshot.windows.filter(\.prominent)) { window in
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font((compact ? Font.footnote : .subheadline).weight(.medium).monospacedDigit())
                    .foregroundStyle(levelColor(window.usedPercent))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(levelColor(window.usedPercent).gradient)
                        .frame(width: max(4, geo.size.width * min(1, max(0, window.usedPercent / 100))))
                }
            }
            .frame(height: compact ? 6 : 9)
        }
    }
}
