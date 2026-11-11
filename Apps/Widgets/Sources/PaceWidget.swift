import SwiftUI
import WidgetKit
import QuotaCore

// MARK: - Pace Chart

/// The pace chart: dotted diagonal ideal line + solid usage line + end dot.
struct PaceChart: View {
    let elapsedFraction: Double
    let usedFraction: Double
    // .primary, not .white: widget backgrounds are light in light mode (system and GoodLimits.ai alike).
    var lineColor: Color = .primary
    var idealColor: Color = .primary.opacity(0.4)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                idealLine(w: w, h: h)
                usageLine(w: w, h: h)
                endDot(w: w, h: h)
            }
        }
    }

    private func idealLine(w: CGFloat, h: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w, y: 0))
        }
        .stroke(idealColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
    }

    private func usageLine(w: CGFloat, h: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: h))
            let x = w * CGFloat(min(elapsedFraction, 1))
            let y = h * CGFloat(1 - min(usedFraction, 1))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        .stroke(lineColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func endDot(w: CGFloat, h: CGFloat) -> some View {
        let x = w * CGFloat(min(elapsedFraction, 1))
        let y = h * CGFloat(1 - min(usedFraction, 1))
        return Circle()
            .fill(lineColor)
            .frame(width: 6, height: 6)
            .offset(x: x - 3, y: y - 3)
    }
}

// MARK: - Pace Entry

struct PaceEntry: TimelineEntry {
    let date: Date
    let result: Result<DevicePayload, SharedStore.ReadFailure>

    var payload: DevicePayload? { try? result.get() }

    var state: WidgetContentState { WidgetContent.overviewState(result) }

    static func entries(result: Result<DevicePayload, SharedStore.ReadFailure>, now: Date = .now) -> [PaceEntry] {
        WidgetContent.entryDates(for: try? result.get(), now: now).map { PaceEntry(date: $0, result: result) }
    }

    static var nextReload: Date { .now.addingTimeInterval(WidgetContent.reloadInterval) }

    static let placeholder = PaceEntry(date: .now, result: .success(.preview))
}

// MARK: - Timeline Provider

struct PaceTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PaceEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (PaceEntry) -> Void) {
        let result = SharedStore.readResult()
        let payload = (try? result.get()) ?? .preview
        completion(PaceEntry(date: .now, result: .success(payload)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PaceEntry>) -> Void) {
        completion(Timeline(entries: PaceEntry.entries(result: SharedStore.readResult()),
                            policy: .after(PaceEntry.nextReload)))
    }
}

// MARK: - Widget Definition

struct PaceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "cz.zmrhal.QuotaVadis.pace", provider: PaceTimelineProvider()) { entry in
            PaceWidgetView(entry: entry).widgetTheme(entry.payload)
        }
        .configurationDisplayName("Quota pace")
        .description("See whether a provider's quota lasts until it resets.")
        .supportedFamilies(families)
    }

    private var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

// MARK: - Widget Views

