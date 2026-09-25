import Charts
import SwiftUI
import QuotaCore

/// How much room a cost section gets.
/// - `glance`: the menu panel's expanded card — the four figures and the daily chart, nothing that needs
///   reading; breakdowns wait in the dashboard window.
/// - `compact`: a phone-width detail screen (iOS): everything, tightly spaced.
/// - `dashboard`: a resizable Mac window: everything, with room to breathe.
public enum CostSectionStyle: Sendable {
    case glance, compact, dashboard
}

/// Today / 30-day tokens and estimated cost, a dated daily chart, token composition, and model/project
/// breakdowns ranked by whichever metric is selected. Same numbers `quotavadis cost` prints.
public struct CostSection: View {
    let report: CostReport
    let style: CostSectionStyle
    @AppStorage("costChartMetric") private var metric: CostMetric = .cost

    public init(report: CostReport, style: CostSectionStyle = .compact) { self.report = report; self.style = style }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: style == .dashboard ? 16 : 10) {
                CostSummaryCards(report: report, now: context.date, style: style)
                HStack {
                    Text("Last \(report.days.count) days").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Chart shows", selection: $metric) {
                        Text("Cost").tag(CostMetric.cost)
                        Text("Tokens").tag(CostMetric.tokens)
                    }
                    .pickerStyle(.segmented).controlSize(.small).frame(width: 130).labelsHidden()
                    .accessibilityLabel("Chart shows cost or tokens")
                }
                UsageHistoryChart(report: report, metric: metric, now: context.date,
                                  height: style == .dashboard ? 200 : (style == .glance ? 84 : 100))
                if style != .glance {
                    TokenCompositionBar(tokens: report.tokenComposition)
                    CostBreakdownView(title: "By model", buckets: report.byModel, metric: metric,
                                      top: style == .dashboard ? 8 : 5, accent: report.provider.accent)
                    if !report.byProject.isEmpty {
                        CostBreakdownView(title: "By project", buckets: report.byProject, metric: metric,
                                          top: style == .dashboard ? 8 : 5, accent: report.provider.accent,
                                          shareCaption: "share of tracked projects")
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if style != .glance { Text(report.source) }
                    Text("Computed \(report.generatedAt.formatted(.relative(presentation: .named)))")
                }
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Where a cost figure comes from, said next to the figure itself rather than only in the footer.
func costProvenance(_ provider: ProviderID) -> String {
    provider == .cursor ? "Metered cost from Cursor’s dashboard" : "API-price estimate — not your subscription bill"
}

/// Four clearly labelled figures: tokens first, estimated cost second.
public struct CostSummaryCards: View {
    let report: CostReport
    let now: Date
    let style: CostSectionStyle

    public init(report: CostReport, now: Date = .now, style: CostSectionStyle = .compact) {
        self.report = report; self.now = now; self.style = style
    }

    public var body: some View {
        let today = report.day(at: now)
        VStack(alignment: .leading, spacing: 6) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    tile("Today tokens", today.map { CostFormat.tokens($0.tokens.total) }, symbol: "number")
                    tile("\(report.days.count)-day tokens", CostFormat.tokens(report.totalTokens), symbol: "sum")
                }
                GridRow {
                    tile("Today cost", today.map { CostFormat.money($0.costUSD) }, symbol: "dollarsign")
                    tile("\(report.days.count)-day cost", CostFormat.money(report.totalCostUSD), symbol: "calendar")
                }
            }
            Label(costProvenance(report.provider), systemImage: "info.circle")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// nil value: the report is from an earlier day, so "today" is unknown rather than zero.
    private func tile(_ title: String, _ value: String?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(.secondary).labelStyle(.titleOnly)
            Text(value ?? "Unavailable")
                .font((style == .dashboard ? Font.title3 : .callout).weight(.semibold).monospacedDigit())
                .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(report.provider.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Discrete daily totals as bars (never smoothed into an invented curve), with dates, a zero baseline and a
/// hover/selection readout. Dates are the report's own calendar days, in the zone that produced them.
public struct UsageHistoryChart: View {
    let report: CostReport
    let metric: CostMetric
    let now: Date
    let height: CGFloat
    @State private var selected: Date?

    public init(report: CostReport, metric: CostMetric, now: Date = .now, height: CGFloat = 100) {
        self.report = report; self.metric = metric; self.now = now; self.height = height
    }

    private struct Point: Identifiable {
        let bucket: CostBucket
        let date: Date
        var id: String { bucket.id }
    }

    public var body: some View {
        let points = report.days.compactMap { day in report.date(of: day).map { Point(bucket: day, date: $0) } }
        let todayID = report.day(at: now)?.id
        let accent = report.provider.accent
        let calendar = report.bucketCalendar
        let selectedPoint = selected.flatMap { s in points.first { calendar.isDate($0.date, inSameDayAs: s) } }
        let isEmpty = !points.contains { $0.bucket.value(metric) > 0 }
        VStack(alignment: .leading, spacing: 4) {
            readout(selectedPoint ?? points.last { $0.bucket.id == todayID } ?? points.last)
            Chart(points) { point in
                BarMark(x: .value("Day", point.date, unit: .day), y: .value(metric == .cost ? "USD" : "Tokens", point.bucket.value(metric)))
                    .foregroundStyle(point.bucket.id == todayID || point.id == selectedPoint?.id
                        ? AnyShapeStyle(LinearGradient(colors: [accent.opacity(0.75), accent], startPoint: .bottom, endPoint: .top))
                        : AnyShapeStyle(accent.opacity(0.6)))
                    .cornerRadius(2)
                // A concrete colour: a hierarchical style on a mark resolves against the chart's series colour
                // and paints the baseline bright blue.
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.primary.opacity(0.28)).lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            .chartOverlay { _ in
                // All-zero days: say so, instead of an axis floating over nothing.
                if isEmpty {
                    Text("No \(metric == .cost ? "estimated cost" : "tokens") recorded in these \(points.count) days")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: height > 150 ? 5 : 10)) { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: false).font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: height > 150 ? 4 : 2)) { v in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(axisLabel(d)).font(.caption2) } }
                }
            }
            .environment(\.timeZone, calendar.timeZone)
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel(summary(points))
        }
    }

    private func readout(_ point: Point?) -> some View {
        HStack(spacing: 6) {
            if let point {
                Text(point.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: report.bucketCalendar.timeZone)))
                    .fontWeight(.medium)
                Text("·")
                Text(CostFormat.money(point.bucket.costUSD))
                Text("·")
                Text("\(CostFormat.tokens(point.bucket.tokens.total)) tokens")
            }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func axisLabel(_ v: Double) -> String { metric == .cost ? CostFormat.money(v, digits: 0) : CostFormat.tokens(Int(v)) }

    private func summary(_ points: [Point]) -> String {
        let peak = points.max { $0.bucket.value(metric) < $1.bucket.value(metric) }
        let total = metric == .cost ? CostFormat.money(report.totalCostUSD) : "\(CostFormat.tokens(report.totalTokens)) tokens"
        var text = "Daily \(metric == .cost ? "estimated cost" : "tokens") for the last \(points.count) days, total \(total)."
        if let peak, peak.bucket.value(metric) > 0 {
            text += " Highest on \(peak.date.formatted(date: .abbreviated, time: .omitted)): " +
                (metric == .cost ? CostFormat.money(peak.bucket.costUSD) : "\(CostFormat.tokens(peak.bucket.tokens.total)) tokens") + "."
        }
        return text
    }
}

