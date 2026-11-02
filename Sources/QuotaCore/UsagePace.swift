import Foundation

public extension UsageWindow {
    /// Nominal length of the rolling window: `windowSeconds` when reported, otherwise derived from `kind`.
    func windowLength(calendar: Calendar = .current) -> TimeInterval? {
        if let windowSeconds, windowSeconds > 0 { return windowSeconds }
        switch kind {
        case .session: return 5 * 3600
        case .weekly: return 7 * 86400
        case .monthly:
            guard let resetsAt else { return 30 * 86400 }
            return calendar.date(byAdding: .month, value: -1, to: resetsAt).map { resetsAt.timeIntervalSince($0) } ?? 30 * 86400
        case .model, .credits: return nil
        }
    }

    /// Start of the current window (`resetsAt - windowLength`), nil when either is unknown.
    func windowStart(calendar: Calendar = .current) -> Date? {
        guard let resetsAt, let length = windowLength(calendar: calendar) else { return nil }
        return resetsAt.addingTimeInterval(-length)
    }

    /// Pace vs even consumption over the window. Nil when the window is not active or has no measurable length.
    func pace(now: Date = .now, calendar: Calendar = .current) -> UsagePace? {
        guard let resetsAt, let start = windowStart(calendar: calendar), now >= start, now < resetsAt else { return nil }
        let length = resetsAt.timeIntervalSince(start)
        guard length > 0 else { return nil }
        let elapsedFraction = min(max((now.timeIntervalSince(start) / length), 0), 1)
        let expectedPercent = elapsedFraction * 100
        let deltaPercent = usedPercent - expectedPercent
        return UsagePace(elapsedFraction: elapsedFraction, expectedPercent: expectedPercent, deltaPercent: deltaPercent)
    }
}

/// Result of `UsageWindow.pace(now:calendar:)`.
public struct UsagePace: Sendable, Hashable {
    public var elapsedFraction: Double
    public var expectedPercent: Double
    public var deltaPercent: Double

    public init(elapsedFraction: Double, expectedPercent: Double, deltaPercent: Double) {
        self.elapsedFraction = elapsedFraction
        self.expectedPercent = expectedPercent
        self.deltaPercent = deltaPercent
    }

    public enum Status: Sendable, Hashable {
        case onPace, under, over
    }

    public var status: Status {
        if abs(deltaPercent) < 3 { return .onPace }
        return deltaPercent < 0 ? .under : .over
    }

    public var label: String {
        switch status {
        case .onPace: return "on pace"
        case .under: return "\(Int(abs(deltaPercent).rounded()))% under pace"
        case .over: return "\(Int(abs(deltaPercent).rounded()))% over pace"
        }
    }
}

/// One measured usage sample.
public struct UsageSample: Codable, Sendable, Hashable {
    public var at: Date
    public var percent: Double
    public init(at: Date, percent: Double) {
        self.at = at
        self.percent = percent
    }
}

/// Forecast of usage at window reset.
public struct UsageForecast: Sendable, Hashable {
    public enum Risk: Int, Sendable, Comparable {
        case safe, watch, atRisk, exhausted
        // Comparable is not synthesized for raw-value enums (SE-0266): order by severity explicitly.
        public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Basis: Sendable, Hashable {
        case recent, windowAverage
    }

    /// Projected used% at reset (not clamped above 100, >= current used).
    public var projectedPercent: Double
    /// When 100% is reached before the reset; nil if it fits.
    public var runsOutAt: Date?
    public var resetsAt: Date
    /// Percentage points per hour, >= 0.
    public var ratePerHour: Double
    public var basis: Basis
    public var risk: Risk

    public init(projectedPercent: Double, runsOutAt: Date?, resetsAt: Date, ratePerHour: Double, basis: Basis, risk: Risk) {
        self.projectedPercent = projectedPercent
        self.runsOutAt = runsOutAt
        self.resetsAt = resetsAt
        self.ratePerHour = ratePerHour
        self.basis = basis
        self.risk = risk
    }

