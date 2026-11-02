import Charts
import SwiftUI
import QuotaCore

/// A contextual button on a provider card (Connect, Reconnect), owned by the app, not by QuotaUI.
public struct ProviderRowAction {
    public let title: String
    public let systemImage: String
    public let isWarning: Bool
    public let perform: () -> Void
    public init(title: String, systemImage: String, isWarning: Bool = false, perform: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.isWarning = isWarning; self.perform = perform
    }
}

/// Collapsed: coloured mark, name, plan and the main bars. Expanded: every window, credits, resets, account,
/// freshness and a compact cost section. Provider colour marks identity only; bar colours keep meaning usage.
public struct ProviderRow: View {
    let provider: ProviderID
    let title: String
    let state: ProviderState
    let cost: CostReport?
    let isExpanded: Bool
    /// Forecast for a window at a given moment; called on every timeline tick so the projection stays current.
    let forecast: ((UsageWindow, Date) -> UsageForecast?)?
    /// The window the user picked for the big bar; nil or missing from the data = the default.
    let primaryWindowID: String?
    let toggle: () -> Void
    let action: ProviderRowAction?
    let showDetails: (() -> Void)?

    public init(provider: ProviderID, title: String? = nil, state: ProviderState, cost: CostReport?, isExpanded: Bool,
                forecast: ((UsageWindow, Date) -> UsageForecast?)? = nil, primaryWindowID: String? = nil,
                action: ProviderRowAction? = nil, showDetails: (() -> Void)? = nil, toggle: @escaping () -> Void) {
        self.provider = provider; self.title = title ?? provider.displayName; self.state = state; self.cost = cost
        self.isExpanded = isExpanded; self.forecast = forecast; self.primaryWindowID = primaryWindowID; self.toggle = toggle; self.action = action; self.showDetails = showDetails
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 9) {
                    ProviderMark(provider: provider, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.headline).lineLimit(1)
                        if let snapshot = state.snapshot, let plan = [snapshot.plan, isExpanded ? snapshot.seat : nil].compactMap({ $0 }).nonEmptyJoined {
                            Text(plan).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
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
            if case .failed(let error, _) = state, action == nil {
                Text(ProviderFailureCode(error).nextStep).font(.caption).foregroundStyle(.orange)
            }
            if let action {
                Button(action: action.perform) { Label(action.title, systemImage: action.systemImage) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .tint(action.isWarning ? .orange : provider.accent)
            }

            if let snapshot = state.snapshot {
                if let notice = snapshot.modelLimitNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                let layout = snapshot.overviewLayout(primaryWindowID: primaryWindowID)
                let others = layout.cards
                if let main = layout.main {
                    LimitBar(window: main, forecast: { forecast?(main, $0) }, style: .main)
                }
                // Two cards per row. Plain stacks, not a lazy grid: the menu panel sizes itself from intrinsic
                // content height (fixedSize), which a lazy container does not report.
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(stride(from: 0, to: others.count, by: 2)), id: \.self) { row in
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(others[row..<min(row + 2, others.count)]) { window in
                                    LimitBar(window: window, forecast: { forecast?(window, $0) }, style: .card)
                                }
                            }
                        }
                    }
                }
                // Money spent shows up front whenever there is any; zero-spend lines stay in the detail.
                ForEach(snapshot.credits.filter { $0.used > 0 }) { credits in
                    CreditsLine(credits: credits)
                }
                if isExpanded {
                    ForEach(snapshot.credits.filter { $0.used == 0 }) { credits in
                        CreditsLine(credits: credits)
                    }
                    ForEach(snapshot.windows.filter { w in w.id != layout.main?.id && !others.contains { $0.id == w.id } }) { window in
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
                    if let cost {
                        Divider().padding(.vertical, 2)
                        // The glance: figures and the daily chart. Models, projects and the token mix are a
                        // window of their own, one click below.
                        CostSection(report: cost, style: .glance)
                    }
                    HStack(spacing: 12) {
                        if let showDetails {
                            Button(action: showDetails) { Label(cost == nil ? "View details" : "Models & projects", systemImage: "chart.bar.xaxis") }
                                .buttonStyle(.bordered).controlSize(.small).tint(provider.accent)
                                .help("Open a window with every limit, the daily history and the model and project breakdowns")
                        }
                        Spacer()
                        Link(destination: provider.dashboardURL) { Label("Website", systemImage: "arrow.up.right.square") }
                            .help("Open \(provider.displayName)’s usage page in the browser")
                        Link(destination: provider.statusURL) { Label("Status", systemImage: "waveform.path.ecg") }
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }
            } else if case .unavailable = state, action == nil {
                Text("Open \(provider.displayName) on this Mac and sign in, then use Refresh above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Pace and forecast helpers for per-window bars.
internal func paceTint(_ pace: UsagePace) -> Color {
    switch pace.status {
    case .under, .onPace: usageTint(0)
    case .over where pace.deltaPercent < 15: usageTint(60)
    default: usageTint(100)
    }
}

/// A per-window bar: main (session) style or compact card style.
public struct LimitBar: View {
    public enum Style: Sendable { case main, card }
    let window: UsageWindow
    /// Evaluated inside the timeline, so "runs out at…" and the projected % move with the clock.
    let forecast: (Date) -> UsageForecast?
    let style: Style

    public init(window: UsageWindow, forecast: @escaping (Date) -> UsageForecast? = { _ in nil }, style: Style = .main) {
        self.window = window; self.forecast = forecast; self.style = style
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let pace = window.pace(now: now)
            let projection = forecast(now)
            // Bar and percentage follow the forecast's risk (usage level without one); pace text keeps its own colour.
            let tint = riskTintPercent(UsageForecast.Risk(usedPercent: window.usedPercent, forecast: projection))

            switch style {
            case .main:
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.title).font(.callout)
                        Spacer()
                        Text("\(Int(window.usedPercent.rounded()))%")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(usageTint(tint))
                    }
                    GlowBar(percent: window.usedPercent, height: 10, marker: pace?.expectedPercent, tintPercent: tint)
                    HStack {
                        resetLine(now)
                        Spacer(minLength: 6)
                        if let pace {
                            Text(pace.label).font(.caption2.weight(.medium)).foregroundStyle(paceTint(pace))
                        }
                    }
                    if let projection {
                        forecastLine(projection, now)
                    }
                }
                .accessibilityElement(children: .combine)
            case .card:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.title).font(.caption)
                        Spacer()
                        Text("\(Int(window.usedPercent.rounded()))%")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(usageTint(tint))
                    }
                    GlowBar(percent: window.usedPercent, height: 6, marker: pace?.expectedPercent, tintPercent: tint)
                    // Card width: short labels, and room for a second line rather than an ellipsis.
                    resetLine(now, compact: true)
                    if let pace {
                        Text(pace.label).font(.caption2.weight(.medium)).foregroundStyle(paceTint(pace))
                    }
                    if let projection {
                        forecastLine(projection, now, compact: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func resetLine(_ now: Date, compact: Bool = false) -> some View {
        Group {
            if let reset = window.resetsAt {
                let left = compact ? reset.compactRemainingLabel(now: now) : reset.remainingLabel(now: now)
                Label {
                    Text(reset <= now ? "reset passed" : "resets \(reset.resetClockLabel(now: now)) · \(left)")
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : 1).fixedSize(horizontal: false, vertical: compact)
                .help(reset.formatted(date: .complete, time: .shortened))
            } else {
                EmptyView()
            }
        }
    }

    private func forecastLine(_ forecast: UsageForecast, _ now: Date, compact: Bool = false) -> some View {
        Label(compact ? forecast.compactLabel(now: now) : forecast.label(now: now),
              systemImage: forecast.risk >= .atRisk ? "exclamationmark.triangle.fill" : "chart.line.uptrend.xyaxis")
        .font(.caption2)
        .lineLimit(compact ? 3 : nil).fixedSize(horizontal: false, vertical: true)
        .riskTextStyle(forecast.risk)
        .help("\(forecast.label(now: now)). " +
              (forecast.basis == .recent ? "Forecast from the last hour of usage" : "Forecast from the average since the window started"))
    }
}

private extension Array where Element == String {
    var nonEmptyJoined: String? { isEmpty ? nil : joined(separator: " · ") }
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

/// Spend against a cap as a bar: "Extra usage  $15.65 / $5.00". Without a cap, a plain line. Credit pools
/// (Codex) count credits, with the approximate dollar value as a quiet hint: "1,240 / 2,500 credits  ~$49.60 / ~$100".
public struct CreditsLine: View {
    let credits: UsageCredits

    public init(credits: UsageCredits) { self.credits = credits }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(credits.title).font(.caption)
                Spacer()
                if let reset = credits.resetsAt, credits.limit != nil {
                    ResetLabel(reset: reset)
                }
                if credits.limit == nil {
                    Text(credits.valueLabel()).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text(credits.valueLabel()).font(.caption.weight(.semibold).monospacedDigit()).riskTextStyle(risk)
                }
            }
            if let usd = credits.approxUSDLabel() {
                Text(usd).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("Approximate: credits valued at their list price")
            }
            if let percent = credits.usedPercent {
                GlowBar(percent: percent, height: 6)
            }
        }
    }

    /// Spend has no forecast: the usage-level fallback of the shared risk rule.
    private var risk: UsageForecast.Risk { UsageForecast.Risk(usedPercent: credits.usedPercent ?? 0, forecast: nil) }
}

/// The "Resets in 2 hours · 13:30" line next to a bar. A plain `Text` of the formatted string goes stale:
/// SwiftUI only re-evaluates a row whose data changed, so a window sitting at the same percentage for hours
/// keeps the relative distance it was first drawn with (a 13:30 reset still claiming "in 5 hours"). The
/// timeline makes the clock, not the usage numbers, the thing that drives this label.
struct ResetLabel: View {
    let reset: Date

    var body: some View {
        // "Resets in 5d 4h · 13:30"; the tooltip shows the full date/time.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(reset <= context.date ? "Reset passed" : "Resets \(reset.resetLabel(now: context.date))")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .help(reset.formatted(date: .complete, time: .shortened))
        }
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
                    ResetLabel(reset: reset)
                }
                // A fixed column: "5%" and "32%" line up, so the reset labels beside them do too.
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(usageTint(window.usedPercent))
                    .frame(minWidth: 34, alignment: .trailing)
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
        case .gemini: URL(string: "https://antigravity.google/")!
        }
    }

    var statusURL: URL {
        switch self {
        case .claude: URL(string: "https://status.anthropic.com")!
        case .codex: URL(string: "https://status.openai.com")!
        case .cursor: URL(string: "https://status.cursor.com")!
        case .gemini: URL(string: "https://status.cloud.google.com")!
        }
    }
}
