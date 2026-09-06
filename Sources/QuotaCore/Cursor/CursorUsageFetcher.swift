import Foundation

/// `GET https://cursor.com/api/usage-summary` authenticated with Cursor.app's local session.
public struct CursorUsageFetcher: UsageFetcher {
    public let provider: ProviderID = .cursor
    public init() {}

    public func isAvailable() -> Bool { CursorCredentials.isAvailable() }

    public func fetch() async throws -> UsageSnapshot {
        let creds = try CursorCredentials.load()
        let response = try HTTP.decode(CursorUsageSummary.self, from: try await fetchRaw(creds))
        return Self.snapshot(from: response, account: creds.email)
    }

    public func fetchRaw() async throws -> Data { try await fetchRaw(try CursorCredentials.load()) }

    private func fetchRaw(_ creds: CursorCredentials) async throws -> Data {
        if let expiry = creds.expiresAt, expiry.timeIntervalSinceNow < 60 { throw ProviderError.tokenExpired }
        return try await HTTP.get(URL(string: "https://cursor.com/api/usage-summary")!, headers: [
            "Cookie": creds.cookieHeader,
            "Origin": "https://cursor.com",
            "Referer": "https://cursor.com/dashboard",
            "User-Agent": "QuotaVadis",
        ])
    }

    static func snapshot(from r: CursorUsageSummary, account: String?) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        var credits: [UsageCredits] = []
        let cycleEnd = ISO8601DateFormatter.parseAny(r.billingCycleEnd)
        // Cursor is money-metered: the plan's included allowance is both the "window" and the credit figure.
        if let plan = r.individualUsage?.plan {
            if let pct = plan.totalPercentUsed ?? percent(used: plan.used, limit: plan.limit) {
                windows.append(UsageWindow(id: "plan", kind: .monthly, title: "Plan", usedPercent: pct, resetsAt: cycleEnd))
            }
            if let used = plan.used {
                credits.append(UsageCredits(id: "plan", title: "Included", used: Double(used) / 100,
                                            limit: plan.limit.map { Double($0) / 100 }, resetsAt: cycleEnd))
            }
        }
        if let od = r.individualUsage?.onDemand, od.enabled == true, let used = od.used {
            credits.append(UsageCredits(id: "on-demand", title: "On-demand", used: Double(used) / 100,
                                        limit: od.limit.map { Double($0) / 100 }, resetsAt: cycleEnd))
        }
        let plan = r.membershipType.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        return UsageSnapshot(provider: .cursor, account: account, plan: plan, windows: windows, credits: credits)
    }

    private static func percent(used: Int?, limit: Int?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return Double(used) / Double(limit) * 100
    }
}

struct CursorUsageSummary: Decodable {
    struct Bucket: Decodable {
        let enabled: Bool?
        let used: Int?
        let limit: Int?
        let totalPercentUsed: Double?
    }
    struct Individual: Decodable {
        let plan: Bucket?
        let onDemand: Bucket?
    }
    let billingCycleEnd: String?
    let membershipType: String?
    let individualUsage: Individual?
}
