import Foundation

/// Platform-neutral alert logic shared by the Mac app (after each refresh) and the iOS app (after each sync).
/// Decides which notifications to raise by comparing the previous and the current snapshots.
public struct QuotaAlert: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case threshold, reset }
    public var id: String { "\(kind.rawValue)/\(key)" }
    public let kind: Kind
    /// "<instanceID>/<windowID>"
    public let key: String
    public let title: String
    public let body: String
}

public struct QuotaAlertEngine: Sendable {
    public var warnAtPercent: Int
    public var notifyOnReset: Bool
    /// Keys currently above the threshold (already warned). Persist between runs.
    public var warned: Set<String>
    /// Keys snoozed until a date.
    public var snoozed: [String: Date]

    public init(warnAtPercent: Int, notifyOnReset: Bool, warned: Set<String> = [], snoozed: [String: Date] = [:]) {
        self.warnAtPercent = warnAtPercent
        self.notifyOnReset = notifyOnReset
        self.warned = warned
        self.snoozed = snoozed
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
        }
        return alerts
    }
}
