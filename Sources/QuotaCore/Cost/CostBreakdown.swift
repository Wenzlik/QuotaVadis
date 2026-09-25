import Foundation

/// What a cost chart or breakdown measures. Raw values match the stored `costChartMetric` preference.
public enum CostMetric: String, CaseIterable, Sendable {
    case cost, tokens
}

public extension CostBucket {
    func value(_ metric: CostMetric) -> Double { metric == .cost ? costUSD : Double(tokens.total) }
}

/// One line of a "By model" / "By project" list: a bucket (or the folded rest) and its share of the total.
public struct CostBreakdownRow: Sendable, Hashable, Identifiable {
    public var bucket: CostBucket
    /// 0...1 of the sum over every bucket in the list, for the selected metric.
    public var share: Double
    /// Number of buckets folded into this row; 0 for an ordinary row.
    public var folded: Int
    public var id: String { bucket.id }
    public var isOther: Bool { folded > 0 }
}

public enum CostBreakdown {
    /// Ranks by the selected metric *before* choosing the top rows — the stored order is by cost, so a tokens
    /// view that reused it showed an unsorted list. Ties break by id so the order is stable; "Other" is last.
    public static func rows(_ buckets: [CostBucket], metric: CostMetric, top: Int = 5) -> [CostBreakdownRow] {
        let total = buckets.reduce(0) { $0 + $1.value(metric) }
        func share(_ v: Double) -> Double { total > 0 ? v / total : 0 }
        let sorted = buckets.sorted { a, b in
            a.value(metric) != b.value(metric) ? a.value(metric) > b.value(metric) : a.id < b.id
        }
        var rows = sorted.prefix(top).map { CostBreakdownRow(bucket: $0, share: share($0.value(metric)), folded: 0) }
        let rest = sorted.dropFirst(top)
        if !rest.isEmpty {
            var other = CostBucket(id: "Other (\(rest.count))")
            for b in rest { other.tokens += b.tokens; other.costUSD += b.costUSD; other.requests += b.requests }
            rows.append(CostBreakdownRow(bucket: other, share: share(other.value(metric)), folded: rest.count))
        }
        return rows
    }
}

public extension CostReport {
    /// The calendar the daily buckets were cut with (the publishing Mac's zone, for synced reports).
    var bucketCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        return calendar
    }

    /// Start of the day a `days` bucket stands for, in `bucketCalendar`. nil for a malformed id.
    func date(of day: CostBucket) -> Date? {
        let parts = day.id.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return bucketCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// All tokens over the report window, split by kind.
    var tokenComposition: TokenCounts {
        days.reduce(into: TokenCounts()) { $0 += $1.tokens }
    }
}