    public func label(now: Date = .now, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        if risk == .exhausted { return "limit reached" }
        if let runsOutAt {
            let gap = Self.shortDuration(resetsAt.timeIntervalSince(runsOutAt))
            return "runs out at \(runsOutAt.resetClockLabel(now: now, calendar: calendar, locale: locale)) · \(gap) before reset"
        }
        return "fits, ends at ~\(Int(min(projectedPercent, 100).rounded()))%"
    }

    /// Shown instead of a projection when `UsageForecaster` returns nil for an active window.
    public static let notEnoughDataLabel = "forecast: not enough data yet"

    /// Card-width variant: "runs out Sun 10:47" without the gap to the reset; `label` goes in the tooltip.
    public func compactLabel(now: Date = .now, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        guard risk != .exhausted, let runsOutAt else { return label(now: now, calendar: calendar, locale: locale) }
        return "runs out \(runsOutAt.resetClockLabel(now: now, calendar: calendar, locale: locale))"
    }

    private static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total > 0 else { return "1 min" }
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(minutes, 1)) min"
    }
}

public extension UsageForecast.Risk {
    /// The one rule for bar, percentage and headline colour and for "most at risk" ranking: the forecast's
    /// risk when there is one, otherwise the usage level (ok → safe, warning → watch, critical → at risk).
    init(usedPercent: Double, forecast: UsageForecast?) {
        if let forecast { self = forecast.risk; return }
        if usedPercent >= 100 { self = .exhausted; return }
        switch UsageLevel(usedPercent) {
        case .ok: self = .safe
        case .warning: self = .watch
        case .critical: self = .atRisk
        }
    }
}

/// One limit (window or capped spend) as the panel header sees it.
public struct RiskItem: Sendable, Hashable {
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var risk: UsageForecast.Risk
    /// Forecast label for a window, "$1.04 / $1.00" for spend.
    public var detail: String?
    /// A window that should have a forecast but has none (not enough data, stale measurement): its risk is
    /// only the usage level, so it must not count as "on track".
    public var missingForecast: Bool

    public init(title: String, usedPercent: Double, resetsAt: Date?, risk: UsageForecast.Risk, detail: String? = nil,
                missingForecast: Bool = false) {
        self.title = title; self.usedPercent = usedPercent; self.resetsAt = resetsAt; self.risk = risk; self.detail = detail
        self.missingForecast = missingForecast
    }

    /// Header order: worse risk first, then higher usage, then the sooner reset.
    public func outranks(_ other: RiskItem) -> Bool {
        if risk != other.risk { return risk > other.risk }
        if usedPercent != other.usedPercent { return usedPercent > other.usedPercent }
        return (resetsAt ?? .distantFuture) < (other.resetsAt ?? .distantFuture)
    }
}

/// "N limits at risk" plus the single most threatened limit; nil without any limit.
public struct RiskSummary: Sendable, Hashable {
    public var atRiskCount: Int
    public var limitCount: Int
    /// Limits below "at risk" whose forecast is unknown.
    public var noForecastCount: Int
    public var top: RiskItem

    public init?(items: [RiskItem]) {
        guard var top = items.first else { return nil }
        for item in items.dropFirst() where item.outranks(top) { top = item }
        self.top = top
        limitCount = items.count
        atRiskCount = items.filter { $0.risk >= .atRisk }.count
        noForecastCount = items.filter { $0.risk < .atRisk && $0.missingForecast }.count
    }

    /// True only when every limit has a forecast and none is at risk.
    public var allOnTrack: Bool { atRiskCount == 0 && noForecastCount == 0 }

