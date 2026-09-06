import Foundation

/// `GET https://cursor.com/api/usage-summary` authenticated with Cursor.app's local session.
public struct CursorUsageFetcher: UsageFetcher {
    public let provider: ProviderID = .cursor
    public init() {}

    public func isAvailable() -> Bool { CursorCredentials.isAvailable() }

    public func fetch() async throws -> UsageSnapshot {
        let creds = try CursorCredentials.load()
        if let expiry = creds.expiresAt, expiry.timeIntervalSinceNow < 60 { throw ProviderError.tokenExpired }
        let data = try await HTTP.get(URL(string: "https://cursor.com/api/usage-summary")!, headers: [
            "Cookie": creds.cookieHeader,
            "Origin": "https://cursor.com",
            "Referer": "https://cursor.com/dashboard",
            "User-Agent": "QuotaBar",
        ])
        let response = try HTTP.decode(CursorUsageSummary.self, from: data)
        return Self.snapshot(from: response, account: creds.email)
    }

    static func snapshot(from r: CursorUsageSummary, account: String?) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        let cycleEnd = ISO8601DateFormatter.parseAny(r.billingCycleEnd)
        if let plan = r.individualUsage?.plan {
            let pct = plan.totalPercentUsed
                ?? percent(used: plan.used, limit: plan.limit)
            if let pct {
                windows.append(UsageWindow(id: "plan", kind: .monthly, title: "Plan", usedPercent: pct, resetsAt: cycleEnd))
            }
        }
        if let od = r.individualUsage?.onDemand, od.enabled == true, let pct = percent(used: od.used, limit: od.limit) {
            windows.append(UsageWindow(id: "on-demand", kind: .credits, title: "On-demand", usedPercent: pct, resetsAt: cycleEnd))
        }
        let plan = r.membershipType.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        return UsageSnapshot(provider: .cursor, account: account, plan: plan, windows: windows)
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
