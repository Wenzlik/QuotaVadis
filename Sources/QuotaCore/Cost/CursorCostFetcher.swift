import Foundation

/// Cursor cost comes from the dashboard, not local logs: `POST /api/dashboard/get-filtered-usage-events`.
/// Account-wide (every machine), and Cursor reports its own cents per event, so no list-price estimate is needed.
public struct CursorCostFetcher: Sendable {
    public static let windowDays = 30
    public init() {}

    public func report(now: Date = .now) async throws -> CostReport {
        let creds = try CursorCredentials.load()
        let since = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(Self.windowDays - 1) * 86_400)
        var acc = CostAccumulator()
        var page = 1
        var seen = 0
        var expected = Int.max
        while seen < expected, page <= 50 {
            let body = #"{"page":\#(page),"pageSize":1000,"startDate":"\#(Int64(since.timeIntervalSince1970 * 1000))","endDate":"\#(Int64(now.timeIntervalSince1970 * 1000))"}"#
            let data = try await HTTP.post(URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!, json: body, headers: [
                "Cookie": creds.cookieHeader, "Origin": "https://cursor.com", "Referer": "https://cursor.com/dashboard", "User-Agent": "QuotaVadis",
            ])
            let pageData = try HTTP.decode(EventsPage.self, from: data)
            expected = pageData.totalUsageEventsCount ?? 0
            let events = pageData.usageEventsDisplay ?? []
            if events.isEmpty { break }
            for e in events { Self.add(e, to: &acc) }
            seen += events.count
            page += 1
        }
        return acc.report(provider: .cursor, windowDays: Self.windowDays,
                          source: "From Cursor's usage dashboard, all machines on this account; cost as metered by Cursor.")
    }

    static func add(_ e: Event, to acc: inout CostAccumulator) {
        guard let ms = e.timestampMS else { return }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let t = e.tokenUsage
        let tokens = TokenCounts(input: t?.inputTokens ?? 0, output: t?.outputTokens ?? 0,
                                 cacheRead: t?.cacheReadTokens ?? 0, cacheWrite: t?.cacheWriteTokens ?? 0)
        let cost = (t?.totalCents ?? e.chargedCents ?? 0) / 100
        acc.add(date: date, model: e.model ?? "unknown", project: nil, tokens: tokens, costUSD: cost)
    }

    struct EventsPage: Decodable {
        let totalUsageEventsCount: Int?
        let usageEventsDisplay: [Event]?
    }
    struct Event: Decodable {
        let timestampMS: Int64?
        let model: String?
        let kind: String?
        let tokenUsage: TokenUsage?
        let chargedCents: Double?
        enum CodingKeys: String, CodingKey { case timestamp, model, kind, tokenUsage, chargedCents }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Timestamp arrives as a string of milliseconds or as a number.
            timestampMS = (try? c.decodeIfPresent(String.self, forKey: .timestamp)).flatMap(Int64.init)
                ?? (try? c.decodeIfPresent(Int64.self, forKey: .timestamp))
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            tokenUsage = try? c.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
            chargedCents = try? c.decodeIfPresent(Double.self, forKey: .chargedCents)
        }
    }
    struct TokenUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheWriteTokens: Int?
        let cacheReadTokens: Int?
        let totalCents: Double?
    }
}