struct PaceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PaceEntry

    var body: some View {
        if let payload = entry.payload, entry.state.isReady {
            switch family {
            case .systemSmall: smallView(payload)
            case .systemMedium: mediumView(payload)
            case .systemLarge: largeView(payload)
            case .systemExtraLarge: extraLargeView(payload)
            default: smallView(payload)
            }
        } else {
            WidgetEmptyState(state: entry.state)
        }
    }

    private func paceData(for snapshot: UsageSnapshot, now: Date) -> (window: UsageWindow, pace: UsagePace)? {
        guard let window = snapshot.worstWindow, let pace = window.pace(now: now) else { return nil }
        return (window, pace)
    }

    private func firstTwoPace(_ payload: DevicePayload, now: Date) -> [(snapshot: UsageSnapshot, window: UsageWindow, pace: UsagePace)] {
        payload.snapshots.compactMap { snapshot in
            guard let data = paceData(for: snapshot, now: now) else { return nil }
            return (snapshot, data.window, data.pace)
        }.prefix(2).map { $0 }
    }

    // MARK: Small

    private func smallView(_ payload: DevicePayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot = payload.snapshots.first, let data = paceData(for: snapshot, now: entry.date) {
                HStack {
                    Text(snapshot.provider.shortName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(data.pace.label)
                        .font(.caption2)
                        .foregroundStyle(paceColor(data.pace))
                }
                PaceChart(
                    elapsedFraction: data.pace.elapsedFraction,
                    usedFraction: data.window.usedPercent / 100,
                    lineColor: paceColor(data.pace)
                )
            } else {
                Text("No pace data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Medium

    private func mediumView(_ payload: DevicePayload) -> some View {
        HStack(spacing: 12) {
            if let snapshot = payload.snapshots.first, let data = paceData(for: snapshot, now: entry.date) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.provider.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(data.window.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(data.pace.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(paceColor(data.pace))
                    if let reset = data.window.resetsAt {
                        Text("resets \(reset, style: .relative)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                PaceChart(
                    elapsedFraction: data.pace.elapsedFraction,
                    usedFraction: data.window.usedPercent / 100,
                    lineColor: paceColor(data.pace)
                )
                .frame(maxWidth: .infinity)
            } else {
                WidgetEmptyState(state: .noTrackedTools)
            }
        }
    }

    // MARK: Large (two stacked)

    private func largeView(_ payload: DevicePayload) -> some View {
        let items = firstTwoPace(payload, now: entry.date)
        return VStack(spacing: 8) {
            if items.isEmpty {
                WidgetEmptyState(state: .noTrackedTools)
            } else {
                ForEach(items.indices, id: \.self) { i in
                    paceRow(items[i].snapshot, items[i].window, items[i].pace)
                    if i < items.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
                if items.count == 1 {
                    Spacer()
                }
            }
        }
    }

    // MARK: Extra Large (two side by side)

    private func extraLargeView(_ payload: DevicePayload) -> some View {
        let items = firstTwoPace(payload, now: entry.date)
        return HStack(spacing: 16) {
            if items.isEmpty {
                WidgetEmptyState(state: .noTrackedTools)
            } else {
                ForEach(items.indices, id: \.self) { i in
                    paceColumn(items[i].snapshot, items[i].window, items[i].pace)
                    if i < items.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    // MARK: Shared Components

    private func paceRow(_ snapshot: UsageSnapshot, _ window: UsageWindow, _ pace: UsagePace) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.provider.displayName)
                    .font(.caption.weight(.semibold))
                Text(window.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(pace.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(paceColor(pace))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PaceChart(
                elapsedFraction: pace.elapsedFraction,
                usedFraction: window.usedPercent / 100,
                lineColor: paceColor(pace)
            )
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private func paceColumn(_ snapshot: UsageSnapshot, _ window: UsageWindow, _ pace: UsagePace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snapshot.provider.displayName)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(pace.label)
                    .font(.caption2)
                    .foregroundStyle(paceColor(pace))
            }
            Text(window.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            PaceChart(
                elapsedFraction: pace.elapsedFraction,
                usedFraction: window.usedPercent / 100,
                lineColor: paceColor(pace)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func paceColor(_ pace: UsagePace) -> Color {
        switch pace.status {
        case .under: Color(red: 0.16, green: 0.62, blue: 0.36)
        case .onPace: .primary
        case .over: Color(red: 0.88, green: 0.22, blue: 0.22)
        }
    }
}

// MARK: - Preview

#Preview("Small", as: .systemSmall) {
    PaceWidget()
} timeline: {
    PaceEntry(date: .now, result: .success(.preview))
}

#Preview("Medium", as: .systemMedium) {
    PaceWidget()
} timeline: {
    PaceEntry(date: .now, result: .success(.preview))
}

#Preview("Large", as: .systemLarge) {
    PaceWidget()
} timeline: {
    PaceEntry(date: .now, result: .success(.preview))
}
