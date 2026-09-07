import Charts
import SwiftUI
import QuotaCore

/// Collapsed: name, plan and the main bars. Expanded: every window, credits, resets, account, freshness.
public struct ProviderRow: View {
    let provider: ProviderID
    let title: String
    let state: ProviderState
    let cost: CostReport?
    let isExpanded: Bool
    let toggle: () -> Void

    public init(provider: ProviderID, title: String? = nil, state: ProviderState, cost: CostReport?, isExpanded: Bool, toggle: @escaping () -> Void) {
        self.provider = provider; self.title = title ?? provider.displayName; self.state = state; self.cost = cost
        self.isExpanded = isExpanded; self.toggle = toggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.headline).lineLimit(1)
                    if let snapshot = state.snapshot {
                        Text([snapshot.plan, isExpanded ? snapshot.seat : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(isExpanded ? "hide details" : "show details")")
            // Only speak up when something is wrong: a fresh row stays quiet.
            let status = ProviderSyncStatus(instanceID: state.snapshot?.instanceID ?? provider.rawValue, provider: provider, state: state, lastAttemptAt: nil)
            if status.freshness() != .fresh, state.snapshot != nil || status.errorCode != .unavailable {
                MeasurementStatusView(status: status)
            }
            if case .failed(let error, _) = state {
                Text(ProviderFailureCode(error).nextStep).font(.caption).foregroundStyle(.orange)
            }

            if let snapshot = state.snapshot {
                if let notice = snapshot.modelLimitNotice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
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
                    ForEach(snapshot.windows.filter { w in !mainWindows(snapshot).contains { $0.id == w.id } }) { window in
                        UsageBar(window: window, compact: true)
                    }
                    if let resets = snapshot.resetCreditsAvailable {
                        DetailLine(title: "Limit resets available", value: "\(resets)")
                        if !snapshot.resetCreditExpiries.isEmpty {
                            DetailLine(title: "Expire", value: snapshot.resetCreditExpiries
                                .map { $0.formatted(.dateTime.day().month(.abbreviated)) }.joined(separator: ", "))
                        }
                    }
                    if let org = snapshot.organization {
                        DetailLine(title: "Organization", value: org)
                    }
                    if let account = snapshot.account {
                        DetailLine(title: "Account", value: account)
                    }
                    if case .failed(let error, _) = state {
                        DetailLine(title: "Last error", value: error.localizedDescription).foregroundStyle(.orange)
                    }
                    DetailLine(title: "Updated", value: snapshot.fetchedAt.formatted(.relative(presentation: .named)))
                    HStack(spacing: 14) {
                        Link(destination: provider.dashboardURL) { Label("Dashboard", systemImage: "chart.bar.xaxis") }
                        Link(destination: provider.statusURL) { Label("Status", systemImage: "waveform.path.ecg") }
                        Spacer()
                    }
                    .font(.caption)
                    .padding(.top, 2)
                    if let cost {
                        Divider().padding(.vertical, 2)
                        CostSection(report: cost)
                    }
                }
            } else if case .unavailable = state {
                Text("Open \(provider.displayName) on this Mac and sign in, then use Refresh above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Keep the overview compact while retaining every binding exception.
    private func mainWindows(_ snapshot: UsageSnapshot) -> [UsageWindow] {
        snapshot.overviewWindows
    }
}

/// Today / 30-day spend and tokens, a daily bar chart, top model. Same numbers `quotactl --cost` prints.
public struct CostSection: View {
    let report: CostReport

    public init(report: CostReport) { self.report = report }
    @AppStorage("costChartMetric") private var metric: ChartMetric = .cost

    enum ChartMetric: String, CaseIterable { case cost, tokens }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    stat("Today", report.day(at: now).map { money($0.costUSD) } ?? "Unavailable")
                    stat("30d cost", money(report.totalCostUSD))
                }
                GridRow {
                    stat("Today tokens", report.day(at: now).map { tokens($0.tokens.total) } ?? "Unavailable")
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
                    .foregroundStyle(day.id == report.days.last?.id
                        ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor.opacity(0.7), Color.accentColor], startPoint: .bottom, endPoint: .top))
                        : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .cornerRadius(3)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { v in
                    AxisValueLabel { if let d = v.as(Double.self) { Text(axisLabel(d)).font(.caption2) } }
                }
            }
            .frame(height: 56)

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
                        Capsule().fill(LinearGradient(colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, geo.size.width * value(b) / maxValue))
                    }
                    .frame(height: 4)
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
                    Text(reset.resetLabel()).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(amount(credits.used) + (credits.limit.map { " / " + amount($0) } ?? ""))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(credits.limit == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            }
            if let percent = credits.usedPercent {
                GlowBar(percent: percent, height: 6)
            }
        }
    }

    private var tint: Color { usageTint(credits.usedPercent ?? 0) }

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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.caption).foregroundStyle(compact ? .secondary : .primary)
                Spacer()
                if let reset = window.resetsAt {
                    Text(reset <= .now ? "reset passed" : reset.resetLabel())
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(usageTint(window.usedPercent))
            }
            GlowBar(percent: window.usedPercent, height: compact ? 4 : 7)
        }
        .padding(.leading, compact ? 12 : 0)
        .accessibilityElement(children: .combine)
    }
}

public extension ProviderID {
    /// The provider's own usage page.
    var dashboardURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .cursor: URL(string: "https://cursor.com/dashboard")!
        case .antigravity: URL(string: "https://antigravity.google/")!
        }
    }

    var statusURL: URL {
        switch self {
        case .claude: URL(string: "https://status.anthropic.com")!
        case .codex: URL(string: "https://status.openai.com")!
        case .cursor: URL(string: "https://status.cursor.com")!
        case .antigravity: URL(string: "https://status.cloud.google.com")!
        }
    }
}
