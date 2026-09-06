import SwiftUI
import WidgetKit
import QuotaCore

func levelColor(_ percent: Double) -> Color {
    switch percent { case ..<50: .green; case ..<80: .yellow; default: .red }
}

/// Single tool: ring on small, ring + bars on medium, Lock Screen accessories.
struct ProviderWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "cz.zmrhal.QuotaVadis.provider", intent: ProviderIntent.self, provider: ProviderTimelineProvider()) { entry in
            ProviderWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Tool usage")
        .description("How much of one tool's quota is left.")
        .supportedFamilies(supported)
    }

    private var supported: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }
}

struct ProviderWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryCircular: circular(snapshot)
            case .accessoryRectangular: rectangular(snapshot)
            case .accessoryInline: Text("\(snapshot.provider.displayName) \(pct(snapshot.worstWindow))")
            case .systemMedium: medium(snapshot)
            default: small(snapshot)
            }
        } else {
            noData
        }
    }

    private var noData: some View {
        VStack(spacing: 4) {
            Image(systemName: "flame").font(.title2)
            Text("Open QuotaVadis").font(.caption)
        }.foregroundStyle(.secondary)
    }

    private func pct(_ w: UsageWindow?) -> String { w.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—" }

    private func small(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s.provider.displayName).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if let w = s.worstWindow {
                Gauge(value: min(1, w.usedPercent / 100)) { EmptyView() } currentValueLabel: {
                    Text("\(Int(w.usedPercent.rounded()))").font(.title3.weight(.semibold).monospacedDigit())
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(levelColor(w.usedPercent))
                .frame(maxWidth: .infinity)
                Text(w.title).font(.caption2).foregroundStyle(.secondary)
                if let reset = w.resetsAt {
                    Text("resets \(reset, style: .relative)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    private func medium(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(s.provider.displayName).font(.headline)
                if let plan = s.plan { Text(plan).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(entry.payload?.deviceName ?? "").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(s.windows.filter(\.prominent).prefix(3)) { w in
                BarLine(title: w.title, percent: w.usedPercent, resetsAt: w.resetsAt)
            }
        }
    }

    private func circular(_ s: UsageSnapshot) -> some View {
        Gauge(value: min(1, (s.worstWindow?.usedPercent ?? 0) / 100)) {
            Image(systemName: "flame.fill")
        } currentValueLabel: {
            Text("\(Int((s.worstWindow?.usedPercent ?? 0).rounded()))")
        }
        .gaugeStyle(.accessoryCircular)
    }

    private func rectangular(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.provider.displayName).font(.headline)
            ForEach(s.windows.filter(\.prominent).prefix(2)) { w in
                HStack {
                    Text(w.title).font(.caption2)
                    Spacer()
                    Text("\(Int(w.usedPercent.rounded()))%").font(.caption2.monospacedDigit())
                }
            }
        }
    }
}

/// All tools at once: medium shows two bars each, large adds today's and 30-day cost.
struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "cz.zmrhal.QuotaVadis.overview", provider: OverviewTimelineProvider()) { entry in
            OverviewWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("All tools")
        .description("Claude Code, Codex and Cursor side by side.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct OverviewWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        if let payload = entry.payload, !payload.snapshots.isEmpty {
            VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 8) {
                ForEach(payload.snapshots) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(s.provider.displayName).font(.caption.weight(.semibold))
                            Spacer()
                            if family == .systemLarge, let c = payload.cost(for: s.provider) {
                                Text("today \(money(c.today?.costUSD ?? 0)) · 30d \(money(c.totalCostUSD))")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(s.windows.filter(\.prominent).prefix(family == .systemLarge ? 3 : 2)) { w in
                            BarLine(title: w.title, percent: w.usedPercent, resetsAt: family == .systemLarge ? w.resetsAt : nil)
                        }
                    }
                }
                Spacer(minLength: 0)
                Text("\(payload.deviceName) · \(payload.updatedAt, style: .relative) ago").font(.caption2).foregroundStyle(.tertiary)
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "flame").font(.title2)
                Text("Open QuotaVadis").font(.caption)
            }.foregroundStyle(.secondary)
        }
    }

    private func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(0))) }
}

struct BarLine: View {
    let title: String
    let percent: Double
    let resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2)
                Spacer()
                if let resetsAt { Text(resetsAt, style: .relative).font(.caption2).foregroundStyle(.tertiary) }
                Text("\(Int(percent.rounded()))%").font(.caption2.monospacedDigit()).foregroundStyle(levelColor(percent))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(levelColor(percent)).frame(width: geo.size.width * min(1, max(0, percent / 100)))
                }
            }
            .frame(height: 4)
        }
    }
}