/// Input / output / cache read / cache write as one labelled stacked bar with a numeric legend. Shares are
/// of tokens only — cache reads are cheap, so this is not a cost split.
public struct TokenCompositionBar: View {
    let tokens: TokenCounts
    public init(tokens: TokenCounts) { self.tokens = tokens }

    private var parts: [(String, Int, Color)] {
        [("Input", tokens.input, .blue), ("Output", tokens.output, .purple),
         ("Cache read", tokens.cacheRead, .teal), ("Cache write", tokens.cacheWrite, .mint)]
            .filter { $0.1 > 0 }
    }

    public var body: some View {
        let total = max(tokens.total, 1)
        if tokens.total > 0 {
            VStack(alignment: .leading, spacing: 5) {
                Text("Token mix").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                GeometryReader { geo in
                    HStack(spacing: 1.5) {
                        ForEach(parts, id: \.0) { part in
                            Rectangle().fill(part.2.gradient)
                                .frame(width: max(2, (geo.size.width - 1.5 * CGFloat(parts.count - 1)) * CGFloat(part.1) / CGFloat(total)))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                FlowLegend(items: parts.map { ($0.0, "\(CostFormat.tokens($0.1)) · \(CostFormat.percent(Double($0.1) / Double(total)))", $0.2) })
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct FlowLegend: View {
    let items: [(String, String, Color)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), alignment: .leading)], alignment: .leading, spacing: 3) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.2).frame(width: 7, height: 7)
                    Text(item.0).foregroundStyle(.primary)
                    Text(item.1).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption2).lineLimit(1)
            }
        }
    }
}