    /// "2 limits at risk", "All 3 limits on track", or with unknown forecasts "2 on track · 1 without forecast".
    public var statusLabel: String {
        if atRiskCount > 0 { return atRiskCount == 1 ? "1 limit at risk" : "\(atRiskCount) limits at risk" }
        if noForecastCount == 0 { return "All \(limitCount) limits on track" }
        let onTrack = limitCount - noForecastCount
        let unknown = noForecastCount == 1 ? "1 limit without forecast" : "\(noForecastCount) limits without forecast"
        return onTrack == 0 ? unknown : "\(onTrack) on track · \(unknown)"
    }
}

/// Where the panel shows the "Most at risk / Closest limit" summary. Raw values are stored in UserDefaults.
public enum RiskSummaryPlacement: String, CaseIterable, Sendable {
    case bottom, top, hidden

    /// Stored value, or `.bottom` when missing or unknown.
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .bottom
    }
}

public enum UsageForecaster {
    /// `measuredAt` is when `window.usedPercent` was measured (the snapshot's `fetchedAt`); nil means `now`.
    /// A measurement older than `staleAfter` (refreshes failing) is not current usage: no projection.
    public static func forecast(window: UsageWindow, samples: [UsageSample], now: Date = .now, measuredAt: Date? = nil,
                                staleAfter: TimeInterval = ProviderSyncStatus.minimumStaleAfter,
                                recentInterval: TimeInterval = 3600, calendar: Calendar = .current) -> UsageForecast? {
        guard let reset = window.resetsAt, reset > now else { return nil }
        let used = window.usedPercent

        // Usage never drops within a window, so a stale 100% is still exhausted.
        if used >= 100 {
            return UsageForecast(projectedPercent: used, runsOutAt: nil, resetsAt: reset, ratePerHour: 0, basis: .recent, risk: .exhausted)
        }
        if let measuredAt, now.timeIntervalSince(measuredAt) > staleAfter { return nil }
        // Everything below is "as of the measurement": the window average and the current sample belong to
        // `measuredAt`, not to the clock (a few refresh intervals at most, given the guard above).
        let asOf = min(measuredAt ?? now, now)

        let start = window.windowStart(calendar: calendar)

        // Relevant samples: at <= asOf, at >= start (when known), sorted ascending.
        // Samples from a previous window fall before `start` (resetsAt moved), so this is the primary reset detection.
        var relevant = samples.filter { sample in
            sample.at <= asOf && (start.map { $0 <= sample.at } ?? true)
        }.sorted { $0.at < $1.at }
        // Ensure a sample at `asOf` with the current used percent.
        if let last = relevant.last, last.at > asOf.addingTimeInterval(-1), abs(last.percent - used) < 0.01 {
            // already covered
        } else {
            relevant.append(UsageSample(at: asOf, percent: used))
        }

        // Fallback for windows without a known start: drop everything before the last reset-sized drop.
        var dropIndex = relevant.startIndex
        for i in relevant.indices where i > relevant.startIndex {
            if UsageForecaster.isReset(from: relevant[i - 1].percent, to: relevant[i].percent) {
                dropIndex = i
            }
        }
        relevant = Array(relevant[dropIndex...])

        // Recent rate over the last `recentInterval`.
        let recentCutoff = asOf.addingTimeInterval(-recentInterval)
        let recent = relevant.filter { $0.at >= recentCutoff }
        var rate: Double?
        var basis = UsageForecast.Basis.recent
        // A flat last hour (idle, or an integer provider that has not ticked) says nothing about the rest of the
        // window: projecting rate 0 would show the current value as the projection. Fall back to the window average.
        if recent.count >= 2, let first = recent.first, let last = recent.last, last.at.timeIntervalSince(first.at) >= 600 {
            let recentRate = (last.percent - first.percent) / last.at.timeIntervalSince(first.at)
            if recentRate > 0 { rate = recentRate }
        }
        if rate == nil, let start, asOf.timeIntervalSince(start) >= 300 {
            rate = max(0, used / asOf.timeIntervalSince(start))
            basis = .windowAverage
        }
        // Not enough data: no projection rather than the current value dressed up as one.
        guard let rate else { return nil }

        let remaining = reset.timeIntervalSince(asOf)
        let projected = used + rate * remaining
        var runsOutAt: Date?
        if rate > 0, projected >= 100 {
            let candidate = asOf.addingTimeInterval((100 - used) / rate)
            if candidate < reset { runsOutAt = candidate }
        }

        let risk: UsageForecast.Risk
        if runsOutAt != nil { risk = .atRisk }
        else if projected >= 85 { risk = .watch }
        else { risk = .safe }

        return UsageForecast(projectedPercent: projected, runsOutAt: runsOutAt, resetsAt: reset,
                             ratePerHour: rate * 3600, basis: basis, risk: risk)
    }

