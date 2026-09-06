import Charts
import SwiftUI
import QuotaCore

/// Collapsed: name, plan and the main bars. Expanded: every window, credits, resets, account, freshness.
public struct ProviderRow: View {
    let provider: ProviderID
    let state: ProviderState
    let cost: CostReport?
    let isExpanded: Bool
    let toggle: () -> Void

    public init(provider: ProviderID, state: ProviderState, cost: CostReport?, isExpanded: Bool, toggle: @escaping () -> Void) {
        self.provider = provider; self.state = state; self.cost = cost; self.isExpanded = isExpanded; self.toggle = toggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(provider.displayName).font(.headline)
                    if let plan = state.snapshot?.plan {
                        Text([plan, isExpanded ? state.snapshot?.seat : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if case .failed(let error, _) = state {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(error.localizedDescription)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let snapshot = state.snapshot {
                ForEach(mainWindows(snapshot)) { window in
                    UsageBar(window: window)
                }
                // Money spent shows up front whenever there is any; zero-spend lines stay in the detail.
                ForEach(snapshot.credits.filter { $0.used > 0 }) { credits in
                    CreditsLine(credits: credits)
                }
                if isExpanded {
                    ForEach(snapshot.credits.filter { $0.used == 0 }) { credits in
                        CreditsLine(credits: credits)
                    }
                    ForEach(snapshot.windows.filter { !$0.prominent }) { window in
                        UsageBar(window: window, compact: true)
                    }
                    if let resets = snapshot.resetCreditsAvailable {
                        DetailLine(title: "Limit resets available", value: "\(resets)")
                    }
                    if let account = snapshot.account {
                        DetailLine(title: "Account", value: account)
                    }
                    if case .failed(let error, _) = state {
                        DetailLine(title: "Last error", value: error.localizedDescription).foregroundStyle(.orange)
                    }
                    DetailLine(title: "Updated", value: snapshot.fetchedAt.formatted(.relative(presentation: .named)))
                    if let cost {
                        Divider().padding(.vertical, 2)
                        CostSection(report: cost)
                    }
                }
            } else if case .failed(let error, _) = state {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Collapsed rows show the prominent windows (Claude's per-model weekly limits included).
    private func mainWindows(_ snapshot: UsageSnapshot) -> [UsageWindow] {
        snapshot.windows.filter(\.prominent)
    }
}

/// Today / 30-day spend and tokens, a daily bar chart, top model. Same numbers `quotactl --cost` prints.
public struct CostSection: View {
    let report: CostReport

    public init(report: CostReport) { self.report = report }
    @AppStorage("costChartMetric") private var metric: ChartMetric = .cost

    enum ChartMetric: String, CaseIterable { case cost, tokens }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    stat("Today", money(report.today?.costUSD ?? 0))
                    stat("30d cost", money(report.totalCostUSD))
                }
                GridRow {
                    stat("Today tokens", tokens(report.today?.tokens.total ?? 0))
                    stat("30d tokens", tokens(report.totalTokens))
                }
            }
            HStack {
                Text("Last 30 days").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $metric) {
                    Text("Cost").tag(ChartMetric.cost)
                    Text("Tokens").tag(ChartMetric.tokens)
                }
                .pickerStyle(.segmented).controlSize(.mini).frame(width: 110).labelsHidden()
            }
            Chart(report.days) { day in
                BarMark(x: .value("Day", day.id), y: .value(metric == .cost ? "USD" : "Tokens", value(day)))
                    .foregroundStyle(day.id == report.days.last?.id ? Color.accentColor : Color.secondary.opacity(0.45))
                    .cornerRadius(1.5)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { v in
                    AxisValueLabel { if let d = v.as(Double.self) { Text(axisLabel(d)).font(.caption2) } }
                }
            }
            .frame(height: 44)

            breakdown("By model", report.byModel)
            if !report.byProject.isEmpty { breakdown("By project", report.byProject) }
            Text(report.source).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Top five buckets as thin proportional bars; the rest folded into "Other".
    private func breakdown(_ title: String, _ buckets: [CostBucket]) -> some View {
        let shown = Array(buckets.prefix(5))
        let rest = buckets.dropFirst(5)
        let others = rest.isEmpty ? nil : CostBucket(id: "Other (\(rest.count))",
                                                     tokens: rest.reduce(TokenCounts()) { var t = $0; t += $1.tokens; return t },
                                                     costUSD: rest.reduce(0) { $0 + $1.costUSD }, requests: rest.reduce(0) { $0 + $1.requests })
        let rows = shown + (others.map { [$0] } ?? [])
        let maxValue = max(rows.map(value).max() ?? 1, 0.0001)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
            ForEach(rows) { b in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(label(b.id)).font(.caption).lineLimit(1).truncationMode(.head).help(b.id)
                        Spacer()
                        Text(metric == .cost ? money(b.costUSD) : tokens(b.tokens.total))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        Capsule().fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(2, geo.size.width * value(b) / maxValue))
                    }
                    .frame(height: 3)
                }
            }
        }
    }

    private func value(_ b: CostBucket) -> Double { metric == .cost ? b.costUSD : Double(b.tokens.total) }
    private func axisLabel(_ v: Double) -> String { metric == .cost ? money(v, digits: 0) : tokens(Int(v)) }

    /// Project ids are working directories; show the folder name, keep the full path in the tooltip.
    private func label(_ id: String) -> String {
        id.hasPrefix("/") ? (id as NSString).lastPathComponent : id
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func money(_ v: Double, digits: Int = 2) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }

    private func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: String(format: "%.0fM", Double(n) / 1e6)
        case 1_000...: String(format: "%.0fK", Double(n) / 1e3)
        default: "\(n)"
        }
    }
}

public struct DetailLine: View {
    let title: String
    let value: String

    public init(title: String, value: String) { self.title = title; self.value = value }

    public var body: some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Spend against a cap as a bar: "Extra usage  $15.65 / $5.00". Without a cap, a plain line.
public struct CreditsLine: View {
    let credits: UsageCredits

    public init(credits: UsageCredits) { self.credits = credits }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(credits.title).font(.caption)
                Spacer()
                if let reset = credits.resetsAt, credits.limit != nil {
                    Text(reset, format: .relative(presentation: .numeric)).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(amount(credits.used) + (credits.limit.map { " / " + amount($0) } ?? ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(credits.limit == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            }
            if let percent = credits.usedPercent {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(tint).frame(width: geo.size.width * min(1, max(0, percent / 100)))
                    }
                }
                .frame(height: 5)
            }
        }
    }

    private var tint: Color {
        switch credits.usedPercent ?? 0 {
        case ..<50: .green
        case ..<80: .yellow
        default: .red
        }
    }

    private func amount(_ value: Double) -> String {
        value.formatted(.currency(code: credits.currency).precision(.fractionLength(2)))
    }
}

public struct UsageBar: View {
    let window: UsageWindow
    /// Sub-window (per-model breakdown): indented, thinner bar.
    var compact = false

    public init(window: UsageWindow, compact: Bool = false) { self.window = window; self.compact = compact }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title).font(.caption).foregroundStyle(compact ? .secondary : .primary)
                Spacer()
                if let reset = window.resetsAt {
                    Text(reset, format: .relative(presentation: .numeric))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * min(1, max(0, window.usedPercent / 100)))
                }
            }
            .frame(height: compact ? 3 : 5)
        }
        .padding(.leading, compact ? 12 : 0)
    }

    private var tint: Color {
        switch window.usedPercent {
        case ..<50: .green
        case ..<80: .yellow
        default: .red
        }
    }
}
