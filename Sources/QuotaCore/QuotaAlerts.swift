import Foundation

/// Platform-neutral alert logic shared by the Mac app (after each refresh) and the iOS app (after each sync).
/// Decides which notifications to raise by comparing the previous and the current snapshots.
public struct QuotaAlert: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case threshold, reset, extraUsageUnexpected, extraUsageAtLimit }
    public var id: String { "\(kind.rawValue)/\(key)" }
    public let kind: Kind
    /// "<instanceID>/<windowID>"
    public let key: String
    public let title: String
    public let body: String

    public init(kind: Kind, key: String, title: String, body: String) {
        self.kind = kind; self.key = key; self.title = title; self.body = body
    }
}

public struct QuotaAlertEngine: Sendable {
    public var warnAtPercent: Int
    public var notifyOnReset: Bool
    /// Alert when paid extra usage grows — while limits are still available (you are paying although quota is
    /// left, e.g. a model outside your seat) and when it starts after a window hit 100%.
    public var notifyExtraUsage: Bool
    /// Keys currently above the threshold (already warned). Persist between runs.
    public var warned: Set<String>
    /// Keys snoozed until a date.
    public var snoozed: [String: Date]
    /// Last seen paid amount per "<instanceID>/credit/<creditID>". Persist between runs.
    public var creditBaseline: [String: Double]
    /// Extra-usage alerts repeat at most once per hour per credit line.
    public static let extraUsageCooldown: TimeInterval = 3600

    public init(warnAtPercent: Int, notifyOnReset: Bool, notifyExtraUsage: Bool = true, warned: Set<String> = [],
                snoozed: [String: Date] = [:], creditBaseline: [String: Double] = [:]) {
        self.warnAtPercent = warnAtPercent
        self.notifyOnReset = notifyOnReset
        self.notifyExtraUsage = notifyExtraUsage
        self.warned = warned
        self.snoozed = snoozed
        self.creditBaseline = creditBaseline
    }

    public mutating func snooze(key: String, for interval: TimeInterval = 3600, now: Date = .now) {
        snoozed[key] = now.addingTimeInterval(interval)
    }

    /// `titles` maps instance id → display title ("Claude Code · GoodData").
    public mutating func evaluate(snapshots: [UsageSnapshot], titles: [String: String] = [:], now: Date = .now) -> [QuotaAlert] {
        var alerts: [QuotaAlert] = []
        snoozed = snoozed.filter { $0.value > now }
        for snapshot in snapshots {
            let title = titles[snapshot.instanceID] ?? snapshot.provider.displayName
            for window in snapshot.windows where window.prominent {
                let key = "\(snapshot.instanceID)/\(window.id)"
                let above = window.usedPercent >= Double(warnAtPercent)
                if above {
                    if !warned.contains(key) {
                        warned.insert(key)
                        if snoozed[key] == nil {
                            let reset = window.resetsAt.map { " · resets \($0.formatted(.relative(presentation: .named)))" } ?? ""
                            alerts.append(QuotaAlert(kind: .threshold, key: key,
                                                     title: "\(title): \(window.title) at \(Int(window.usedPercent.rounded()))%",
                                                     body: "\(Int(window.remainingPercent.rounded()))% left\(reset)"))
                        }
                    }
                } else if warned.contains(key) {
                    warned.remove(key)
                    // Went from above the threshold to (near) empty: the window reset.
                    if notifyOnReset, window.usedPercent < 15, snoozed[key] == nil {
                        alerts.append(QuotaAlert(kind: .reset, key: key,
                                                 title: "\(title): \(window.title) reset",
                                                 body: "Back to \(Int(window.remainingPercent.rounded()))% available."))
                    }
                }
            }
            alerts += extraUsageAlerts(for: snapshot, title: title, now: now)
        }
        return alerts
    }

    private mutating func extraUsageAlerts(for snapshot: UsageSnapshot, title: String, now: Date) -> [QuotaAlert] {
        var alerts: [QuotaAlert] = []
        for credit in snapshot.credits {
            let key = "\(snapshot.instanceID)/credit/\(credit.id)"
            let previous = creditBaseline[key]
            creditBaseline[key] = credit.used
            // First sighting only sets the baseline; a decrease is a new billing period.
            guard notifyExtraUsage, let previous, credit.used > previous + 0.005 else { continue }
            guard snoozed[key] == nil else { continue }
            let delta = credit.used - previous
            let money = { (v: Double) in v.formatted(.currency(code: credit.currency).precision(.fractionLength(2))) }
            let exhausted = snapshot.windows.filter(\.prominent).filter { $0.usedPercent >= 99.5 }
            if exhausted.isEmpty {
                alerts.append(QuotaAlert(kind: .extraUsageUnexpected, key: key,
                                         title: "\(title): paying extra usage while limits remain",
                                         body: "\(credit.title) grew by \(money(delta)) to \(money(credit.used)) although no window is exhausted. A model outside your seat (e.g. Fable on a Standard seat) is billed separately."))
            } else {
                let names = exhausted.map(\.title).joined(separator: ", ")
                // The cheapest advice: if the exhausted window resets soon, waiting beats paying.
                let soonest = exhausted.compactMap(\.resetsAt).min()
                var body = "\(names) is exhausted; further use is billed. \(credit.title) is at \(money(credit.used))."
                var heading = "\(title): extra usage started"
                if let soonest, soonest > now {
                    let minutes = Int(soonest.timeIntervalSince(now) / 60)
                    body += " Resets \(soonest.resetLabel(now: now))."
                    if minutes <= 90 { heading = "\(title): paying extra usage, reset in \(minutes) min" }
                }
                alerts.append(QuotaAlert(kind: .extraUsageAtLimit, key: key, title: heading, body: body))
            }
            snoozed[key] = now.addingTimeInterval(Self.extraUsageCooldown)
        }
        return alerts
    }
}