    /// A drop that means the window reset rather than rounding jitter: integer providers (Codex) can dip by
    /// one point at the same reset, so require more than 5 points, or a fall to ~0.
    static func isReset(from previous: Double, to current: Double) -> Bool {
        previous - current > 5 || (current < 1 && previous - current > 1)
    }
}

/// Lightweight local sample store persisted to disk.
public struct UsageHistory: Codable, Sendable, Hashable {
    public private(set) var samples: [String: [UsageSample]] = [:]
    public init() {}

    public static func key(instanceID: String, windowID: String) -> String {
        "\(instanceID)/\(windowID)"
    }

    public mutating func record(_ snapshot: UsageSnapshot, at now: Date = .now) {
        for window in snapshot.windows {
            let key = Self.key(instanceID: snapshot.instanceID, windowID: window.id)
            var list = samples[key] ?? []
            if let last = list.last, now.timeIntervalSince(last.at) < 120, abs(last.percent - window.usedPercent) < 0.01 {
                // skip duplicate
            } else {
                list.append(UsageSample(at: now, percent: window.usedPercent))
            }
            // Reset detection: samples from before the current window's start (resetsAt moved on),
            // or, without a known start, a reset-sized drop -> keep only the new sample.
            if let start = window.windowStart() {
                list.removeAll { $0.at < start }
            }
            if let newest = list.last, let previous = list.dropLast().last,
               UsageForecaster.isReset(from: previous.percent, to: newest.percent) {
                list = [newest]
            }
            // Prune by window length.
            let keepSeconds = window.windowLength() ?? 8 * 86400
            let cutoff = max(keepSeconds, 86400)
            let oldest = now.addingTimeInterval(-cutoff)
            list.removeAll { $0.at < oldest }
            // Cap at newest 600.
            if list.count > 600 { list = Array(list.suffix(600)) }
            samples[key] = list
        }
    }

    public mutating func prune(keeping validKeys: Set<String>, now: Date = .now) {
        let cutoff = now.addingTimeInterval(-8 * 86400)
        for key in samples.keys where !validKeys.contains(key) {
            guard let newest = samples[key]?.last?.at, newest < cutoff else { continue }
            samples.removeValue(forKey: key)
        }
    }

    public func samples(instanceID: String, windowID: String) -> [UsageSample] {
        samples[Self.key(instanceID: instanceID, windowID: windowID)] ?? []
    }

    public func forecast(for window: UsageWindow, instanceID: String, now: Date = .now, measuredAt: Date? = nil,
                         staleAfter: TimeInterval = ProviderSyncStatus.minimumStaleAfter) -> UsageForecast? {
        UsageForecaster.forecast(window: window, samples: samples(instanceID: instanceID, windowID: window.id), now: now,
                                 measuredAt: measuredAt, staleAfter: staleAfter)
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaVadis", isDirectory: true)
            .appendingPathComponent("usage-history.json")
    }

    public static func load(from url: URL = defaultURL) -> UsageHistory {
        guard let data = try? Data(contentsOf: url) else { return UsageHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(UsageHistory.self, from: data)) ?? UsageHistory()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