/// Top buckets ranked by the selected metric, each with its value and share; the rest folded into "Other".
public struct CostBreakdownView: View {
    let title: String
    let buckets: [CostBucket]
    let metric: CostMetric
    let top: Int
    let accent: Color
    let shareCaption: String

    public init(title: String, buckets: [CostBucket], metric: CostMetric, top: Int = 5, accent: Color = .accentColor,
                shareCaption: String = "share of total") {
        self.title = title; self.buckets = buckets; self.metric = metric; self.top = top; self.accent = accent
        self.shareCaption = shareCaption
    }

    public var body: some View {
        let rows = CostBreakdown.rows(buckets, metric: metric, top: top)
        let maxShare = rows.map(\.share).max() ?? 0
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(shareCaption).font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(row.isOther ? Color.secondary : BucketPalette.color(for: row.id)).frame(width: 6, height: 6)
                        Text(label(row.id)).font(.caption).lineLimit(1).truncationMode(.head)
                            .help(row.isOther ? "\(row.folded) smaller items combined" : row.id)
                        Spacer()
                        Text(metric == .cost ? CostFormat.money(row.bucket.costUSD) : CostFormat.tokens(row.bucket.tokens.total))
                            .font(.caption.monospacedDigit())
                        Text(CostFormat.percent(row.share))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.06))
                            // Exactly zero draws no bar at all.
                            if row.share > 0, maxShare > 0 {
                                Capsule().fill((row.isOther ? Color.secondary : BucketPalette.color(for: row.id)).opacity(0.85))
                                    .frame(width: max(3, geo.size.width * row.share / maxShare))
                            }
                        }
                    }
                    .frame(height: 4)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Project ids are working directories; show the folder name, keep the full path in the tooltip.
    private func label(_ id: String) -> String {
        id.hasPrefix("/") ? (id as NSString).lastPathComponent : id
    }
}

/// Stable colour per bucket id (a model or project keeps its colour when the metric or rank changes).
/// A fixed hash, not `hashValue`, which Swift randomises per launch.
enum BucketPalette {
    // No red/green/yellow: those stay reserved for usage severity.
    static let colors: [Color] = [.blue, .purple, .teal, .indigo, .cyan, .mint, .brown, .orange]
    static func color(for id: String) -> Color {
        let hash = id.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) }
        return colors[Int(hash % UInt32(colors.count))]
    }
}

enum CostFormat {
    static func money(_ v: Double, digits: Int = 2) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: String(format: "%.1fB", Double(n) / 1e9)
        case 10_000_000...: String(format: "%.0fM", Double(n) / 1e6)
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: String(format: "%.0fK", Double(n) / 1e3)
        default: "\(n)"
        }
    }

    static func percent(_ share: Double) -> String {
        share > 0 && share < 0.01 ? "<1%" : share.formatted(.percent.precision(.fractionLength(0)))
    }
}
