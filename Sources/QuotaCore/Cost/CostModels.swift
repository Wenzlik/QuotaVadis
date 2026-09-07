import Foundation

/// Token counts for one or many requests. Cache tokens are kept apart because they are priced differently.
public struct TokenCounts: Codable, Sendable, Hashable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input; lhs.output += rhs.output; lhs.cacheRead += rhs.cacheRead; lhs.cacheWrite += rhs.cacheWrite
    }
}

/// One aggregation bucket (a day, a model, a project).
public struct CostBucket: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var tokens: TokenCounts
    public var costUSD: Double
    public var requests: Int

    public init(id: String, tokens: TokenCounts = TokenCounts(), costUSD: Double = 0, requests: Int = 0) {
        self.id = id; self.tokens = tokens; self.costUSD = costUSD; self.requests = requests
    }

    mutating func add(_ tokens: TokenCounts, cost: Double) {
        self.tokens += tokens; costUSD += cost; requests += 1
    }
}

/// 30-day cost picture for one provider. Days are local calendar days, oldest first, gaps filled with zeros.
public struct CostReport: Codable, Sendable, Hashable {
    public var provider: ProviderID
    public var days: [CostBucket]
    public var byModel: [CostBucket]
    public var byProject: [CostBucket]
    public var generatedAt: Date
    /// Calendar zone of the Mac that produced the daily buckets (optional for older payloads).
    public var timeZoneID: String?
    /// Where the numbers come from, shown verbatim under the chart.
    public var source: String

    public init(provider: ProviderID, days: [CostBucket], byModel: [CostBucket], byProject: [CostBucket], generatedAt: Date = .now, source: String) {
        self.provider = provider; self.days = days; self.byModel = byModel; self.byProject = byProject
        self.generatedAt = generatedAt; self.source = source
        self.timeZoneID = TimeZone.current.identifier
    }

    public var today: CostBucket? { day(at: .now) }
    public func day(at date: Date) -> CostBucket? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        return days.first { $0.id == CostAccumulator.dayKey(date, calendar: calendar) }
    }
    public var totalCostUSD: Double { days.reduce(0) { $0 + $1.costUSD } }
    public var totalTokens: Int { days.reduce(0) { $0 + $1.tokens.total } }
    public var topModel: CostBucket? { byModel.max { $0.costUSD < $1.costUSD } }
}

/// Accumulates raw usage rows into a CostReport.
struct CostAccumulator {
    private var days: [String: CostBucket] = [:]
    private var models: [String: CostBucket] = [:]
    private var projects: [String: CostBucket] = [:]
    private let calendar = CostAccumulator.bucketCalendar
    private static let dayFormat: Date.FormatStyle = .init().year().month(.twoDigits).day(.twoDigits)

    /// Day buckets always use the Gregorian calendar in the local time zone, matching `CostReport.day(at:)`.
    static var bucketCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func dayKey(_ date: Date, calendar: Calendar = CostAccumulator.bucketCalendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    mutating func add(date: Date, model: String, project: String?, tokens: TokenCounts, costUSD: Double) {
        days[Self.dayKey(date), default: CostBucket(id: Self.dayKey(date))].add(tokens, cost: costUSD)
        models[model, default: CostBucket(id: model)].add(tokens, cost: costUSD)
        if let project { projects[project, default: CostBucket(id: project)].add(tokens, cost: costUSD) }
    }

    func report(provider: ProviderID, windowDays: Int, source: String, now: Date = .now) -> CostReport {
        var filled: [CostBucket] = []
        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let key = Self.dayKey(date)
            filled.append(days[key] ?? CostBucket(id: key))
        }
        return CostReport(provider: provider, days: filled,
                          byModel: models.values.sorted { $0.costUSD > $1.costUSD },
                          byProject: projects.values.sorted { $0.costUSD > $1.costUSD },
                          generatedAt: now, source: source)
    }
}
