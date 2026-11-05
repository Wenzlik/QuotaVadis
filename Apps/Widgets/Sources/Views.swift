import SwiftUI
import WidgetKit
import QuotaCore
import QuotaUI

/// The one place a widget says "nothing to show, and here is why". Never a blank tile: a desktop widget that
/// renders only whitespace is indistinguishable from a broken one, which is exactly how this bug was reported.
struct WidgetEmptyState: View {
    let state: WidgetContentState
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 6) {
                Image(systemName: state.symbol)
                    .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(state.headline)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            }
            Text(state.detail)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 3 : 4)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Single tool: ring on small, ring + bars on medium, Lock Screen accessories.
struct ProviderWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "cz.zmrhal.QuotaVadis.provider", intent: ProviderIntent.self, provider: ProviderTimelineProvider()) { entry in
            ProviderWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Tool usage")
        .description("How much of one tool's quota is used.")
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
        // `state` also covers "there is a payload, but this tool has no window to draw" — the case that used
        // to slip past every `if let` below and leave the tile blank.
        if let snapshot = entry.snapshot, entry.state.isReady {
            switch family {
            case .accessoryCircular: circular(snapshot)
            case .accessoryRectangular: rectangular(snapshot)
            case .accessoryInline: Text("\(snapshot.provider.shortName) \(pct(snapshot.worstWindow)) used · \(entry.payload?.status(for: snapshot).freshness(now: entry.date).rawValue ?? "Stale")")
            case .systemMedium: medium(snapshot)
            default: small(snapshot)
            }
        } else {
            empty
        }
    }

    @ViewBuilder private var empty: some View {
        switch family {
        case .accessoryInline: Text(entry.state.headline)
        case .accessoryCircular: Image(systemName: entry.state.symbol)
        case .accessoryRectangular: WidgetEmptyState(state: entry.state, compact: true)
        default: WidgetEmptyState(state: entry.state)
        }
    }

    private func measurement(_ s: UsageSnapshot) -> some View {
        Text(entry.payload?.status(for: s).label(now: entry.date) ?? "Stale")
            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
    }

    private func pct(_ w: UsageWindow?) -> String { w.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—" }

    private func small(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                ProviderMark(provider: s.provider, size: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.provider.displayName).font(.caption.weight(.semibold)).lineLimit(1)
                    if let plan = s.plan {
                        Text(plan).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            measurement(s)
            Spacer(minLength: 0)
            if let w = s.worstWindow {
                Gauge(value: min(1, w.usedPercent / 100)) { EmptyView() } currentValueLabel: {
                    Text("\(Int(w.usedPercent.rounded()))%")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(usageTint(w.usedPercent))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(usageTint(w.usedPercent))
                .frame(maxWidth: .infinity)
                Text(w.title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                if let reset = w.resetsAt {
                    Text("resets \(reset.compactRemainingLabel(now: entry.date)) · \(reset.resetClockLabel(now: entry.date))")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    private func medium(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderMark(provider: s.provider, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.provider.displayName).font(.subheadline.weight(.semibold))
                    if let plan = s.plan { Text(plan).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(entry.payload?.deviceName ?? "").font(.caption2).foregroundStyle(.tertiary)
            }
            measurement(s)
            ForEach(s.compactWindows.prefix(3)) { w in
                WidgetBarLine(window: w, now: entry.date, style: .compact)
            }
        }
    }

    private func circular(_ s: UsageSnapshot) -> some View {
        Gauge(value: min(1, (s.worstWindow?.usedPercent ?? 0) / 100)) {
            Image(systemName: entry.payload?.status(for: s).freshness(now: entry.date) == .fresh ? "flame.fill" : "exclamationmark.triangle")
        } currentValueLabel: {
            Text("\(Int((s.worstWindow?.usedPercent ?? 0).rounded()))")
        }
        .gaugeStyle(.accessoryCircular)
    }

    private func rectangular(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.provider.displayName).font(.headline)
            measurement(s)
            ForEach(s.compactWindows.prefix(2)) { w in
                HStack {
                    Text(w.title).font(.caption2)
                    Spacer()
                    Text("\(Int(w.usedPercent.rounded()))% used").font(.caption2.monospacedDigit())
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
        .description("Claude Code, Codex and Cursor side by side. Limits only, no cost estimates.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct OverviewWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        if let payload = entry.payload, entry.state.isReady {
            if family == .systemLarge { large(payload) } else { medium(payload) }
        } else {
            WidgetEmptyState(state: entry.state)
        }
    }

    /// Medium is ~155 pt tall: one line per tool, the highest window only, so three tools always fit.
    private func medium(_ payload: DevicePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(payload.snapshots.prefix(4)) { s in
                if let w = s.worstWindow {
                    WidgetProviderRow(snapshot: s, window: w, payload: payload, now: entry.date)
                }
            }
            Spacer(minLength: 0)
            footerLine(payload)
        }
    }

    private func large(_ payload: DevicePayload) -> some View {
        // Dynamically limit windows per provider based on provider count to fit in ~340pt
        // 4+ providers: 2 windows each, 3 providers: 3 windows, 1-2 providers: 3 windows
        let providerCount = payload.snapshots.count
        let maxWindows = providerCount >= 4 ? 2 : 3
        
        VStack(alignment: .leading, spacing: 4) {
            ForEach(payload.snapshots.prefix(4)) { s in
                WidgetProviderSection(snapshot: s, payload: payload, now: entry.date, maxWindows: maxWindows)
            }
            Spacer(minLength: 0)
            footerLine(payload)
        }
    }

    private func footerLine(_ payload: DevicePayload) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "desktopcomputer")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("\(payload.deviceName) · \(payload.snapshots.map(\.fetchedAt).min() ?? .distantPast, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

/// A progress bar line for widgets, using the polished GlowBar from QuotaUI.
struct WidgetBarLine: View {
    /// - `standard`: 7pt bar with pace marker, full caption text
    /// - `compact`: 5pt bar with pace marker, caption2 text
    /// - `mini`: 4pt bar WITHOUT pace marker, caption2 text (densest, for overflow situations)
    enum Style { case standard, compact, mini }

    let window: UsageWindow
    let now: Date
    var style: Style = .standard

    private var barHeight: CGFloat {
        switch style {
        case .standard: 7
        case .compact: 5
        case .mini: 4
        }
    }
    private var titleFont: Font { style == .standard ? .caption : .caption2 }
    private var percentFont: Font {
        style == .standard
            ? .caption.weight(.semibold).monospacedDigit()
            : .caption2.weight(.semibold).monospacedDigit()
    }
    private var showPaceMarker: Bool { style != .mini }

    var body: some View {
        let pace = showPaceMarker ? window.pace(now: now) : nil
        let risk = UsageForecast.Risk(usedPercent: window.usedPercent, forecast: nil)

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(titleFont)
                Spacer()
                if let reset = window.resetsAt {
                    Text(reset.compactRemainingLabel(now: now))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(percentFont)
                    .riskTextStyle(risk)
            }
            GlowBar(percent: window.usedPercent, height: barHeight, marker: pace?.expectedPercent, tintPercent: riskTintPercent(risk))
        }
    }
}

/// A single provider row in the medium overview widget (compact, one bar).
struct WidgetProviderRow: View {
    let snapshot: UsageSnapshot
    let window: UsageWindow
    let payload: DevicePayload
    let now: Date

    var body: some View {
        let pace = window.pace(now: now)
        let risk = UsageForecast.Risk(usedPercent: window.usedPercent, forecast: nil)
        let freshness = payload.status(for: snapshot).freshness(now: now)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                ProviderMark(provider: snapshot.provider, size: 14)
                Text(snapshot.provider.shortName)
                    .font(.caption.weight(.semibold))
                if freshness != .fresh {
                    Text(freshness.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let reset = window.resetsAt {
                    Text(reset.compactRemainingLabel(now: now))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .riskTextStyle(risk)
            }
            GlowBar(percent: window.usedPercent, height: 5, marker: pace?.expectedPercent, tintPercent: riskTintPercent(risk))
        }
    }
}

/// A provider section in the large overview widget (header + multiple bars).
/// Compact layout: no background padding, shows worst window with pace marker + 1-2 secondary windows without.
/// `maxWindows` limits how many bars to show per provider (to fit more providers).
struct WidgetProviderSection: View {
    let snapshot: UsageSnapshot
    let payload: DevicePayload
    let now: Date
    var maxWindows: Int = 3

    var body: some View {
        let freshness = payload.status(for: snapshot).freshness(now: now)
        let windows = snapshot.compactWindows.prefix(maxWindows)
        let worstID = snapshot.worstWindow?.id

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ProviderMark(provider: snapshot.provider, size: 12)
                Text(snapshot.provider.shortName)
                    .font(.caption2.weight(.semibold))
                if let plan = snapshot.plan {
                    Text(plan)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if freshness != .fresh {
                    Text("· \(freshness.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, w in
                // Show pace marker only on the worst/first window to save vertical space
                WidgetBarLine(window: w, now: now, style: w.id == worstID ? .compact : .mini)
            }
        }
    }
}

/// Legacy BarLine for backward compatibility (used in Switcher).
struct BarLine: View {
    let title: String
    let percent: Double
    let resetsAt: Date?
    let now: Date

    var body: some View {
        let risk = UsageForecast.Risk(usedPercent: percent, forecast: nil)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption2)
                Spacer()
                if let resetsAt {
                    Text(resetsAt.compactRemainingLabel(now: now))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("\(Int(percent.rounded()))%")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .riskTextStyle(risk)
            }
            GlowBar(percent: percent, height: 5, tintPercent: riskTintPercent(risk))
        }
    }
}
